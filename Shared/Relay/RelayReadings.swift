import Foundation

/// Readings straight from iCloud, for devices that read no provider themselves: the Watch and
/// its complications. Every collector's record counts, the iPhone's included.
enum RelayReadings {
    enum Outcome: Sendable {
        case readings(ReadingCache)
        /// No iCloud account on this device.
        case noAccount
        /// This build has no iCloud container (not signed for it).
        case unavailable
        /// iCloud didn't answer.
        case failed
    }

    static func read(now: Date = .now) async -> Outcome {
        guard let container = RelayAvailability.containerIdentifier else { return .unavailable }
        let relay = CloudRelay(containerIdentifier: container)
        guard let status = try? await relay.accountStatus() else { return .failed }
        guard status == .available else { return .noAccount }
        guard let contents = try? await relay.contents() else { return .failed }
        return .readings(cache(from: contents, now: now))
    }

    /// Nil when this build has no iCloud container, there's no account, or iCloud didn't answer.
    static func fetch(now: Date = .now) async -> ReadingCache? {
        if case .readings(let cache) = await read(now: now) {
            return cache
        }
        return nil
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
        await cache(at: url, maxAge: maxAge, budget: budget, now: now) { await fetch(now: now) }
    }

    /// - Parameter read: iCloud's readings; tests stand in for it.
    static func cache(
        at url: URL?, maxAge: TimeInterval, budget: TimeInterval, now: Date,
        read: @escaping @Sendable () async -> ReadingCache?
    ) async -> ReadingCache? {
        let cached = url.flatMap(ReadingCache.load)
        if let cached, isRecent(cached, maxAge: maxAge, now: now) {
            return cached
        }
        let fresh = await TimeLimit.run(budget, otherwise: nil, read)
        if let fresh, let url {
            try? fresh.save(to: url)
        }
        return fresh ?? cached
    }

    #if DEBUG
    /// Screenshots: a sample cache saved on the Watch stays until real readings replace it. The
    /// iPhone doesn't hand samples over any more; release builds let an old one age out.
    static let keepsSamples = true
    #else
    static let keepsSamples = false
    #endif

    /// Whether `cached` can be shown without reading iCloud first. Outside debug builds a sample
    /// cache ages like any other, so it doesn't outlive sample mode.
    static func isRecent(_ cached: ReadingCache, maxAge: TimeInterval, now: Date, keepsSamples: Bool = RelayReadings.keepsSamples) -> Bool {
        (keepsSamples && cached.isSample) || now.timeIntervalSince(cached.savedAt) < maxAge
    }
}
