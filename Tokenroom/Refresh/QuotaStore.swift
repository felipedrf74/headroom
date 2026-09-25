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
    private var alertLedger: AlertLedger

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var rateLimitedUntil: [Provider: Date] = [:]
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
        showsLegacyNotice: Bool = false
    ) {
        self.settings = settings
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.cache = cache
        self.relay = relay
        self.history = HistoryStore(directory: cache.directory)
        self.alertLedger = AlertLedger.load(from: cache.directory)
        self.showsLegacyNotice = showsLegacyNotice
        self.signIn = SignInCoordinator()
        let cached = cache.load()
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
            if force {
                inFlight.cancel()
                await inFlight.value
            } else {
                await inFlight.value
                return
            }
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
        inFlight = nil
    }

    private func refreshNow(providers: [Provider]?) async {
        isRefreshing = true
        let now = Date()
        lastAttempt = now
        let enabled = (providers ?? Provider.allCases).filter { provider in
            guard settings.isEnabled(provider) else { return false }
            // A provider that answered 429 is left alone until its Retry-After passes.
            if let until = rateLimitedUntil[provider], until > now { return false }
            if let last = checkedAt[provider], now.timeIntervalSince(last) < provider.minimumInterval { return false }
            return true
        }
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in enabled {
                guard let client = clients[provider] else { continue }
                group.addTask {
                    await (provider, Self.fetchWithBudget(client))
                }
            }
            for await (provider, result) in group {
                apply(provider: provider, result: result)
            }
        }
        persistLiveSnapshots()
        history.saveIfNeeded()
        isRefreshing = false
        let envelope = relayEnvelope(at: now)
        await relay?.publish(envelope)
        let relayed = Provider.allCases.filter { settings.isEnabled($0) }
        await relay?.publishHistory(history.relayHistory(for: relayed), now: now)
        await sendAlerts(for: envelope.providers, now: now)
    }

    /// Alerts for crossings since the last refresh: to the iPhone through iCloud, and on this Mac
    /// when turned on. Each goes out once, from whichever device saw it first.
    private func sendAlerts(for providers: [RelayProvider], now: Date) async {
        let preferences = await relay?.alertPreferences(now: now) ?? AlertPreferences()
        let alerts = alertLedger.process(providers, preferences: preferences, now: now)
        alertLedger.save(to: cache.directory)
        guard !alerts.isEmpty else { return }
        await relay?.sendAlerts(alerts, preferences: preferences, now: now)
        if settings.showsAlertsOnMac {
            MacAlerts.post(alerts.filter { preferences.shouldSend($0, at: now) })
        }
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

    /// Enabled providers as the iPhone and Watch will see them.
    func relayEnvelope(at now: Date) -> RelayEnvelope {
        let providers = Provider.allCases.filter { settings.isEnabled($0) }.map { provider in
            RelayProvider(provider: provider, status: statuses[provider] ?? .loading, checkedAt: checkedAt[provider])
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
        popoverProviders.filter(isDisconnected)
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

    private static func fetchWithBudget(_ client: any ProviderClient) async -> Result<QuotaSnapshot, ProviderError> {
        await withTaskGroup(of: Result<QuotaSnapshot, ProviderError>?.self) { group in
            group.addTask { await client.fetch() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(client.fetchBudget * 1_000_000_000))
                return nil
            }
            var result: Result<QuotaSnapshot, ProviderError> = .failure(.unreachable)
            while let next = await group.next() {
                if let next {
                    result = next
                    group.cancelAll()
                    break
                }
                group.cancelAll()
                break
            }
            return result
        }
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

    private static func usageEqual(_ a: QuotaSnapshot, _ b: QuotaSnapshot) -> Bool {
        a.provider == b.provider
            && a.usedPercent == b.usedPercent
            && a.resetsAt == b.resetsAt
            && a.primaryTitle == b.primaryTitle
            && a.windows == b.windows
            && a.planLabel == b.planLabel
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
