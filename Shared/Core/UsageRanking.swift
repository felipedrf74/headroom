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
        switch pace.severity {
        case .critical: return 3
        case .tight: return 2
        case .watch: return 1
        case .none: return 0
        }
    }

    /// Most urgent first; ties by name.
    static func sorted<Item>(_ items: [Item], provider: (Item) -> RelayProvider, pace: (Item) -> Pace?) -> [Item] {
        let keyed = items.map { item in
            let reading = provider(item)
            let window = reading.primaryWindow
            return (item: item, metered: window?.isMetered ?? false, urgency: urgency(pace(item)), used: window?.used ?? 0, name: reading.name)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.metered != rhs.metered { return lhs.metered }
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            if lhs.used != rhs.used { return lhs.used > rhs.used }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.item)
    }
}
