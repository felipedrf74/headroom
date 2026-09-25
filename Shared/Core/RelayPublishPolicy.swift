import Foundation

/// When a collector sends its readings: when usage changed (at most every 5 minutes), when a
/// provider's status changed (after a minute), and every 30 minutes as a heartbeat so readers
/// can tell it's alive.
struct RelayPublishPolicy: Sendable, Equatable {
    static let heartbeat: TimeInterval = 30 * 60
    static let minimumInterval: TimeInterval = 5 * 60
    static let statusInterval: TimeInterval = 60

    private(set) var lastHash: Int?
    private(set) var lastStates: [String: String] = [:]
    private(set) var lastSent: Date?

    func isDue(_ envelope: RelayEnvelope, force: Bool = false, now: Date) -> Bool {
        if force || lastHash == nil { return true }
        let hash = envelope.materialHash
        let sinceLast = lastSent.map { now.timeIntervalSince($0) } ?? .infinity
        return (hash != lastHash && Self.states(envelope) != lastStates && sinceLast >= Self.statusInterval)
            || (hash != lastHash && sinceLast >= Self.minimumInterval)
            || sinceLast >= Self.heartbeat
    }

    mutating func didSend(_ envelope: RelayEnvelope, at now: Date) {
        lastHash = envelope.materialHash
        lastStates = Self.states(envelope)
        lastSent = now
    }

    /// The next check sends whatever it has.
    mutating func reset() {
        lastHash = nil
    }

    private static func states(_ envelope: RelayEnvelope) -> [String: String] {
        Dictionary(envelope.providers.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }
}
