import Foundation

/// When each key-read provider was last called, and until when it asked to be left alone. The
/// iPhone app and its widgets run in separate processes; they share this through the App Group,
/// so a widget refresh counts toward Anthropic's 15-minute spacing and honors a 429.
/// UserDefaults is thread-safe, which Swift can't see.
struct KeyFetchGate: @unchecked Sendable {
    private let defaults: UserDefaults
    static let defaultsKey = "keyFetchGate"

    private struct Entry: Codable {
        var attemptAt: Date?
        var blockedUntil: Date?
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    /// Whether a call now would come too soon after the last one, or before a Retry-After.
    func isResting(_ provider: Provider, now: Date = .now) -> Bool {
        guard let entry = entries[provider.rawValue] else { return false }
        if let blocked = entry.blockedUntil, blocked > now { return true }
        if let attempt = entry.attemptAt, now.timeIntervalSince(attempt) < provider.minimumInterval { return true }
        return false
    }

    func recordAttempt(_ provider: Provider, at date: Date = .now) {
        update(provider) { $0.attemptAt = date }
    }

    /// A 429's wait, or nil to clear it after a good answer.
    func block(_ provider: Provider, until date: Date?) {
        update(provider) { $0.blockedUntil = date }
    }

    private var entries: [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func update(_ provider: Provider, _ change: (inout Entry) -> Void) {
        var all = entries
        var entry = all[provider.rawValue] ?? Entry()
        change(&entry)
        all[provider.rawValue] = entry
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
