import Foundation

/// A week of hourly usage per window, kept in Application Support/Tokenroom/history.json, plus
/// the last six hours of raw readings in memory for pace. Percentages only.
@MainActor
final class HistoryStore {
    /// Raw readings kept for pace: six hours at a five-minute refresh.
    static let recentCapacity = 72

    private(set) var weeks: [String: UsageHistory] = [:]
    private var recent: [String: [(date: Date, used: Double)]] = [:]
    private var dirty = false
    private let fileURL: URL?

    init(directory: URL? = SnapshotCache.defaultDirectory) {
        fileURL = directory?.appendingPathComponent("history.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? RelayEnvelope.decoder.decode([String: UsageHistory].self, from: data) {
            weeks = saved
        }
    }

    func record(_ snapshot: QuotaSnapshot) {
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var week = weeks[key] ?? UsageHistory(endingAt: snapshot.fetchedAt)
            if week.record(window.usedPercent, at: snapshot.fetchedAt) || weeks[key] == nil {
                weeks[key] = week
                dirty = true
            }
            var samples = recent[key] ?? []
            if samples.last?.date != snapshot.fetchedAt {
                samples.append((snapshot.fetchedAt, window.usedPercent))
                if samples.count > Self.recentCapacity {
                    samples.removeFirst(samples.count - Self.recentCapacity)
                }
                recent[key] = samples
            }
        }
    }

    /// Readings for pace: raw recent ones, else the hourly week.
    func samples(provider: Provider, window: String) -> [(date: Date, used: Double)] {
        let key = RelayHistory.key(provider: provider.rawValue, window: window)
        if let recent = recent[key], recent.count >= 3 {
            return recent
        }
        return weeks[key]?.points ?? []
    }

    /// History to relay, limited to the given providers.
    func relayHistory(for providers: [Provider]) -> RelayHistory {
        let ids = Set(providers.map(\.rawValue))
        return RelayHistory(series: weeks.filter { key, week in
            guard let provider = key.split(separator: "/").first else { return false }
            return ids.contains(String(provider)) && !week.isEmpty
        })
    }

    func saveIfNeeded() {
        guard dirty, let fileURL else { return }
        dirty = false
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? RelayEnvelope.encoder.encode(weeks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
