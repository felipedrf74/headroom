import Foundation

/// Readings for widgets: the app's cache, refreshed here when it's old, within a few seconds.
/// Reads the relay and this iPhone's keys like the app does, but never writes to iCloud.
enum WidgetRefresher {
    /// A cache older than this is refreshed before a timeline is built.
    static let maxAge: TimeInterval = 15 * 60
    /// The most time a widget spends fetching.
    static let budget: TimeInterval = 6
    static let localLabel = "This iPhone"

    static func cache(force: Bool = false, now: Date = .now) async -> ReadingCache? {
        if AppGroup.defaults.bool(forKey: "sampleMode") {
            return SampleData.cache(now: now)
        }
        let cached = ReadingCache.defaultURL.flatMap(ReadingCache.load)
        if !force, let cached, now.timeIntervalSince(cached.savedAt) < maxAge {
            return cached
        }
        let refreshed = await withTaskGroup(of: ReadingCache?.self) { group in
            group.addTask { await refresh(previous: cached, now: now) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return refreshed ?? cached
    }

    /// Saves what it read for the app and the other widgets.
    static func refresh(previous: ReadingCache?, now: Date) async -> ReadingCache? {
        let defaults = AppGroup.defaults
        let ownID = defaults.string(forKey: "relaySourceID")
        async let relayRead = readRelay()
        async let keyRead = readKeys(defaults: defaults, now: now)
        let (contents, fresh) = await (relayRead, keyRead)
        guard contents != nil || !fresh.isEmpty else { return nil }

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
            let others = Dictionary(grouping: previous.items.filter { $0.source != localLabel }, by: \.source)
            for (label, items) in others {
                let id = "previous-" + label
                sources.append(RelayMerge.Source(
                    id: id,
                    label: label,
                    // Dated by their own checks, so they age out if iCloud stays away.
                    envelope: RelayEnvelope(producer: "cache", appVersion: TokenroomIdentity.version,
                                            checkedAt: items.compactMap { Self.readingTime($0.provider) }.max() ?? previous.savedAt,
                                            providers: items.map(\.provider))
                ))
                var series: [String: UsageHistory] = [:]
                for item in items {
                    for (window, week) in item.history {
                        series[RelayHistory.key(provider: item.id, window: window)] = week
                    }
                }
                histories[id] = RelayHistory(series: series)
            }
        }
        if let ownID, !own.isEmpty {
            sources.append(RelayMerge.Source(
                id: ownID,
                label: localLabel,
                envelope: RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: own)
            ))
            histories[ownID] = RelayHistory(series: HistoryStore.load(from: AppGroup.containerURL))
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

    private static func readRelay() async -> CloudRelay.Contents? {
        guard let container = RelayAvailability.containerIdentifier else { return nil }
        let relay = CloudRelay(containerIdentifier: container)
        guard (try? await relay.accountStatus()) == .available else { return nil }
        return try? await relay.contents()
    }

    /// Providers read with this iPhone's keys. Ones that failed, or that are resting between
    /// calls (spacing, a 429), are left out, so an older reading stands in for them.
    private static func readKeys(defaults: UserDefaults, now: Date) async -> [RelayProvider] {
        let keys = APIKeyStore(accessGroup: AppGroup.keychainGroup)
        let gate = KeyFetchGate(defaults: defaults)
        let providers = await BlockingIO.run {
            Provider.allCases.filter { $0.readsWithKey && keys.hasKey(for: $0) }
        }.filter { !gate.isResting($0, now: now) }
        guard !providers.isEmpty else { return [] }
        let budgets = defaults.dictionary(forKey: "budgets") as? [String: Double] ?? [:]
        for provider in providers {
            gate.recordAttempt(provider, at: now)
        }
        let snapshots = await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in providers {
                group.addTask {
                    // A second under the widget's own limit, so a slow provider doesn't cost the rest.
                    await (provider, APIKeyClient(provider: provider, keys: keys).fetchWithinBudget(budget - 1))
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
        return providers.compactMap { provider in
            snapshots.first { $0.provider == provider }.map { snapshot in
                RelayProvider(provider: provider, status: .live(snapshot.applyingBudget(budgets[provider.rawValue])), checkedAt: now)
            }
        }
    }
}
