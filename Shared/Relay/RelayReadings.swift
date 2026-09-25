import Foundation

/// Readings straight from iCloud, for devices that read no provider themselves: the Watch and
/// its complications. Every collector's record counts, the iPhone's included.
enum RelayReadings {
    /// Nil when this build has no iCloud container, there's no account, or iCloud didn't answer.
    static func fetch(now: Date = .now) async -> ReadingCache? {
        guard let container = RelayAvailability.containerIdentifier else { return nil }
        let relay = CloudRelay(containerIdentifier: container)
        guard (try? await relay.accountStatus()) == .available,
              let contents = try? await relay.contents()
        else { return nil }
        return cache(from: contents, now: now)
    }

    static func cache(from contents: CloudRelay.Contents, now: Date = .now) -> ReadingCache {
        let sources = contents.sources.compactMap { source in
            source.envelope.map { RelayMerge.Source(id: source.id, label: source.label, envelope: $0) }
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: contents.histories, now: now)
        return ReadingCache(savedAt: now, isSample: false, items: output.connected)
    }

    /// The cache, or a fresh read when it's older than `maxAge`, within `budget` seconds.
    static func cache(at url: URL?, maxAge: TimeInterval, budget: TimeInterval, now: Date = .now) async -> ReadingCache? {
        let cached = url.flatMap(ReadingCache.load)
        if let cached, cached.isSample || now.timeIntervalSince(cached.savedAt) < maxAge {
            return cached
        }
        let fresh = await withTaskGroup(of: ReadingCache?.self) { group in
            group.addTask { await fetch(now: now) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let fresh, let url {
            try? fresh.save(to: url)
        }
        return fresh ?? cached
    }
}
