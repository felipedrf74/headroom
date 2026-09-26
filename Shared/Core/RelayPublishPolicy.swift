import Foundation

/// When a collector sends its readings: when usage changed or a measured run-out moved an hour
/// (at most every 5 minutes), when a provider's status changed or a window crossed an alert
/// threshold (after a minute), and every 30 minutes as a heartbeat so readers can tell it's alive.
struct RelayPublishPolicy: Sendable, Equatable {
    static let heartbeat: TimeInterval = 30 * 60
    static let minimumInterval: TimeInterval = 5 * 60
    static let statusInterval: TimeInterval = 60

    private(set) var lastHash: Int?
    private(set) var lastStates: [String: String] = [:]
    private(set) var lastLevels: [String: Int] = [:]
    private(set) var lastRunOuts: [String: Date] = [:]
    private(set) var lastSent: Date?

    func isDue(_ envelope: RelayEnvelope, force: Bool = false, now: Date) -> Bool {
        if force || lastHash == nil { return true }
        let hash = envelope.materialHash
        var sinceLast = lastSent.map { now.timeIntervalSince($0) } ?? .infinity
        // The clock was set back since the last send: how long ago that was is unknown, and
        // waiting for the clock to catch up would hold every send back just as long.
        if sinceLast < 0 {
            sinceLast = .infinity
        }
        // A crossing can hide inside the rounded hash (79.6% to 80.3%), so it goes out on its own.
        let urgent = Self.states(envelope) != lastStates || Self.levels(envelope) != lastLevels
        let changed = hash != lastHash || runOutsMoved(envelope)
        return (urgent && sinceLast >= Self.statusInterval)
            || (changed && sinceLast >= Self.minimumInterval)
            || sinceLast >= Self.heartbeat
    }

    mutating func didSend(_ envelope: RelayEnvelope, at now: Date) {
        lastHash = envelope.materialHash
        lastStates = Self.states(envelope)
        lastLevels = Self.levels(envelope)
        lastRunOuts = envelope.runOuts
        lastSent = now
    }

    private func runOutsMoved(_ envelope: RelayEnvelope) -> Bool {
        Self.runOutsMoved(envelope.runOuts, since: lastRunOuts)
    }

    /// Whether a measured run-out moved an hour or more from the one last sent, or a window
    /// started or stopped being measured. Against what was sent rather than hour boundaries, so
    /// one wobbling across an hour, or around its reset, doesn't go out every five minutes.
    static func runOutsMoved(_ runOuts: [String: Date], since sent: [String: Date]) -> Bool {
        guard Set(runOuts.keys) == Set(sent.keys) else { return true }
        return runOuts.contains { key, date in
            guard let last = sent[key] else { return true }
            guard date != .distantFuture, last != .distantFuture else { return date != last }
            return abs(date.timeIntervalSince(last)) >= RelayEnvelope.runOutStep
        }
    }

    /// The next check sends whatever it has.
    mutating func reset() {
        lastHash = nil
    }

    private static func states(_ envelope: RelayEnvelope) -> [String: String] {
        Dictionary(envelope.providers.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    /// The highest alert threshold (80, 95) each metered window has reached, 0 below them.
    private static func levels(_ envelope: RelayEnvelope) -> [String: Int] {
        var levels: [String: Int] = [:]
        for provider in envelope.providers {
            for window in provider.windows where window.isMetered {
                levels[provider.id + "/" + window.id] = AlertPreferences.supportedThresholds.filter { window.used >= Double($0) }.max() ?? 0
            }
        }
        return levels
    }
}
