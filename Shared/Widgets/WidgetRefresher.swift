import Foundation
import Synchronization

/// Readings for widgets: the app's cache, refreshed here when it's old, within a few seconds.
/// Reads the relay and this iPhone's keys like the app does, but never writes to iCloud.
enum WidgetRefresher {
    /// A cache older than this is refreshed before a timeline is built.
    static let maxAge: TimeInterval = 15 * 60
    /// The most time a widget spends fetching.
    static let budget: TimeInterval = 6
    /// iCloud and each key provider get a second under the widget's own limit, so a slow one
    /// doesn't cost the rest and there's time to put what came back together.
    static let readBudget = budget - 1
    static let localLabel = "This iPhone"

    static func cache(force: Bool = false, now: Date = .now) async -> ReadingCache? {
        if AppGroup.defaults.bool(forKey: "sampleMode") {
            return SampleData.cache(now: now)
        }
        let cached = ReadingCache.defaultURL.flatMap(ReadingCache.load)
        if !force, let cached, now.timeIntervalSince(cached.savedAt) < maxAge {
            return cached
        }
        // Widgets whose timelines are due together share one refresh, rather than each reading
        // iCloud and calling every key provider.
        let task = running.withLock { running -> Task<ReadingCache?, Never> in
            if let running {
                return running
            }
            let task = Task { await TimeLimit.run(budget, otherwise: nil) { await refresh(previous: cached, now: now) } }
            running = task
            return task
        }
        let refreshed = await task.value
        running.withLock { running in
            if running == task {
                running = nil
            }
        }
        return refreshed ?? cached
    }

    /// The refresh under way in this process.
    private static let running = Mutex<Task<ReadingCache?, Never>?>(nil)

    /// Saves what it read for the app and the other widgets.
    static func refresh(previous: ReadingCache?, now: Date) async -> ReadingCache? {
        // Samples left from sample mode never stand in for real readings.
        let previous = previous?.isSample == true ? nil : previous
        let defaults = AppGroup.defaults
        let ownID = defaults.string(forKey: "relaySourceID")
        async let relayRead = readRelay()
        async let keyRead = readKeys(defaults: defaults, now: now)
        let (contents, (fresh, readings)) = await (relayRead, keyRead)
        guard contents != nil || !fresh.isEmpty else { return nil }
        // For the week's history: the app records these the next time it refreshes.
        HistoryStore.queue(readings, in: AppGroup.containerURL)

        // This iPhone's providers: what was just read, else the newer of its last relayed and
        // cached readings.
        let ownRecord = contents?.sources.first { $0.id == ownID }?.envelope
        let previousOwn = previous?.items.filter { $0.source == localLabel }.map(\.provider) ?? []
        // As in the app: only providers that still have a key, and readings up to a week old.
        let keyed = (defaults.array(forKey: "keyedProviders") as? [String]).map(Set.init)
        var own = fresh
        for provider in (ownRecord?.providers ?? []) + previousOwn where !fresh.contains(where: { $0.id == provider.id }) {
            guard keyed?.contains(provider.id) ?? true,
                  let time = Self.readingTime(provider), now.timeIntervalSince(time) < RelayMerge.maxSourceAge
            else { continue }
            if let index = own.firstIndex(where: { $0.id == provider.id }) {
                if Self.readingTime(provider) ?? .distantPast > Self.readingTime(own[index]) ?? .distantPast {
                    own[index] = provider
                }
            } else {
                own.append(provider)
            }
        }

        var sources = (contents?.sources ?? []).compactMap { source -> RelayMerge.Source? in
            guard source.id != ownID, let envelope = source.envelope else { return nil }
            return RelayMerge.Source(id: source.id, label: source.label, envelope: envelope)
        }
        var histories = contents?.histories ?? [:]
        if contents == nil, let previous {
            // iCloud didn't answer in time: the other devices' readings from last time stay,
            // rather than leaving only this iPhone's.
            for carried in previous.carriedSources(excluding: localLabel) {
                sources.append(carried.source)
                histories[carried.source.id] = carried.history
            }
        }
        if let ownID, !own.isEmpty {
            sources.append(RelayMerge.Source(
                id: ownID,
                label: localLabel,
                envelope: RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: own)
            ))
            histories[ownID] = RelayHistory(series: HistoryStore.loadWithPending(from: AppGroup.containerURL, now: now))
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: histories, now: now)
        let cache = ReadingCache(savedAt: now, isSample: false, items: output.connected)
        if let url = ReadingCache.defaultURL {
            try? cache.save(to: url)
        }
        return cache
    }

    private static func readingTime(_ provider: RelayProvider) -> Date? {
        provider.checkedAt ?? provider.fetchedAt
    }

    /// Nil without iCloud, or when it doesn't answer within its share of the widget's seconds;
    /// `refresh` then keeps the other devices' last readings beside this iPhone's fresh ones.
    private static func readRelay() async -> CloudRelay.Contents? {
        guard let container = RelayAvailability.containerIdentifier else { return nil }
        return await TimeLimit.run(readBudget, otherwise: nil) {
            let relay = CloudRelay(containerIdentifier: container)
            guard (try? await relay.accountStatus()) == .available else { return nil }
            return try? await relay.contents()
        }
    }

    /// Providers read with this iPhone's keys, and the readings themselves (with budgets) for
    /// history. Ones that failed, or that are resting between calls (spacing, a 429), are left
    /// out, so an older reading stands in for them.
    private static func readKeys(defaults: UserDefaults, now: Date) async -> (providers: [RelayProvider], readings: [QuotaSnapshot]) {
        let keys = APIKeyStore(accessGroup: AppGroup.keychainGroup)
        let gate = KeyFetchGate(defaults: defaults)
        let providers = await BlockingIO.run {
            Provider.allCases.filter { $0.readsWithKey && keys.hasKey(for: $0) }
        }.filter { !gate.isResting($0, now: now) }
        guard !providers.isEmpty else { return ([], []) }
        let budgets = defaults.dictionary(forKey: "budgets") as? [String: Double] ?? [:]
        for provider in providers {
            gate.recordAttempt(provider, at: now)
        }
        let snapshots = await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in providers {
                group.addTask {
                    await (provider, APIKeyClient(provider: provider, keys: keys).fetchWithinBudget(readBudget))
                }
            }
            var snapshots: [QuotaSnapshot] = []
            for await (provider, result) in group {
                switch result {
                case .success(let snapshot):
                    gate.block(provider, until: nil)
                    snapshots.append(snapshot)
                case .failure(.rateLimited(let until)):
                    gate.block(provider, until: ProviderStatus.clampedRetry(until, now: now))
                case .failure:
                    break
                }
            }
            return snapshots
        }
        let readings = providers.compactMap { provider in
            snapshots.first { $0.provider == provider }.map { $0.applyingBudget(budgets[provider.rawValue]) }
        }
        return (readings.map { RelayProvider(provider: $0.provider, status: .live($0), checkedAt: now) }, readings)
    }
}
