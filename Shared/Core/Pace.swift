import Foundation

/// Whether usage is running ahead of the clock, and when it would run out.
///
/// Compares used % with the share of the window that has elapsed:
/// halfway through a week with 70% used is 20 points ahead of an even pace.
struct Pace: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// Within 10 points of an even pace.
        case onPace
        /// At least 10 points under an even pace.
        case plentyLeft
        /// At least 10 points over an even pace.
        case ahead
        case limitReached
    }

    enum Severity: Equatable, Sendable {
        case none
        /// Runs out, but only in the last quarter of the window.
        case watch
        /// Runs out earlier than that.
        case tight
        /// Runs out within the hour, or already has.
        case critical
    }

    var verdict: Verdict
    /// Used minus expected, in percentage points.
    var delta: Double
    var elapsedFraction: Double
    var resetsAt: Date
    /// Projected moment usage reaches 100%, only when that comes before the reset.
    var runsOutAt: Date?
    var severity: Severity

    static let tolerance = 10.0
    static let minimumElapsed = 0.05
    static let minimumUsed = 5.0

    /// - Parameters:
    ///   - samples: recent `(time, used %)` readings, oldest first. Used for the run-out rate
    ///     when there are enough inside the current window.
    /// - Returns: nil when there's no reset time, the window is too young, usage is tiny,
    ///   or the reading is stale.
    static func evaluate(
        used: Double,
        kind: WindowKind,
        resetsAt: Date?,
        startsAt: Date? = nil,
        windowSeconds: Double? = nil,
        samples: [(date: Date, used: Double)] = [],
        isStale: Bool = false,
        now: Date = .now,
        calendar: Calendar = .gregorianUTC
    ) -> Pace? {
        guard !isStale, let resetsAt, resetsAt > now,
              let length = windowLength(kind: kind, resetsAt: resetsAt, startsAt: startsAt, windowSeconds: windowSeconds, calendar: calendar),
              length > 0
        else { return nil }

        let start = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        let fraction = elapsed / length

        if used >= 100 {
            return Pace(verdict: .limitReached, delta: 100 - fraction * 100, elapsedFraction: fraction, resetsAt: resetsAt, runsOutAt: nil, severity: .critical)
        }
        guard fraction >= minimumElapsed, fraction < 1, used >= minimumUsed else { return nil }

        let delta = used - fraction * 100
        let verdict: Verdict
        if delta >= tolerance {
            verdict = .ahead
        } else if delta <= -tolerance {
            verdict = .plentyLeft
        } else {
            verdict = .onPace
        }

        var runsOut: Date?
        if let rate = recentRate(samples: samples, since: start, kind: kind, now: now) ?? linearRate(used: used, elapsed: elapsed),
           rate > 0 {
            let projected = now.addingTimeInterval((100 - used) / rate)
            if projected < resetsAt {
                runsOut = projected
            }
        }

        let severity: Severity
        if let runsOut {
            let lastQuarter = resetsAt.addingTimeInterval(-length / 4)
            if runsOut.timeIntervalSince(now) < 3_600 {
                severity = .critical
            } else if runsOut >= lastQuarter {
                severity = .watch
            } else {
                severity = .tight
            }
        } else {
            severity = .none
        }
        return Pace(verdict: verdict, delta: delta, elapsedFraction: fraction, resetsAt: resetsAt, runsOutAt: runsOut, severity: severity)
    }

    /// The provider's own length, else reset minus start, else the usual length for the kind.
    static func windowLength(
        kind: WindowKind,
        resetsAt: Date,
        startsAt: Date?,
        windowSeconds: Double?,
        calendar: Calendar = .gregorianUTC
    ) -> TimeInterval? {
        if let windowSeconds, windowSeconds > 0 {
            return windowSeconds
        }
        if let startsAt, startsAt < resetsAt {
            return resetsAt.timeIntervalSince(startsAt)
        }
        switch kind {
        case .session:
            return 5 * 3_600
        case .weekly:
            return 7 * 86_400
        case .billingCycle:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
            return resetsAt.timeIntervalSince(previous)
        case .pool:
            return nil
        }
    }

    /// Least-squares slope (percent per second) of recent samples in the current window.
    /// Sessions look at the last 30 minutes, longer windows at the last 6 hours.
    static func recentRate(samples: [(date: Date, used: Double)], since start: Date, kind: WindowKind, now: Date) -> Double? {
        let horizon: TimeInterval = kind == .session ? 30 * 60 : 6 * 3_600
        let recent = samples.filter { $0.date >= start && $0.date >= now.addingTimeInterval(-horizon) && $0.date <= now }
        guard recent.count >= 3 else { return nil }
        let times = recent.map { $0.date.timeIntervalSince(now) }
        let values = recent.map(\.used)
        let meanT = times.reduce(0, +) / Double(times.count)
        let meanV = values.reduce(0, +) / Double(values.count)
        var numerator = 0.0
        var denominator = 0.0
        for (time, value) in zip(times, values) {
            numerator += (time - meanT) * (value - meanV)
            denominator += (time - meanT) * (time - meanT)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Average rate since the window started.
    private static func linearRate(used: Double, elapsed: TimeInterval) -> Double? {
        elapsed > 0 ? used / elapsed : nil
    }
}

extension Calendar {
    /// Month arithmetic for billing cycles, independent of the device's time zone.
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

extension Pace {
    /// One short line for captions: "On pace", "Plenty left",
    /// "Ahead of pace · runs out Thu 14:00", "Limit reached · resets in 2h 10m".
    func caption(now: Date = .now, timeZone: TimeZone = .current) -> String {
        switch verdict {
        case .onPace:
            return "On pace"
        case .plentyLeft:
            return "Plenty left"
        case .limitReached:
            return RelativeTime.resets(resetsAt, now: now).map { "Limit reached · \($0)" } ?? "Limit reached"
        case .ahead:
            guard let runsOutAt else { return "Ahead of pace" }
            return "Ahead of pace · runs out \(Self.shortMoment(runsOutAt, now: now, timeZone: timeZone))"
        }
    }

    /// "14:00" today, "Thu 14:00" within a week, "Oct 3" after that.
    static func shortMoment(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style)
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            var weekday = Date.FormatStyle().weekday(.abbreviated)
            weekday.timeZone = timeZone
            return "\(date.formatted(weekday)) \(date.formatted(style))"
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        day.timeZone = timeZone
        return date.formatted(day)
    }
}
