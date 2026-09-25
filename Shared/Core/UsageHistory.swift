import Foundation

/// Hourly used-% for one window over the last seven days. Each bucket keeps the hour's highest
/// reading; nil means there was no reading that hour.
struct UsageHistory: Codable, Equatable, Sendable {
    static let capacity = 168
    static let step: TimeInterval = 3_600

    /// Start of the first bucket, on an hour boundary.
    var start: Date
    var used: [UInt8?]

    /// An empty week whose last bucket is the hour containing `now`.
    init(endingAt now: Date) {
        start = Self.hourStart(now).addingTimeInterval(-Double(Self.capacity - 1) * Self.step)
        used = Array(repeating: nil, count: Self.capacity)
    }

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    var end: Date {
        start.addingTimeInterval(Double(used.count) * Self.step)
    }

    /// Records a reading, moving the week forward when time has passed. Readings older than
    /// the week are ignored. Returns whether a bucket changed.
    @discardableResult
    mutating func record(_ percent: Double, at date: Date) -> Bool {
        var index = Int((Self.hourStart(date).timeIntervalSince(start) / Self.step).rounded())
        guard index >= 0 else { return false }
        if index >= Self.capacity {
            let shift = index - Self.capacity + 1
            if shift >= Self.capacity {
                used = Array(repeating: nil, count: Self.capacity)
            } else {
                used.removeFirst(shift)
                used.append(contentsOf: Array(repeating: nil, count: shift))
            }
            start = start.addingTimeInterval(Double(shift) * Self.step)
            index = Self.capacity - 1
        }
        let value = UInt8(clamping: Int(min(max(percent, 0), 100).rounded()))
        let next = max(used[index] ?? 0, value)
        guard used[index] != next else { return false }
        used[index] = next
        return true
    }

    /// Recorded hours, oldest first.
    var points: [(date: Date, used: Double)] {
        used.enumerated().compactMap { index, value in
            value.map { (start.addingTimeInterval(Double(index) * Self.step), Double($0)) }
        }
    }

    var isEmpty: Bool {
        used.allSatisfy { $0 == nil }
    }
}

/// Every window's history from one collector, relayed hourly as the `History` record.
/// Keys are `provider/window`, e.g. `claude/weekly`.
struct RelayHistory: Codable, Equatable, Sendable {
    var v: Int = 1
    var series: [String: UsageHistory]

    static func key(provider: String, window: String) -> String {
        "\(provider)/\(window)"
    }

    func encoded() throws -> Data {
        try RelayEnvelope.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RelayHistory {
        try RelayEnvelope.decoder.decode(RelayHistory.self, from: data)
    }
}
