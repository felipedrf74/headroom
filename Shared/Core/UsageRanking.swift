import Foundation

/// Orders providers by how soon they need attention: a reached limit and a quick run-out first,
/// then the most used. Balances without a limit come last.
enum UsageRanking {
    /// Pace for a provider's headline window.
    static func pace(for provider: RelayProvider, history: UsageHistory?, now: Date = .now) -> Pace? {
        guard let window = provider.primaryWindow, window.isMetered else { return nil }
        return pace(for: window, isStale: !provider.isLive, history: history, now: now)
    }

    static func pace(for window: RelayWindow, isStale: Bool, history: UsageHistory?, now: Date = .now) -> Pace? {
        Pace.evaluate(
            used: window.used,
            kind: window.windowKind,
            resetsAt: window.resetsAt,
            startsAt: window.startsAt,
            windowSeconds: window.periodSec,
            samples: history?.points ?? [],
            measured: window.pace,
            isStale: isStale,
            now: now
        )
    }

    static func urgency(_ pace: Pace?) -> Int {
        guard let pace else { return 0 }
        return urgency(severity: pace.severity)
    }

    private static func urgency(severity: Pace.Severity) -> Int {
        switch severity {
        case .critical: return 3
        case .tight: return 2
        case .watch: return 1
        case .none: return 0
        }
    }

    /// A live limit reached with no reset time (a spent key limit or balance reference) has no
    /// pace to say so, but is as pressing as one that has.
    private static func isReachedWithoutReset(_ provider: RelayProvider) -> Bool {
        guard provider.isLive, let window = provider.primaryWindow else { return false }
        return window.isMetered && window.resetsAt == nil && window.used >= 100
    }

    /// Most urgent first; ties by name.
    static func sorted<Item>(_ items: [Item], provider: (Item) -> RelayProvider, pace: (Item) -> Pace?) -> [Item] {
        let keyed = items.map { item in
            let reading = provider(item)
            let window = reading.primaryWindow
            let level = isReachedWithoutReset(reading) ? urgency(severity: .critical) : urgency(pace(item))
            return (item: item, metered: window?.isMetered ?? false, urgency: level, used: window?.used ?? 0, name: reading.name)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.metered != rhs.metered { return lhs.metered }
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            if lhs.used != rhs.used { return lhs.used > rhs.used }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.item)
    }
}
