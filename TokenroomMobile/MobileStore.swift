import CloudKit
import Foundation
import Observation
import os

/// Everything the iPhone shows: readings your Macs relay through iCloud, providers read with keys
/// added on this iPhone, or sample data. Saves the merged readings for widgets and, while this
/// iPhone has keys, relays its own readings to your other devices. Readings only: keys never
/// leave this iPhone's Keychain.
@Observable
@MainActor
final class MobileStore {
    enum RelayPhase: Equatable {
        case idle
        case loading
        case ready
        /// This build has no iCloud container (an unsigned build).
        case unavailable
        case noAccount
        case failed(String)
    }

    /// One provider to show, and where its reading came from.
    struct Reading: Identifiable, Equatable {
        var provider: RelayProvider
        var source: String
        /// A week of hourly usage per window ID, when the source sent it.
        var history: [String: UsageHistory]
        var pace: Pace?

        var id: String { provider.id }

        var primaryHistory: UsageHistory? {
            provider.primaryWindow.flatMap { history[$0.id] }
        }
    }

    enum Keys {
        static let sourceID = "relaySourceID"
        static let sampleMode = "sampleMode"
        static let onboarded = "onboarded"
        static let budgets = "budgets"
        static let published = "relayPublished"
    }

    static let localLabel = "This iPhone"
    /// Coming back to the app refreshes once this much time has passed.
    static let foregroundInterval: TimeInterval = 60

    private(set) var relayPhase: RelayPhase = .idle
    /// Other collectors' records; this iPhone's own record is left out.
    private(set) var relaySources: [CloudRelay.Source] = []
    private(set) var relayHistories: [String: RelayHistory] = [:]
    private(set) var localStatuses: [Provider: ProviderStatus] = [:]
    private(set) var localCheckedAt: [Provider: Date] = [:]
    /// Connected providers, most urgent first.
    private(set) var readings: [Reading] = []
    /// Providers a Mac reports as signed out or not on a plan.
    private(set) var disconnected: [Reading] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Providers with a key on this iPhone.
    private(set) var keyedProviders: [Provider] = []

    var sampleMode: Bool {
        didSet {
            defaults.set(sampleMode, forKey: Keys.sampleMode)
            rebuild()
        }
    }

    var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    let keys: APIKeyStore
    let sourceID: String
    private let relay: CloudRelay?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let cacheURL: URL?
    private var publishPolicy = RelayPublishPolicy()
    private var lastHistoryHour: Date?
    private var lastCacheHash: Int?
    private var rateLimitedUntil: [Provider: Date] = [:]
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "store")

    init(
        defaults: UserDefaults = .standard,
        containerIdentifier: String? = RelayAvailability.containerIdentifier,
        keys: APIKeyStore = APIKeyStore(accessGroup: AppGroup.keychainGroup),
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        self.defaults = defaults
        self.keys = keys
        if let existing = defaults.string(forKey: Keys.sourceID) {
            sourceID = existing
        } else {
            sourceID = "src-\(UUID().uuidString.lowercased())"
            defaults.set(sourceID, forKey: Keys.sourceID)
        }
        relay = containerIdentifier.map(CloudRelay.init(containerIdentifier:))
        relayPhase = relay == nil ? .unavailable : .idle
        history = HistoryStore(directory: directory)
        cacheURL = directory?.appendingPathComponent(ReadingCache.fileName)
        sampleMode = defaults.bool(forKey: Keys.sampleMode)
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        showCachedReadings()
    }

    // MARK: Refresh

    /// Reads the relay and this iPhone's keys. Without `force`, does nothing within a minute of
    /// the last refresh.
    /// - Parameter includeKeys: false for a silent push, which only means a Mac sent new readings.
    func refresh(force: Bool = false, includeKeys: Bool = true, now: Date = .now) async {
        guard !isRefreshing else { return }
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.foregroundInterval { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = now

        async let relayRead: Void = readRelay()
        async let keyRead: Void = includeKeys ? readKeys(force: force, now: now) : ()
        _ = await (relayRead, keyRead)

        rebuild(now: now)
        await publish(now: now)
        history.saveIfNeeded()
    }

    private func readRelay() async {
        guard let relay else {
            relayPhase = .unavailable
            return
        }
        if relaySources.isEmpty {
            relayPhase = .loading
        }
        do {
            guard try await relay.accountStatus() == .available else {
                relayPhase = .noAccount
                return
            }
            let contents = try await relay.contents()
            relaySources = contents.sources.filter { $0.id != sourceID }
            relayHistories = contents.histories
            relayPhase = .ready
        } catch {
            logger.error("relay read failed: \(String(describing: error), privacy: .public)")
            relayPhase = .failed("Couldn't reach iCloud.")
        }
    }

    private func readKeys(force: Bool, now: Date) async {
        let keys = self.keys
        let providers = await BlockingIO.run {
            Provider.allCases.filter { $0.usesAPIKey && keys.hasKey(for: $0) }
        }
        keyedProviders = providers
        for provider in localStatuses.keys where !providers.contains(provider) {
            localStatuses[provider] = nil
            localCheckedAt[provider] = nil
        }
        let due = providers.filter { provider in
            if let until = rateLimitedUntil[provider], until > now { return false }
            if !force, let last = localCheckedAt[provider], now.timeIntervalSince(last) < provider.minimumInterval { return false }
            return true
        }
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in due {
                if localStatuses[provider] == nil {
                    localStatuses[provider] = .loading
                }
                group.addTask {
                    await (provider, Self.fetch(APIKeyClient(provider: provider, keys: keys)))
                }
            }
            for await (provider, result) in group {
                apply(provider, result: result, now: now)
            }
        }
    }

    /// One provider's check, given up on after its budget.
    private nonisolated static func fetch(_ client: APIKeyClient) async -> Result<QuotaSnapshot, ProviderError> {
        await withTaskGroup(of: Result<QuotaSnapshot, ProviderError>?.self) { group in
            group.addTask { await client.fetch() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(client.fetchBudget * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.unreachable)
        }
    }

    private func apply(_ provider: Provider, result: Result<QuotaSnapshot, ProviderError>, now: Date) {
        switch result {
        case .success(let raw):
            let snapshot = raw.applyingBudget(budget(for: provider))
            localStatuses[provider] = .live(snapshot)
            localCheckedAt[provider] = snapshot.fetchedAt
            rateLimitedUntil[provider] = nil
            history.record(snapshot)
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: localStatuses[provider]?.snapshot, lastChecked: localCheckedAt[provider], now: now)
            if case .rateLimited(let until, _) = next {
                rateLimitedUntil[provider] = until
            }
            localStatuses[provider] = next
        }
    }

    // MARK: Merged readings

    private func showCachedReadings() {
        if sampleMode {
            rebuild()
            return
        }
        guard let cacheURL, let cache = ReadingCache.load(from: cacheURL), !cache.isSample else { return }
        readings = cache.items.map { item in
            Reading(provider: item.provider, source: item.source, history: item.history, pace: nil)
        }
    }

    private func rebuild(now: Date = .now) {
        if sampleMode {
            let cache = SampleData.cache(now: now)
            readings = cache.items.map { item in
                Reading(provider: item.provider, source: item.source, history: item.history,
                        pace: UsageRanking.pace(for: item.provider, history: item.provider.primaryWindowID.flatMap { item.history[$0] }, now: now))
            }
            disconnected = []
            saveCache(cache)
            return
        }

        var sources = relaySources.compactMap { source in
            source.envelope.map { RelayMerge.Source(id: source.id, label: source.label, envelope: $0) }
        }
        if !localStatuses.isEmpty {
            sources.append(RelayMerge.Source(id: sourceID, label: Self.localLabel, envelope: localEnvelope(now: now)))
        }
        let all = RelayMerge.entries(from: sources, now: now).map { entry in
            let history = histories(for: entry)
            return Reading(
                provider: entry.provider,
                source: entry.sourceLabel,
                history: history,
                pace: UsageRanking.pace(for: entry.provider, history: entry.provider.primaryWindowID.flatMap { history[$0] }, now: now)
            )
        }
        readings = UsageRanking.sorted(all.filter { !$0.provider.isDisconnected }, provider: \.provider, pace: \.pace)
        disconnected = all.filter(\.provider.isDisconnected).sorted { $0.provider.name < $1.provider.name }
        saveCache(ReadingCache(
            savedAt: now,
            isSample: false,
            items: readings.map { ReadingCache.Item(provider: $0.provider, source: $0.source, history: $0.history) }
        ))
    }

    private func histories(for entry: RelayMerge.Entry) -> [String: UsageHistory] {
        let prefix = entry.provider.id + "/"
        let series: [String: UsageHistory]
        if entry.sourceID == sourceID {
            series = history.weeks
        } else {
            series = relayHistories[entry.sourceID]?.series ?? [:]
        }
        var result: [String: UsageHistory] = [:]
        for (key, week) in series where key.hasPrefix(prefix) && !week.isEmpty {
            result[String(key.dropFirst(prefix.count))] = week
        }
        return result
    }

    /// Widgets redraw from this; it's only rewritten when what they'd draw changed.
    private func saveCache(_ cache: ReadingCache) {
        guard let cacheURL else { return }
        let hash = cache.materialHash
        guard hash != lastCacheHash else { return }
        do {
            try cache.save(to: cacheURL)
            lastCacheHash = hash
        } catch {
            logger.error("cache save failed: \(String(describing: error), privacy: .public)")
        }
    }

    func reading(id: String) -> Reading? {
        readings.first { $0.id == id } ?? disconnected.first { $0.id == id }
    }

    /// When the freshest source last checked.
    var lastChecked: Date? {
        readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max()
    }

    /// Where readings came from, e.g. "Mac" or "Mac and This iPhone".
    var sourceSummary: String? {
        let labels = Array(Set(readings.map(\.source))).sorted()
        switch labels.count {
        case 0: return nil
        case 1: return labels[0]
        default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }

    var needsNewerApp: Bool {
        relaySources.contains(where: \.needsNewerApp)
    }

    // MARK: This iPhone as a source

    private func localEnvelope(now: Date) -> RelayEnvelope {
        let providers = keyedProviders.map { provider in
            RelayProvider(provider: provider, status: localStatuses[provider] ?? .loading, checkedAt: localCheckedAt[provider])
        }
        return RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: providers)
    }

    /// Relays what this iPhone read with its keys, so the Watch and other devices can show it.
    /// Once this iPhone has published, it keeps its record current, even when that's empty.
    private func publish(now: Date) async {
        guard let relay, relayPhase == .ready, !sampleMode else { return }
        let published = defaults.bool(forKey: Keys.published)
        guard !keyedProviders.isEmpty || published else { return }
        let envelope = localEnvelope(now: now)
        if publishPolicy.isDue(envelope, now: now) {
            do {
                try await relay.publish(sourceID: sourceID, kind: "iphone", label: "iPhone", envelope: envelope)
                publishPolicy.didSend(envelope, at: now)
                defaults.set(true, forKey: Keys.published)
            } catch {
                logger.error("relay publish failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        let hour = UsageHistory.hourStart(now)
        let relayHistory = history.relayHistory(for: keyedProviders)
        guard lastHistoryHour != hour, !relayHistory.series.isEmpty else { return }
        do {
            try await relay.publishHistory(sourceID: sourceID, history: relayHistory)
            lastHistoryHour = hour
        } catch {
            logger.error("relay history failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes every Tokenroom record in iCloud, from every device. Macs with sync on send fresh
    /// readings on their next check.
    func deleteICloudData() async throws {
        guard let relay else { return }
        try await relay.deleteAllData()
        relaySources = []
        relayHistories = [:]
        publishPolicy.reset()
        lastHistoryHour = nil
        defaults.set(false, forKey: Keys.published)
        rebuild()
    }

    /// Subscribes to source changes (silent) and alert events (visible notifications).
    func prepareNotifications() async {
        guard let relay else { return }
        do {
            try await relay.ensureSubscriptions()
        } catch {
            logger.error("subscriptions failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Keys and budgets

    func metadata(for provider: Provider) async -> APIKeyStore.Metadata? {
        let keys = self.keys
        return await BlockingIO.run { keys.metadata(for: provider) }
    }

    func saveKey(_ key: String, for provider: Provider, region: String?) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.save(key, for: provider, region: region) }
        hasOnboarded = true
        if sampleMode {
            sampleMode = false
        }
        await refresh(force: true)
    }

    func removeKey(for provider: Provider) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.remove(for: provider) }
        localStatuses[provider] = nil
        localCheckedAt[provider] = nil
        await refresh(force: true)
    }

    func budget(for provider: Provider) -> Double? {
        (defaults.dictionary(forKey: Keys.budgets) as? [String: Double])?[provider.rawValue]
    }

    func setBudget(_ value: Double?, for provider: Provider) {
        var budgets = (defaults.dictionary(forKey: Keys.budgets) as? [String: Double]) ?? [:]
        budgets[provider.rawValue] = value.flatMap { $0 > 0 ? $0 : nil }
        defaults.set(budgets, forKey: Keys.budgets)
        Task { await refresh(force: true) }
    }

    var relayStatusText: String {
        switch relayPhase {
        case .idle, .loading: "Checking…"
        case .ready: relaySources.isEmpty ? "No Mac yet" : "Connected"
        case .unavailable: "Not available in this build"
        case .noAccount: "Sign in to iCloud in Settings"
        case .failed(let message): message
        }
    }
}
