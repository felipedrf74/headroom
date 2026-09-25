import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class QuotaStore {
    var statuses: [Provider: ProviderStatus] = [:]
    /// Last successful fetch per provider, even when usage didn't change.
    var checkedAt: [Provider: Date] = [:]
    var lastAttempt: Date?
    var isRefreshing = false
    var settings: AppSettings
    var showsLegacyNotice: Bool
    /// Set by "Add Key" in the popover; Settings opens its key sheet and clears it.
    var pendingKeyProvider: Provider?
    let signIn: SignInCoordinator
    /// Sends readings to iCloud for iPhone and Apple Watch. Nil in tests.
    let relay: RelayPublisher?
    /// A week of hourly usage per window, next to the snapshot cache.
    let history: HistoryStore
    /// New models and announcements for the News window, fetched only when turned on. Nil in tests.
    let news: NewsStore?
    private var alertLedger: AlertLedger

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var rateLimitedUntil: [Provider: Date] = [:]
    /// When each provider's endpoint was last called, successful or not; spacing counts from it.
    private var lastAttemptAt: [Provider: Date] = [:]
    /// Readings before a budget was applied, so a new budget shows at once.
    private var rawSnapshots: [Provider: QuotaSnapshot] = [:]
    private var loopTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var snapshotsDirty = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "refresh")

    init(
        settings: AppSettings = AppSettings(),
        clients: [any ProviderClient] = QuotaStore.defaultClients,
        cache: SnapshotCache = SnapshotCache(),
        relay: RelayPublisher? = nil,
        news: NewsStore? = nil,
        showsLegacyNotice: Bool = false
    ) {
        self.settings = settings
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.cache = cache
        self.relay = relay
        self.news = news
        self.history = HistoryStore(directory: cache.directory)
        self.alertLedger = AlertLedger.load(from: cache.directory)
        self.showsLegacyNotice = showsLegacyNotice
        self.signIn = SignInCoordinator()
        let cached = cache.load()
        checkedAt = cache.loadChecked()
        for provider in Provider.allCases {
            if let snapshot = cached[provider] {
                statuses[provider] = .stale(snapshot)
            } else {
                statuses[provider] = .loading
            }
        }
        signIn.onConnected = { [weak self] provider in
            guard let self else { return }
            self.settings.setEnabled(provider, true)
            Task { await self.refresh(force: true, providers: [provider]) }
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.refresh(force: true)
            // `-TokenroomSendTestAlert YES` sends one test alert to the iPhone after launch.
            if UserDefaults.standard.bool(forKey: "TokenroomSendTestAlert") {
                await self?.relay?.sendTestAlert()
            }
            while !Task.isCancelled {
                guard let self else { return }
                let nanoseconds = UInt64(max(self.settings.refreshInterval, 60) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
        wakeTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in notifications {
                await self?.refresh()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        inFlight?.cancel()
        inFlight = nil
        signIn.cancel()
    }

    func refreshIfStale(after seconds: TimeInterval = 45) async {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < seconds {
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool = false, providers: [Provider]? = nil) async {
        if let inFlight {
            // A check in flight finishes rather than being cancelled: its calls are already out,
            // and calling a rate-limited provider again right away can earn a 429. Then a forced
            // refresh checks what it asked for; the spacing rules keep just-checked providers
            // resting.
            await inFlight.value
            guard force else { return }
        }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 15 {
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNow(providers: providers)
        }
        inFlight = task
        await task.value
        // Another refresh may have started once this one finished.
        if inFlight == task {
            inFlight = nil
        }
    }

    private func refreshNow(providers: [Provider]?) async {
        isRefreshing = true
        let now = Date()
        lastAttempt = now
        let earlierAttempts = lastAttemptAt
        var due: [Provider] = []
        var resting: [Provider] = []
        for provider in providers ?? Provider.allCases where settings.isEnabled(provider) {
            // A provider that answered 429 is left alone until its Retry-After passes.
            if let until = rateLimitedUntil[provider], until > now { continue }
            // Spacing counts from the last call, so failures don't bring the next one closer.
            if let last = lastAttemptAt[provider], now.timeIntervalSince(last) < provider.minimumInterval {
                resting.append(provider)
            } else {
                due.append(provider)
                lastAttemptAt[provider] = now
            }
        }
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in due {
                guard let client = clients[provider] else { continue }
                group.addTask {
                    await (provider, client.fetchWithinBudget())
                }
            }
            for await (provider, result) in group {
                // Cancelled for a newer refresh: checks cut short aren't failures, and don't
                // count as attempts, so the next refresh asks again.
                if Task.isCancelled, case .failure = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                    continue
                }
                apply(provider: provider, result: result)
            }
        }
        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }
        for provider in resting {
            // The kept reading dates from when its values first appeared; a between-calls
            // reading has to be newer than the last check.
            var previous = statuses[provider]?.snapshot
            if let kept = previous?.fetchedAt, let checked = checkedAt[provider], checked > kept {
                previous?.fetchedAt = checked
            }
            guard let client = clients[provider],
                  let snapshot = await client.fetchBetweenCalls(previous: previous)
            else { continue }
            apply(provider: provider, result: .success(snapshot))
        }
        persistLiveSnapshots()
        cache.saveChecked(checkedAt)
        history.saveIfNeeded()
        isRefreshing = false
        let envelope = relayEnvelope(at: now)
        await relay?.publish(envelope)
        let relayed = Provider.allCases.filter { settings.isEnabled($0) }
        await relay?.publishHistory(history.relayHistory(for: relayed), now: now)
        await sendAlerts(for: envelope.providers, now: now)
        await refreshNews(now: now)
    }

    /// Checks News when it's turned on; the fetcher only goes out when a feed is due.
    func refreshNews(force: Bool = false, now: Date = .now) async {
        guard settings.newsEnabled, let news else { return }
        await news.refresh(maxAge: force ? 0 : nil, preferences: settings.alertPreferences, notifies: settings.showsAlertsOnMac, now: now)
    }

    /// Alerts for crossings since the last refresh: to the iPhone through iCloud, and on this Mac
    /// when turned on. Each goes out once, from whichever device saw it first. Alerts that can
    /// wait hold until quiet hours end, and ones iCloud didn't take are retried next time.
    private func sendAlerts(for providers: [RelayProvider], now: Date) async {
        let preferences = await currentAlertPreferences(now: now)
        alertLedger.process(providers, preferences: preferences, now: now)
        let due = alertLedger.due(preferences: preferences, now: now)
        guard !due.isEmpty else {
            alertLedger.save(to: cache.directory)
            return
        }
        let relayActive = relay.map { $0.isAvailable && $0.isEnabled } ?? false
        var delivered: [String] = []
        if relayActive, let relay {
            delivered = await relay.sendAlerts(due, now: now)
        }
        if settings.showsAlertsOnMac {
            let unseen = due.filter { alertLedger.shownHere[$0.id] == nil }
            MacAlerts.post(unseen)
            alertLedger.markShownHere(unseen.map(\.id), at: now)
        }
        if !relayActive {
            // Nowhere else to send them: this Mac showed them, or nothing will.
            delivered = due.map(\.id)
        }
        alertLedger.markSent(delivered, at: now)
        alertLedger.save(to: cache.directory)
    }

    /// The newer of this Mac's alert preferences and the shared copy; adopts the shared one when
    /// the iPhone changed it last, so Settings shows it.
    func currentAlertPreferences(now: Date = .now) async -> AlertPreferences {
        let local = settings.alertPreferences
        let preferences = await relay?.alertPreferences(local: local, now: now) ?? local
        if preferences != local {
            settings.alertPreferences = preferences
        }
        return preferences
    }

    /// Alert choices changed in Settings on this Mac.
    func updateAlertPreferences(_ change: (inout AlertPreferences) -> Void, now: Date = .now) {
        var preferences = settings.alertPreferences
        change(&preferences)
        guard preferences != settings.alertPreferences else { return }
        preferences.touch(now: now)
        settings.alertPreferences = preferences
        Task { await relay?.publishAlertPreferences(preferences, now: now) }
    }

    /// Pace of a provider's primary window, from its recent readings.
    func pace(for provider: Provider, now: Date = .now) -> Pace? {
        let status = statuses[provider] ?? .loading
        guard let snapshot = status.snapshot, let window = snapshot.windows.first else { return nil }
        return Pace.evaluate(
            used: window.usedPercent,
            kind: window.kind,
            resetsAt: window.resetsAt,
            startsAt: window.startsAt,
            windowSeconds: window.windowSeconds,
            samples: history.samples(provider: provider, window: window.id),
            isStale: status.isStale,
            now: now
        )
    }

    /// Pace for every window of a provider, keyed by window ID.
    func windowPaces(for provider: Provider, now: Date = .now) -> [String: Pace] {
        let status = statuses[provider] ?? .loading
        guard let snapshot = status.snapshot else { return [:] }
        var paces: [String: Pace] = [:]
        for window in snapshot.windows {
            let pace = Pace.evaluate(
                used: window.usedPercent,
                kind: window.kind,
                resetsAt: window.resetsAt,
                startsAt: window.startsAt,
                windowSeconds: window.windowSeconds,
                samples: history.samples(provider: provider, window: window.id),
                isStale: status.isStale,
                now: now
            )
            paces[window.id] = pace
        }
        return paces
    }

    /// A week of hourly usage per window of a provider, keyed by window ID.
    func weeks(for provider: Provider) -> [String: UsageHistory] {
        history.weeks(for: provider)
    }

    /// Banked resets across providers, for the popover's footer.
    var bankedResets: (count: Int, providers: [Provider]) {
        var count = 0
        var providers: [Provider] = []
        for provider in connectedProviders {
            if let available = statuses[provider]?.snapshot?.banked?.available, available > 0 {
                count += available
                providers.append(provider)
            }
        }
        return (count, providers)
    }

    /// Enabled providers as the iPhone and Watch will see them.
    func relayEnvelope(at now: Date) -> RelayEnvelope {
        let providers = Provider.allCases.filter { settings.isEnabled($0) }.map { provider in
            var relayed = RelayProvider(provider: provider, status: statuses[provider] ?? .loading, checkedAt: checkedAt[provider])
            // The pace this Mac measured from its frequent readings, for readers with hourly history.
            let paces = relayed.isLive ? windowPaces(for: provider, now: now) : [:]
            for index in relayed.windows.indices where relayed.windows[index].isMetered {
                if let pace = paces[relayed.windows[index].id] {
                    relayed.windows[index].pace = RelayPace(runsOutAt: pace.runsOutAt)
                }
            }
            return relayed
        }
        return RelayEnvelope(
            producer: "mac",
            appVersion: TokenroomIdentity.version,
            checkedAt: now,
            providers: providers
        )
    }

    var menuMeters: [MenuMeter] {
        Provider.allCases.compactMap { provider in
            guard settings.isEnabled(provider), settings.showsInMenuBar(provider) else { return nil }
            let status = statuses[provider] ?? .loading
            switch status {
            case .signedOut, .notEntitled, .expired(_, nil), .rateLimited(_, nil), .unreachable(nil):
                return nil
            case .loading:
                return MenuMeter(
                    provider: provider,
                    valueText: "--",
                    remaining: 100,
                    usedPercent: 0,
                    isStale: false,
                    isPlaceholder: true
                )
            case .live(let snapshot), .stale(let snapshot), .unreachable(let snapshot?),
                 .expired(_, let snapshot?), .rateLimited(_, let snapshot?):
                // A balance with no limit has no percentage to show.
                guard snapshot.windows.first?.isMetered ?? true else { return nil }
                return MenuMeter(
                    provider: provider,
                    valueText: Self.percentText(snapshot.usedPercent),
                    remaining: snapshot.remainingPercent,
                    usedPercent: snapshot.usedPercent,
                    isStale: status.isStale,
                    isPlaceholder: false
                )
            }
        }
    }

    var popoverProviders: [Provider] {
        Provider.allCases.filter { settings.isEnabled($0) }
    }

    /// Enabled providers with a reading (or still loading), shown first.
    var connectedProviders: [Provider] {
        popoverProviders.filter { !isDisconnected($0) }
    }

    /// Enabled providers waiting for a sign-in or key, collapsed at the bottom.
    var disconnectedProviders: [Provider] {
        popoverProviders.filter { isDisconnected($0) }
    }

    private func isDisconnected(_ provider: Provider) -> Bool {
        (statuses[provider] ?? .loading).isDisconnected
    }

    func accountCaption(_ provider: Provider) -> String {
        let status = statuses[provider] ?? .loading
        switch status {
        case .loading:
            return "Checking…"
        case .live:
            return "Connected"
        case .stale, .unreachable(.some):
            return "Connected · last good reading"
        case .signedOut:
            return "Not signed in"
        case .expired(_, .some):
            return "Session expired · last good reading"
        case .expired(_, nil):
            return "Session expired"
        case .notEntitled:
            return "Not on this plan"
        case .rateLimited(let until, _):
            return "Rate limited · next try \(until.formatted(date: .omitted, time: .shortened))"
        case .unreachable(nil):
            return "Couldn't reach \(provider.displayName)"
        }
    }

    /// Last successful check for a provider, falling back to when its reading was taken.
    func lastChecked(_ provider: Provider) -> Date? {
        checkedAt[provider] ?? statuses[provider]?.snapshot?.fetchedAt
    }

    /// When a provider's usage last changed: its reading keeps the time it first appeared,
    /// because an unchanged answer doesn't replace it.
    func lastChanged(_ provider: Provider) -> Date? {
        statuses[provider]?.snapshot?.fetchedAt
    }

    /// The currency a provider's budget or reference is entered in, from its last reading.
    func budgetCurrency(for provider: Provider) -> String {
        (rawSnapshots[provider] ?? statuses[provider]?.snapshot)?.budgetCurrencyCode ?? "USD"
    }

    /// Re-applies the provider's budget to its last reading.
    func budgetDidChange(for provider: Provider) {
        guard let raw = rawSnapshots[provider], case .live = statuses[provider] else { return }
        statuses[provider] = .live(raw.applyingBudget(settings.budget(for: provider)))
        snapshotsDirty = true
        persistLiveSnapshots()
    }

    func dismissLegacyNotice() {
        LegacyMigration.dismissNotice()
        showsLegacyNotice = false
    }

    func quitLegacyApp() {
        LegacyMigration.quitLegacyApp()
    }

    static var defaultClients: [any ProviderClient] {
        var clients: [any ProviderClient] = [
            GrokClient(), GrokBotClient(), ClaudeClient(), OpenAIClient(), CursorClient(),
            CopilotClient(), AntigravityClient(), DevinClient(),
        ]
        for provider in Provider.allCases where provider.usesAPIKey {
            var client = APIKeyClient(provider: provider, keys: CredentialReaders.apiKeys)
            if provider.access == .codingPlanKey {
                client.localCredential = { try LocalKeys.credential(for: $0) }
            }
            clients.append(client)
        }
        return clients
    }

    static func percentText(_ value: Double) -> String {
        TokenroomFormat.percentText(value)
    }

    private func apply(provider: Provider, result: Result<QuotaSnapshot, ProviderError>, now: Date = .now) {
        switch result {
        case .success(let raw):
            rawSnapshots[provider] = raw
            let snapshot = raw.applyingBudget(settings.budget(for: provider))
            checkedAt[provider] = snapshot.fetchedAt
            rateLimitedUntil[provider] = nil
            history.record(snapshot)
            if case .live(let old) = statuses[provider], Self.usageEqual(old, snapshot) {
                return
            }
            statuses[provider] = .live(snapshot)
            snapshotsDirty = true
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: statuses[provider]?.snapshot, lastChecked: checkedAt[provider], now: now)
            if case .rateLimited(let until, _) = next {
                rateLimitedUntil[provider] = until
            }
            if statuses[provider] != next {
                statuses[provider] = next
                snapshotsDirty = true
                logger.error("refresh failed \(provider.rawValue, privacy: .public)")
            }
        }
    }

    /// Honors Retry-After, within one minute to six hours.
    nonisolated static func clampedRetry(_ until: Date?, now: Date) -> Date {
        ProviderStatus.clampedRetry(until, now: now)
    }

    /// Whether a new reading says nothing the kept one doesn't: every field but when it was
    /// fetched and where from, so a newly banked reset, credits, or extra usage replace it even
    /// when the meters haven't moved, while the same values from Claude's status line and its
    /// direct call don't take turns. The kept reading's `fetchedAt` stays the time its values
    /// first appeared.
    nonisolated static func usageEqual(_ a: QuotaSnapshot, _ b: QuotaSnapshot) -> Bool {
        var a = a
        a.fetchedAt = b.fetchedAt
        a.source = b.source
        return a == b
    }

    private func persistLiveSnapshots() {
        guard snapshotsDirty else { return }
        snapshotsDirty = false
        var snapshots: [Provider: QuotaSnapshot] = [:]
        for (provider, status) in statuses {
            if let snapshot = status.snapshot {
                snapshots[provider] = snapshot
            }
        }
        cache.save(snapshots)
    }
}
