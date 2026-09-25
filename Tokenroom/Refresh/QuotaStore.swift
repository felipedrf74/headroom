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
    let signIn: SignInCoordinator
    /// Sends readings to iCloud for iPhone and Apple Watch. Nil in tests.
    let relay: RelayPublisher?

    /// How long an expired session keeps showing its last reading (faded).
    static let expiredGrace: TimeInterval = 24 * 60 * 60

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var rateLimitedUntil: [Provider: Date] = [:]
    private var loopTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var snapshotsDirty = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "refresh")

    init(
        settings: AppSettings = AppSettings(),
        clients: [any ProviderClient] = [GrokClient(), GrokBotClient(), ClaudeClient(), OpenAIClient(), CursorClient()],
        cache: SnapshotCache = SnapshotCache(),
        relay: RelayPublisher? = nil,
        showsLegacyNotice: Bool = false
    ) {
        self.settings = settings
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.cache = cache
        self.relay = relay
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
        isRefreshing = false
        await relay?.publish(relayEnvelope(at: now))
    }

    /// Enabled providers as the iPhone and Watch will see them.
    func relayEnvelope(at now: Date) -> RelayEnvelope {
        let providers = Provider.allCases.filter { settings.isEnabled($0) }.map { provider in
            let status = statuses[provider] ?? .loading
            let snapshot = status.snapshot
            return RelayProvider(
                id: provider.rawValue,
                name: provider.displayName,
                shortName: provider.shortName,
                monogram: provider.monogram,
                tint: provider.tintHex,
                state: Self.relayState(status),
                message: Self.relayMessage(status, provider: provider),
                checkedAt: checkedAt[provider],
                fetchedAt: snapshot?.fetchedAt,
                plan: snapshot?.planLabel,
                primaryWindowID: snapshot?.windows.first?.id,
                windows: snapshot?.windows.map {
                    RelayWindow(id: $0.id, kind: $0.kind.rawValue, title: $0.title, used: $0.usedPercent, resetsAt: $0.resetsAt)
                } ?? []
            )
        }
        return RelayEnvelope(
            producer: "mac",
            appVersion: TokenroomIdentity.version,
            checkedAt: now,
            providers: providers
        )
    }

    private static func relayState(_ status: ProviderStatus) -> String {
        switch status {
        case .loading: "loading"
        case .live: "live"
        case .stale: "stale"
        case .signedOut: "signedOut"
        case .expired: "expired"
        case .notEntitled: "notEntitled"
        case .rateLimited: "rateLimited"
        case .unreachable: "unreachable"
        }
    }

    private static func relayMessage(_ status: ProviderStatus, provider: Provider) -> String? {
        switch status {
        case .signedOut(let hint), .expired(let hint, _), .notEntitled(let hint):
            hint
        case .rateLimited(let until, _):
            "Couldn't refresh. \(provider.displayName) asked to wait until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable:
            "Couldn't reach \(provider.displayName)."
        case .loading, .live, .stale:
            nil
        }
    }

    var menuMeters: [MenuMeter] {
        Provider.allCases.compactMap { provider in
            guard settings.isEnabled(provider) else { return nil }
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

    func dismissLegacyNotice() {
        LegacyMigration.dismissNotice()
        showsLegacyNotice = false
    }

    func quitLegacyApp() {
        LegacyMigration.quitLegacyApp()
    }

    static func percentText(_ value: Double) -> String {
        TokenroomFormat.percentText(value)
    }

    private static func fetchWithBudget(_ client: any ProviderClient) async -> Result<QuotaSnapshot, ProviderError> {
        await withTaskGroup(of: Result<QuotaSnapshot, ProviderError>?.self) { group in
            group.addTask { await client.fetch() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(TokenroomHTTP.fetchBudget * 1_000_000_000))
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
        case .success(let snapshot):
            checkedAt[provider] = snapshot.fetchedAt
            rateLimitedUntil[provider] = nil
            if case .live(let old) = statuses[provider], Self.usageEqual(old, snapshot) {
                return
            }
            statuses[provider] = .live(snapshot)
            snapshotsDirty = true
        case .failure(let error):
            let cached = statuses[provider]?.snapshot
            let next: ProviderStatus
            switch error {
            case .signedOut(let hint):
                next = .signedOut(hint)
            case .notEntitled(let hint):
                next = .notEntitled(hint)
            case .expired(let hint):
                next = .expired(hint, cached: recentReading(cached, provider: provider, now: now))
            case .rateLimited(let until):
                let retry = Self.clampedRetry(until, now: now)
                rateLimitedUntil[provider] = retry
                next = .rateLimited(until: retry, cached: cached)
            case .unreachable, .parse:
                if let cached {
                    next = .stale(cached)
                } else {
                    next = .unreachable(cached: nil)
                }
            }
            if statuses[provider] != next {
                statuses[provider] = next
                snapshotsDirty = true
                logger.error("refresh failed \(provider.rawValue, privacy: .public)")
            }
        }
    }

    private func recentReading(_ cached: QuotaSnapshot?, provider: Provider, now: Date) -> QuotaSnapshot? {
        guard let cached else { return nil }
        let checked = checkedAt[provider] ?? cached.fetchedAt
        return now.timeIntervalSince(checked) < Self.expiredGrace ? cached : nil
    }

    /// Honors Retry-After, within one minute to six hours.
    nonisolated static func clampedRetry(_ until: Date?, now: Date) -> Date {
        let wait = until.map { $0.timeIntervalSince(now) } ?? TokenroomHTTP.defaultRetryAfter
        return now.addingTimeInterval(min(max(wait, 60), 6 * 60 * 60))
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
