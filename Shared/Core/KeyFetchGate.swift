import Foundation

/// When each key-read provider was last called, and until when it asked to be left alone. The
/// iPhone app and its widgets run in separate processes; they share this through the App Group,
/// so a widget refresh counts toward Anthropic's 15-minute spacing and honors a 429. Each value
/// is a defaults key of its own, written whole, so one process never overwrites another's
/// values with an older copy. UserDefaults is thread-safe, which Swift can't see.
struct KeyFetchGate: @unchecked Sendable {
    private let defaults: UserDefaults
    /// Where 2.0.0 kept every provider's values together, rewritten on each change.
    static let legacyKey = "keyFetchGate"

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        migrate()
    }

    /// Whether a call now would come too soon after the last one, or before a Retry-After. Times
    /// from before the clock was set back don't count, so they can't hold calls off for as long
    /// as it moved.
    func isResting(_ provider: Provider, now: Date = .now) -> Bool {
        if let blocked = blockedUntil(provider), blocked > now, blocked.timeIntervalSince(now) <= ProviderStatus.longestRetry {
            return true
        }
        if let attempt = lastAttempt(provider) {
            let elapsed = now.timeIntervalSince(attempt)
            if elapsed >= 0, elapsed < provider.minimumInterval { return true }
        }
        return false
    }

    func lastAttempt(_ provider: Provider) -> Date? {
        defaults.object(forKey: Self.attemptKey(provider)) as? Date
    }

    func blockedUntil(_ provider: Provider) -> Date? {
        defaults.object(forKey: Self.blockedKey(provider)) as? Date
    }

    /// A call going out now, or nil to take one back (it was cut short and didn't count).
    func recordAttempt(_ provider: Provider, at date: Date?) {
        defaults.set(date, forKey: Self.attemptKey(provider))
    }

    /// A 429's wait, or nil to clear it after a good answer.
    func block(_ provider: Provider, until date: Date?) {
        defaults.set(date, forKey: Self.blockedKey(provider))
    }

    /// A key saved or removed: the old key's spacing and 429 wait don't apply to the new one.
    func reset(_ provider: Provider) {
        recordAttempt(provider, at: nil)
        block(provider, until: nil)
    }

    private static func attemptKey(_ provider: Provider) -> String {
        "keyFetchGate.\(provider.rawValue).attemptAt"
    }

    private static func blockedKey(_ provider: Provider) -> String {
        "keyFetchGate.\(provider.rawValue).blockedUntil"
    }

    /// Moves 2.0.0's shared entry to the keys above, once.
    private func migrate() {
        guard let data = defaults.data(forKey: Self.legacyKey) else { return }
        defaults.removeObject(forKey: Self.legacyKey)
        struct Entry: Codable {
            var attemptAt: Date?
            var blockedUntil: Date?
        }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (id, entry) in entries {
            guard let provider = Provider(rawValue: id) else { continue }
            if lastAttempt(provider) == nil, let attempt = entry.attemptAt {
                recordAttempt(provider, at: attempt)
            }
            if blockedUntil(provider) == nil, let blocked = entry.blockedUntil {
                block(provider, until: blocked)
            }
        }
    }
}
