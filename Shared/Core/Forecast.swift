import Foundation

/// Forecasts for money: how long a balance lasts at the recent burn, and where a month's
/// spend is heading. Percent windows use `Pace` instead.
enum Forecast {
    /// At least this much history since the last top-up before a burn rate means anything.
    static let minimumSpan: TimeInterval = 12 * 3600
    /// Spend projections wait until this much of the month has passed.
    static let minimumMonthFraction = 0.1

    /// Days a balance lasts at the rate it went down since the last top-up, within the week.
    /// Nil when it isn't going down, or there isn't enough history yet.
    static func daysLeft(remaining: Double, history: UsageHistory?, now: Date = .now) -> Double? {
        guard remaining > 0, let points = history?.amountPoints, points.count >= 2 else { return nil }
        // Walk back from the newest reading until the balance was lower (a top-up after it).
        var segment = [points[points.count - 1]]
        for point in points.dropLast().reversed() {
            guard point.remaining >= segment[0].remaining else { break }
            segment.insert(point, at: 0)
        }
        guard let first = segment.first, let last = segment.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let spent = first.remaining - last.remaining
        guard span >= minimumSpan, spent > 0 else { return nil }
        let perDay = spent / span * 86_400
        return remaining / perDay
    }

    /// This month's spend at the end of the month, at the pace so far.
    static func projectedSpend(spent: Double, startsAt: Date, resetsAt: Date, now: Date = .now) -> Double? {
        let length = resetsAt.timeIntervalSince(startsAt)
        let elapsed = now.timeIntervalSince(startsAt)
        guard length > 0, elapsed > 0, elapsed / length >= minimumMonthFraction, spent > 0 else { return nil }
        return spent / (elapsed / length)
    }

    /// "≈ 12 days left at this week's rate", "≈ 9 hours left at this week's rate".
    static func runwayText(daysLeft: Double) -> String {
        if daysLeft < 1 {
            let hours = max(Int((daysLeft * 24).rounded()), 1)
            return "≈ \(hours) hour\(hours == 1 ? "" : "s") left at this week's rate"
        }
        let days = Int(daysLeft.rounded())
        return days > 60 ? "Lasts months at this week's rate" : "≈ \(days) day\(days == 1 ? "" : "s") left at this week's rate"
    }

    /// "On track for $620 this month", with "over budget" when it passes the budget.
    static func projectionText(_ projected: Double, unit: String, budget: Double?) -> String {
        let amount = AmountFormat.text(projected.rounded(), unit: unit)
        if let budget, projected > budget {
            return "On track for \(amount) this month, over budget"
        }
        return "On track for \(amount) this month"
    }

    /// The forecast line for a relayed window, if it has one: a balance's runway, or a spend
    /// window's projected month.
    static func text(for window: RelayWindow, history: UsageHistory?, now: Date = .now) -> String? {
        guard let amount = window.amount, amount.unit == "usd" || amount.unit == "cny" else { return nil }
        if window.resetsAt == nil, let remaining = amount.remainingOrComputed {
            return daysLeft(remaining: remaining, history: history, now: now).map(runwayText)
        }
        if let spent = amount.used, amount.remaining == nil, let resetsAt = window.resetsAt, let startsAt = window.startsAt {
            return projectedSpend(spent: spent, startsAt: startsAt, resetsAt: resetsAt, now: now)
                .map { projectionText($0, unit: amount.unit, budget: amount.limit) }
        }
        return nil
    }

    /// The same for a Mac reading.
    static func text(for window: QuotaWindow, history: UsageHistory?, now: Date = .now) -> String? {
        text(for: RelayWindow(window), history: history, now: now)
    }
}
