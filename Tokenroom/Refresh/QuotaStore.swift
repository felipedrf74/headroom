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
    private var sleepTask: Task<Void, Never>?
    /// The check running now.
    private var inFlight: Task<Void, Never>?
    /// One more check after the running one, shared by the forced refreshes asked for meanwhile,
    /// for every provider they asked for (nil: all of them).
    private var followUp: Task<Void, Never>?
    private var followUpProviders: Set<Provider>? = []
    /// Sending readings, history, and alerts to iCloud, and checking News, after a check.
    private var sharing: Task<Void, Never>?
    private var shareAgain = false
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
            Task { await self.credentialsChanged(for: provider) }
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.refresh(force: true)
            #if DEBUG
            // `-TokenroomSendTestAlert YES` sends one test alert to the iPhone after launch.
            if UserDefaults.standard.bool(forKey: "TokenroomSendTestAlert") {
                await self?.relay?.sendTestAlert()
            }
            #endif
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
                // Forced: however short the sleep, what it cut short is checked again.
                await self?.refresh(force: true)
            }
        }
        sleepTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification)
            for await _ in notifications {
                // Calls cut off by sleep would come back as failures. Cancelled, they don't
                // count, and the refresh on waking checks again.
                self?.inFlight?.cancel()
                self?.followUp?.cancel()
                self?.sharing?.cancel()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        inFlight?.cancel()
        inFlight = nil
        followUp?.cancel()
        followUp = nil
        sharing?.cancel()
        sharing = nil
        signIn.cancel()
    }

    func refreshIfStale(after seconds: TimeInterval = 45) async {
        if let lastAttempt, (0..<seconds).contains(Date().timeIntervalSince(lastAttempt)) {
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool = false, providers: [Provider]? = nil) async {
        if let inFlight {
            // A check in flight finishes rather than being cancelled: its calls are already out,
            // and calling a rate-limited provider again right away can earn a 429.
            guard force else {
                await inFlight.value
                return
            }
            // Forced refreshes asked for meanwhile share one more check after it, for everything
            // they asked for; the spacing rules keep just-checked providers resting.
            await joinFollowUp(after: inFlight, providers: providers).value
            return
        }
        // A check moments ago is enough, unless the clock was set back since.
        if !force, let lastAttempt, (0..<15).contains(Date().timeIntervalSince(lastAttempt)) {
            return
        }
        // Forced refreshes (a button, a sign-in, the tests) return once readings are shared;
        // the timer's don't wait for iCloud and News, so a slow iCloud can't hold up checks.
        await check(providers, waitsForSharing: force)
    }

    /// A sign-in finished, or a key was saved or removed: the provider is checked now, not after
    /// its spacing or a Retry-After, which came from the old credentials.
    func credentialsChanged(for provider: Provider) async {
        // After the check in flight, whose answer came from the old credentials: a 429 it earns
        // mustn't hold the new ones off.
        if let inFlight {
            await inFlight.value
        }
        lastAttemptAt[provider] = nil
        rateLimitedUntil[provider] = nil
        clients[provider]?.credentialsChanged()
        await refresh(force: true, providers: [provider])
    }

    private func joinFollowUp(after running: Task<Void, Never>, providers: [Provider]?) -> Task<Void, Never> {
        if let providers, let asked = followUpProviders {
            followUpProviders = asked.union(providers)
        } else {
            followUpProviders = nil
        }
        if let followUp {
            return followUp
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await running.value
            guard let self else { return }
            if self.inFlight == running {
                self.inFlight = nil
            }
            let asked = self.followUpProviders
            self.followUp = nil
            self.followUpProviders = []
            // Not when going to sleep or quitting.
            guard !Task.isCancelled else { return }
            // Through `refresh`, in case another check started first.
            await self.refresh(force: true, providers: asked.map { Array($0) })
        }
        followUp = task
        return task
    }

    /// Checks the providers asked for (nil: all), then shares what it found.
    private func check(_ providers: [Provider]?, waitsForSharing: Bool = true) async {
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
        // A check cut short (sleep, quitting) has nothing new to share.
        guard !task.isCancelled else { return }
        if waitsForSharing {
            await share()
        } else {
            Task { await self.share() }
        }
    }

    /// Sends readings, history, and alerts to iCloud and checks News, one round at a time and
    /// outside the check, so a slow iCloud doesn't hold up the next check. A check that finishes
    /// meanwhile leaves one more round, with the newest readings then.
    private func share() async {
        if let sharing {
            shareAgain = true
            await sharing.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.shareAgain = false
                await self.shareReadings(now: Date())
            } while self.shareAgain && !Task.isCancelled
            self.sharing = nil
        }
        sharing = task
        await task.value
    }

    private func shareReadings(now: Date) async {
        let envelope = relayEnvelope(at: now)
        await relay?.publish(envelope, now: now)
        let relayed = Provider.allCases.filter { settings.isEnabled($0) }
        await relay?.publishHistory(history.relayHistory(for: relayed), now: now)
        await sendAlerts(for: envelope.providers, now: now)
        await relay?.pruneEventsIfDue(now: now)
        await refreshNews(now: now)
    }

    private func refreshNow(providers: [Provider]?) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        lastAttempt = now
        let earlierAttempts = lastAttemptAt
        var due: [Provider] = []
        var resting: [Provider] = []
        for provider in providers ?? Provider.allCases where settings.isEnabled(provider) {
            // Times from before the clock was set back don't hold calls off.
            let sinceLast = lastAttemptAt[provider].map { now.timeIntervalSince($0) }
            if let until = rateLimitedUntil[provider], until > now, until.timeIntervalSince(now) <= ProviderStatus.longestRetry {
                // No call before its Retry-After, but a cheap local reading (Claude's status
                // line) still counts meanwhile.
                resting.append(provider)
            } else if let sinceLast, sinceLast >= 0, sinceLast < provider.minimumInterval {
                // Spacing counts from the last call, so failures don't bring the next one closer.
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
            var unreachable: [Provider] = []
            for await (provider, result) in group {
                // Cut short (the Mac went to sleep, or Tokenroom is quitting): not a failure, and
                // not an attempt, so the next refresh asks again.
                if Task.isCancelled, case .failure = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                    continue
                }
                // No login at all: nothing was called, so the next check isn't spaced out. (An
                // expired session may have been refused by the server, which keeps the spacing.)
                if case .failure(.signedOut) = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                }
                if case .failure(.unreachable) = result {
                    unreachable.append(provider)
                }
                apply(provider: provider, result: result)
            }
            // Every call failed to connect: the Mac was offline (awake before its Wi-Fi), so none
            // of them was a call to space out. One provider alone can't tell an outage from that.
            let called = due.filter { clients[$0] != nil }
            if called.count >= 2, unreachable.count == called.count {
                for provider in unreachable {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                }
            }
        }
        guard !Task.isCancelled else { return }
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

    /// This Mac's alert choices in step with the shared copy: takes what the iPhone changed, and
    /// sends what was changed here (again, if iCloud was away), so Settings shows both.
    func currentAlertPreferences(now: Date = .now) async -> AlertPreferences {
        let local = settings.alertPreferences
        let preferences = await relay?.syncAlertPreferences(local: local, now: now) ?? local
        if preferences != local {
            if settings.alertPreferences == local {
                settings.alertPreferences = preferences
            } else {
                // Changed in Settings meanwhile: that change stays, on top of what came in.
                settings.alertPreferences = AlertPreferences.merged(base: local, local: settings.alertPreferences, remote: preferences)
            }
        }
        return settings.alertPreferences
    }

    /// Alert choices changed in Settings on this Mac: saved at once, and shared on top of the
    /// newest copy in iCloud, so a choice made on the iPhone meanwhile isn't undone.
    func updateAlertPreferences(_ change: (inout AlertPreferences) -> Void, now: Date = .now) {
        var preferences = settings.alertPreferences
        change(&preferences)
        guard preferences != settings.alertPreferences else { return }
        preferences.touch(now: now)
        settings.alertPreferences = preferences
        guard relay != nil else { return }
        Task { _ = await currentAlertPreferences() }
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
            // The pace this Mac measured from its frequent readings, for readers with hourly
            // history. Measured as of the newest reading, which can come after `now`.
            let at = max(now, checkedAt[provider] ?? now)
            let paces = relayed.isLive ? windowPaces(for: provider, now: at) : [:]
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
        // Claude's direct read gives reset times to the microsecond and its status line to the
        // second: the same reset within a minute isn't a change.
        if sameMinute(a.resetsAt, b.resetsAt) {
            a.resetsAt = b.resetsAt
        }
        for index in a.windows.indices {
            guard let match = b.windows.first(where: { $0.id == a.windows[index].id }) else { continue }
            if sameMinute(a.windows[index].resetsAt, match.resetsAt) {
                a.windows[index].resetsAt = match.resetsAt
            }
            if sameMinute(a.windows[index].startsAt, match.startsAt) {
                a.windows[index].startsAt = match.startsAt
            }
        }
        return a == b
    }

    private nonisolated static func sameMinute(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < 60
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
