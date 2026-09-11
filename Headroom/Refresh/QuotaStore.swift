import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class QuotaStore {
    var statuses: [Provider: ProviderStatus] = [:]
    var lastAttempt: Date?
    var isRefreshing = false
    var settings: AppSettings
    let signIn: SignInCoordinator

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var loopTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var snapshotsDirty = false
    private let logger = Logger(subsystem: HeadroomIdentity.bundleID, category: "refresh")

    init(
        settings: AppSettings = AppSettings(),
        clients: [any ProviderClient] = [GrokClient(), GrokBotClient(), ClaudeClient(), OpenAIClient(), CursorClient()],
        cache: SnapshotCache = SnapshotCache()
    ) {
        self.settings = settings
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.cache = cache
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
            await inFlight.value
            return
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
        lastAttempt = Date()
        let enabled = (providers ?? Provider.allCases).filter { settings.isEnabled($0) }
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
    }

    var menuMeters: [MenuMeter] {
        Provider.allCases.compactMap { provider in
            guard settings.isEnabled(provider) else { return nil }
            let status = statuses[provider] ?? .loading
            switch status {
            case .signedOut, .expired:
                return nil
            case .unreachable(nil):
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
            case .live(let snapshot), .stale(let snapshot), .unreachable(let snapshot?):
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
        case .expired:
            return "Session expired"
        case .unreachable(nil):
            return "Couldn't reach \(provider.displayName)"
        }
    }

    static func percentText(_ value: Double) -> String {
        HeadroomFormat.percentText(value)
    }

    private static func fetchWithBudget(_ client: any ProviderClient) async -> Result<QuotaSnapshot, ProviderError> {
        await withTaskGroup(of: Result<QuotaSnapshot, ProviderError>.self) { group in
            group.addTask { await client.fetch() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(HeadroomHTTP.fetchBudget * 1_000_000_000))
                return .failure(.unreachable)
            }
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return .failure(.unreachable)
        }
    }

    private func apply(provider: Provider, result: Result<QuotaSnapshot, ProviderError>) {
        switch result {
        case .success(let snapshot):
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
            case .expired(let hint):
                next = .expired(hint)
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

    private static func usageEqual(_ a: QuotaSnapshot, _ b: QuotaSnapshot) -> Bool {
        a.provider == b.provider
            && a.usedPercent == b.usedPercent
            && a.resetsAt == b.resetsAt
            && a.primaryTitle == b.primaryTitle
            && a.windows == b.windows
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
