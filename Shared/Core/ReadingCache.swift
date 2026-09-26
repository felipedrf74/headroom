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

    /// Whether this can replace `shown`: none of the providers both hold is older here. The
    /// newest reading overall would do instead, but then a provider gone from this one (a key
    /// removed, iCloud data deleted) would hold it back.
    func isAtLeastAsFresh(as shown: ReadingCache) -> Bool {
        let shownTimes = Dictionary(shown.items.map { ($0.id, $0.provider.checkedAt ?? $0.provider.fetchedAt) }, uniquingKeysWith: { first, _ in first })
        return items.allSatisfy { item in
            guard let shownTime = shownTimes[item.id] ?? nil else { return true }
            guard let time = item.provider.checkedAt ?? item.provider.fetchedAt else { return false }
            return time >= shownTime
        }
    }

    /// Measured run-outs, keyed `provider/window` (`RelayEnvelope.runOuts`).
    var runOuts: [String: Date] {
        RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).runOuts
    }

    /// Changes only when what widgets draw changes, not on every check.
    var materialHash: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        hasher.combine(items.map(\.id))
        hasher.combine(RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).materialHash)
        return hasher.finalize()
    }

    /// What a reload asked for from the background is spent on, out of WidgetKit's daily budget:
    /// a provider added or gone, its state, a level crossed (80%, 95%, used up), a window
    /// starting over. Smaller moves wait for the next timeline, which reads the saved readings.
    var reloadSignature: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.provider.state)
            for window in item.provider.windows where window.isMetered {
                hasher.combine(window.id)
                hasher.combine(window.used >= 100 ? 3 : window.used >= 95 ? 2 : window.used >= 80 ? 1 : 0)
                // Rounded, not cut off: a reset worked out as now plus seconds lands a second
                // either side of the hour it's on.
                hasher.combine(window.resetsAt.map { Int(($0.timeIntervalSince1970 / 3600).rounded()) })
            }
        }
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
/// readings change. A widget that has already reloaded 32 times in the last 24 hours, whatever
/// asked for them, waits the hour: 32 half an hour apart and hourly ones after them fit any day
/// within WidgetKit's budget of about 40 reloads a widget, even one that's busy throughout.
enum WidgetSchedule {
    static let busyInterval: TimeInterval = 30 * 60
    static let calmInterval: TimeInterval = 60 * 60
    static let busyUse = 80.0
    static let busyHorizon: TimeInterval = 12 * 3600
    static let busyAllowance = 32

    /// - Parameter reloads: the widget's timeline builds in the last 24 hours, this one included
    ///   (`WidgetReloadLog.record`).
    static func nextReload(after now: Date, items: [ReadingCache.Item], reloads: Int = 0) -> Date {
        guard reloads < busyAllowance else { return now.addingTimeInterval(calmInterval) }
        let busy = items.map { $0.rolledOver(at: now) }.contains { item in
            item.provider.isLive && item.provider.windows.contains { window in
                guard window.isMetered, window.used >= busyUse, let resetsAt = window.resetsAt else { return false }
                return resetsAt.timeIntervalSince(now) <= busyHorizon
            }
        }
        return now.addingTimeInterval(busy ? busyInterval : calmInterval)
    }

    /// When the Watch's Smart Stack offers a live provider's windows: the last 8 hours before the
    /// window a Live Activity would follow resets, and the next half day for its busiest window at
    /// 80% or more. Both, so a session resetting soon doesn't hide a week that's nearly spent.
    static func relevance(of provider: RelayProvider, now: Date) -> [(window: RelayWindow, span: ClosedRange<Date>)] {
        guard provider.isLive else { return [] }
        var spans: [(window: RelayWindow, span: ClosedRange<Date>)] = []
        let followed = provider.windowToFollow(now: now)
        if let followed, let resetsAt = followed.resetsAt {
            spans.append((followed, max(now, resetsAt.addingTimeInterval(-RelayProvider.followHorizon))...resetsAt))
        }
        let busiest = provider.windows.filter { $0.isMetered && $0.used >= busyUse }.max { $0.used < $1.used }
        if let busiest, busiest.id != followed?.id {
            let end = min(busiest.resetsAt ?? now.addingTimeInterval(busyHorizon), now.addingTimeInterval(busyHorizon))
            if end > now {
                spans.append((busiest, now...end))
            }
        }
        return spans
    }
}
