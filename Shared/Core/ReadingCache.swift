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
