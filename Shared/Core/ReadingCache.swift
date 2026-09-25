import Foundation

/// The iPhone's last merged readings, saved in the App Group so its widgets can show them without
/// a network call. Readings only, like the relay records: never keys, tokens, or identities.
struct ReadingCache: Codable, Equatable, Sendable {
    static let version = 1
    static let fileName = "readings.json"

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var provider: RelayProvider
        /// The collector it came from, e.g. "Mac", "This iPhone", or "Sample".
        var source: String
        /// A week of hourly usage per window ID, when the collector sent it.
        var history: [String: UsageHistory] = [:]

        var id: String { provider.id }
    }

    var v: Int = ReadingCache.version
    var savedAt: Date
    var isSample: Bool
    /// Most urgent first.
    var items: [Item]

    /// When the freshest reading was last confirmed.
    var checkedAt: Date? {
        items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max()
    }

    /// Changes only when what widgets draw changes, not on every check.
    var materialHash: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        hasher.combine(items.map(\.id))
        hasher.combine(RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).materialHash)
        return hasher.finalize()
    }

    static var defaultURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    /// Nil when missing, damaged, or written by a newer version.
    static func load(from url: URL) -> ReadingCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? RelayEnvelope.decoder.decode(ReadingCache.self, from: data),
              cache.v <= version
        else { return nil }
        return cache
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RelayEnvelope.encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// When widgets and complications ask for their next timeline: every 30 minutes while a live
/// window is at 80% or more and resets within 12 hours, when fresh readings matter most,
/// otherwise hourly. A month-long budget sitting at 85% doesn't need more. Countdowns tick and
/// meters roll over at resets without a reload, and the apps reload widgets themselves when
/// readings change, so a day stays under WidgetKit's budget of about 40 reloads.
enum WidgetSchedule {
    static let busyInterval: TimeInterval = 30 * 60
    static let calmInterval: TimeInterval = 60 * 60
    static let busyUse = 80.0
    static let busyHorizon: TimeInterval = 12 * 3600

    static func nextReload(after now: Date, items: [ReadingCache.Item]) -> Date {
        let busy = items.map { $0.rolledOver(at: now) }.contains { item in
            item.provider.isLive && item.provider.windows.contains { window in
                guard window.isMetered, window.used >= busyUse, let resetsAt = window.resetsAt else { return false }
                return resetsAt.timeIntervalSince(now) <= busyHorizon
            }
        }
        return now.addingTimeInterval(busy ? busyInterval : calmInterval)
    }
}
