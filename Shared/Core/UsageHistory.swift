import Foundation

/// Hourly used-% for one window over the last seven days. Each bucket keeps the hour's highest
/// reading; nil means there was no reading that hour. Balances also keep the hour's last amount
/// left, for a burn rate, and every window keeps when it reset.
struct UsageHistory: Codable, Equatable, Sendable {
    static let capacity = 168
    static let step: TimeInterval = 3_600
    /// Readings of one window can report reset times this far apart.
    static let resetJitter: TimeInterval = 30 * 60
    /// A reset used early shows as use falling by at least this many points, to half or less,
    /// and to no more than `freshUse`: a window that just started.
    static let resetDrop = 10.0
    static let freshUse = 10.0

    /// Start of the first bucket, on an hour boundary.
    var start: Date
    var used: [UInt8?]
    /// Amount left at the end of each hour, for balances; nil for other windows.
    var amounts: [Double?]? = nil
    /// When the window reset during the week, oldest first.
    var resets: [Date]? = nil
    /// The reset time the latest reading reported, to notice the next reset.
    var windowResetsAt: Date? = nil

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
        guard let index = bucket(for: date) else { return false }
        let value = UInt8(clamping: Int(min(max(percent, 0), 100).rounded()))
        let next = max(used[index] ?? 0, value)
        guard used[index] != next else { return false }
        used[index] = next
        return true
    }

    /// Records the amount left on a balance; the hour keeps its latest value, so a top-up shows.
    @discardableResult
    mutating func recordAmount(_ remaining: Double, at date: Date) -> Bool {
        guard let index = bucket(for: date) else { return false }
        var values = amounts ?? Array(repeating: nil, count: Self.capacity)
        guard values[index] != remaining else { return false }
        values[index] = remaining
        amounts = values
        return true
    }

    /// Notes a reset when the reported reset time moves on to a later window. Returns whether
    /// anything changed.
    /// Some providers report a reset worked out from the current time, so it drifts by
    /// seconds between checks; that alone doesn't count as a change.
    /// - Parameters:
    ///   - percent: the reading's used %, and `length` the window's. With both, a reset used
    ///     before its time (a banked one) is noted too, not only one whose time has passed.
    @discardableResult
    mutating func recordResetTime(_ resetsAt: Date?, used percent: Double? = nil, length: TimeInterval? = nil, at date: Date) -> Bool {
        guard let resetsAt else { return false }
        defer { windowResetsAt = resetsAt }
        guard let previous = windowResetsAt, resetsAt.timeIntervalSince(previous) > Self.resetJitter,
              let reset = previous <= date ? previous : earlyReset(opening: resetsAt, used: percent, length: length, at: date)
        else {
            return windowResetsAt.map { abs(resetsAt.timeIntervalSince($0)) > 15 * 60 } ?? true
        }
        var list = (resets ?? []).filter { $0 >= start }
        if reset >= start, !list.contains(reset) {
            list.append(reset)
        }
        resets = list
        return true
    }

    /// When a window ending at `resetsAt` opened, if that was a reset used early: use fell
    /// sharply since the last reading, to near nothing, and the new window has begun. Noise and
    /// a provider's rounding move use by a point or two, and a window sliding as old use ages
    /// out, or a plan changed mid-window, rarely drops to almost nothing at once. Nil when it
    /// wasn't one.
    private func earlyReset(opening resetsAt: Date, used percent: Double?, length: TimeInterval?, at date: Date) -> Date? {
        guard let percent, let length, let before = usedBefore(date),
              before - percent >= Self.resetDrop, percent <= before / 2, percent <= Self.freshUse
        else { return nil }
        let opened = resetsAt.addingTimeInterval(-length)
        guard opened <= date.addingTimeInterval(Self.resetJitter) else { return nil }
        return min(opened, date)
    }

    /// The highest use recorded in the hour of `date`, or the latest earlier hour with a reading
    /// when that's higher: what the window was at before a reading at `date`, whether that
    /// reading is recorded yet or not.
    private func usedBefore(_ date: Date) -> Double? {
        let hour = Int((Self.hourStart(date).timeIntervalSince(start) / Self.step).rounded())
        guard hour >= 0 else { return nil }
        let own = hour < used.count ? used[hour] : nil
        let earlier = used.prefix(min(hour, used.count)).last { $0 != nil } ?? nil
        return [own, earlier].compactMap { $0 }.max().map { Double($0) }
    }

    /// The bucket for `date`, moving the week forward first when needed.
    private mutating func bucket(for date: Date) -> Int? {
        var index = Int((Self.hourStart(date).timeIntervalSince(start) / Self.step).rounded())
        guard index >= 0 else { return nil }
        if index >= Self.capacity {
            let shift = index - Self.capacity + 1
            used = Self.shifted(used, by: shift)
            amounts = amounts.map { Self.shifted($0, by: shift) }
            start = start.addingTimeInterval(Double(shift) * Self.step)
            resets = resets?.filter { $0 >= start }
            index = Self.capacity - 1
        }
        return index
    }

    private static func shifted<Value>(_ values: [Value?], by shift: Int) -> [Value?] {
        guard shift < capacity else { return Array(repeating: nil, count: capacity) }
        return Array(values.dropFirst(shift)) + Array(repeating: nil, count: shift)
    }

    /// Recorded hours, oldest first.
    var points: [(date: Date, used: Double)] {
        used.enumerated().compactMap { index, value in
            value.map { (start.addingTimeInterval(Double(index) * Self.step), Double($0)) }
        }
    }

    /// Recorded balances, oldest first.
    var amountPoints: [(date: Date, remaining: Double)] {
        (amounts ?? []).enumerated().compactMap { index, value in
            value.map { (start.addingTimeInterval(Double(index) * Self.step), $0) }
        }
    }

    var isEmpty: Bool {
        used.allSatisfy { $0 == nil } && (amounts ?? []).allSatisfy { $0 == nil }
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
