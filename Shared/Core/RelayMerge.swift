import Foundation

/// Merges what several collectors (Macs, an iPhone with API keys) published into one reading
/// per provider.
enum RelayMerge {
    struct Source: Sendable {
        var id: String
        var label: String
        var envelope: RelayEnvelope
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var provider: RelayProvider
        var sourceID: String
        var sourceLabel: String
        var id: String { provider.id }
    }

    /// Collectors silent for longer than this are left out.
    static let maxSourceAge: TimeInterval = 7 * 86_400

    /// A live reading beats a stale, expired, or signed-out one from another collector; among
    /// equals the most recently checked wins. Sorted with the most used first.
    static func entries(from sources: [Source], now: Date = .now) -> [Entry] {
        var best: [String: (entry: Entry, live: Bool, checked: Date)] = [:]
        for source in sources where now.timeIntervalSince(source.envelope.checkedAt) <= maxSourceAge {
            for provider in source.envelope.providers {
                let live = provider.state == "live"
                let checked = provider.checkedAt ?? provider.fetchedAt ?? source.envelope.checkedAt
                let candidate = (Entry(provider: provider, sourceID: source.id, sourceLabel: source.label), live, checked)
                guard let current = best[provider.id] else {
                    best[provider.id] = candidate
                    continue
                }
                if (live && !current.live) || (live == current.live && checked > current.checked) {
                    best[provider.id] = candidate
                }
            }
        }
        return best.values.map(\.entry).sorted { lhs, rhs in
            let left = lhs.provider.primaryWindow?.used ?? -1
            let right = rhs.provider.primaryWindow?.used ?? -1
            return left == right ? lhs.provider.name < rhs.provider.name : left > right
        }
    }
}
