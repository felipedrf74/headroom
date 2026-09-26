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

extension ReadingCache {
    /// Other devices' readings in this cache, as merge sources with their history. They stand in
    /// while iCloud can't be read, so a reader doesn't drop to only this iPhone's providers; each
    /// is dated by its own checks, so it ages out if iCloud stays away.
    func carriedSources(excluding localLabel: String) -> [(source: RelayMerge.Source, history: RelayHistory)] {
        guard !isSample else { return [] }
        let others = Dictionary(grouping: items.filter { $0.source != localLabel }, by: \.source)
        return others.keys.sorted().map { label in
            let items = others[label] ?? []
            var series: [String: UsageHistory] = [:]
            for item in items {
                for (window, week) in item.history {
                    series[RelayHistory.key(provider: item.id, window: window)] = week
                }
            }
            let checkedAt = items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max() ?? savedAt
            let envelope = RelayEnvelope(producer: "cache", appVersion: TokenroomIdentity.version, checkedAt: checkedAt, providers: items.map(\.provider))
            return (RelayMerge.Source(id: "previous-" + label, label: label, envelope: envelope), RelayHistory(series: series))
        }
    }
}
