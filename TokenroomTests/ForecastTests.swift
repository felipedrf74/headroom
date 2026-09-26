import XCTest
@testable import Tokenroom

/// How long a balance lasts, and where a month's spend is heading.
final class ForecastTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Hourly balances ending at `now`, oldest first.
    private func history(_ amounts: [Double]) -> UsageHistory {
        var history = UsageHistory(endingAt: now)
        for (index, amount) in amounts.enumerated() {
            history.recordAmount(amount, at: now.addingTimeInterval(Double(index - amounts.count + 1) * 3600))
        }
        return history
    }

    // MARK: Runway

    func testRunwayCountsOnlySinceTheLastTopUp() throws {
        // Eight hours running low, a top-up to $50, then a dollar an hour for a day.
        let before = (0..<8).map { 30 - Double($0) }
        let after = (0...24).map { 50 - Double($0) }
        let week = history(before + after)
        let days = try XCTUnwrap(Forecast.daysLeft(remaining: 26, history: week, now: now))
        XCTAssertEqual(days, 26.0 / 24, accuracy: 0.0001, "$24 a day, not the average across the top-up")
    }

    func testRunwayNeedsHalfADayOfFallingBalance() {
        XCTAssertNil(Forecast.daysLeft(remaining: 44, history: history((0...6).map { 50 - Double($0) }), now: now), "Six hours isn't a rate")
        XCTAssertNotNil(Forecast.daysLeft(remaining: 38, history: history((0...12).map { 50 - Double($0) }), now: now))
        XCTAssertNil(Forecast.daysLeft(remaining: 50, history: history(Array(repeating: 50, count: 30)), now: now), "Not going down")
        XCTAssertNil(Forecast.daysLeft(remaining: 0, history: history((0...24).map { 24 - Double($0) }), now: now), "Nothing left to last")
        XCTAssertNil(Forecast.daysLeft(remaining: 10, history: nil, now: now))
        XCTAssertNil(Forecast.daysLeft(remaining: 10, history: history([10]), now: now))
    }

    func testASmallRiseIsntATopUp() throws {
        // A dollar an hour for a day, with a cent refunded four hours ago.
        var amounts = (0...24).map { 50 - Double($0) }
        amounts[20] = amounts[19] + 0.01
        let days = try XCTUnwrap(Forecast.daysLeft(remaining: 26, history: history(amounts), now: now), "The runway isn't hidden for half a day")
        XCTAssertEqual(days, 26.0 / 24, accuracy: 0.0001)

        // Under a dollar, where a cent is more than 1% of the balance.
        var low = (0...24).map { 0.98 - Double($0) * 0.03 }
        low[20] = low[19] + 0.01
        XCTAssertEqual(try XCTUnwrap(Forecast.daysLeft(remaining: 0.26, history: history(low), now: now)), 0.26 / 0.72, accuracy: 0.0001)

        // A rise over a dollar and over 1% is a top-up.
        var topped = (0...24).map { 50 - Double($0) }
        topped[20] = topped[19] + 1.5
        XCTAssertNil(Forecast.daysLeft(remaining: 26, history: history(topped), now: now), "Four hours since a top-up isn't a rate")
    }

    func testRunwayText() {
        XCTAssertEqual(Forecast.runwayText(daysLeft: 12.4), "≈ 12 days left at this week's rate")
        XCTAssertEqual(Forecast.runwayText(daysLeft: 1.2), "≈ 1 day left at this week's rate")
        XCTAssertEqual(Forecast.runwayText(daysLeft: 0.3), "≈ 7 hours left at this week's rate")
        XCTAssertEqual(Forecast.runwayText(daysLeft: 0.01), "≈ 1 hour left at this week's rate", "Never zero hours")
        XCTAssertEqual(Forecast.runwayText(daysLeft: 90), "Lasts months at this week's rate")
    }

    // MARK: Month projection

    func testProjectionWaitsForATenthOfTheMonth() throws {
        let start = utc(2026, 9, 1)
        let end = utc(2026, 10, 1)
        XCTAssertNil(Forecast.projectedSpend(spent: 20, startsAt: start, resetsAt: end, now: utc(2026, 9, 2, 12)), "A day and a half is too early")
        let projected = try XCTUnwrap(Forecast.projectedSpend(spent: 100, startsAt: start, resetsAt: end, now: utc(2026, 9, 7)))
        XCTAssertEqual(projected, 500, accuracy: 0.001, "$100 in a fifth of the month")
        XCTAssertNil(Forecast.projectedSpend(spent: 0, startsAt: start, resetsAt: end, now: utc(2026, 9, 7)), "Nothing spent, nothing to project")
    }

    func testProjectionEndsWithTheMonth() {
        let start = utc(2026, 9, 1)
        let end = utc(2026, 10, 1)
        XCTAssertNil(Forecast.projectedSpend(spent: 500, startsAt: start, resetsAt: end, now: utc(2026, 10, 3)), "Not \"on track for $469\" in the next month")
        XCTAssertNil(Forecast.projectedSpend(spent: 500, startsAt: start, resetsAt: end, now: end))
        let spend = RelayWindow(id: "spend-month", kind: "monthly", title: "This month", used: 0, resetsAt: end, startsAt: start, amount: QuotaAmount(used: 500, unit: "usd"), metered: false)
        XCTAssertNil(Forecast.text(for: spend, history: nil, now: utc(2026, 10, 3)))
    }

    func testProjectionRunsToTheReadingAndSkipsOldOnes() throws {
        let start = utc(2026, 9, 1)
        let end = utc(2026, 10, 1)
        // $100 read at midnight on 7 September, a fifth of the month in, and seen that evening.
        let read = utc(2026, 9, 7)
        let projected = try XCTUnwrap(Forecast.projectedSpend(spent: 100, startsAt: start, resetsAt: end, checkedAt: read, now: utc(2026, 9, 7, 20)))
        XCTAssertEqual(projected, 500, accuracy: 0.001, "The pace so far runs to the reading, not to the viewer's clock")
        XCTAssertNil(Forecast.projectedSpend(spent: 100, startsAt: start, resetsAt: end, checkedAt: read, now: utc(2026, 9, 8, 1)), "Over a day old")
        XCTAssertNil(Forecast.projectedSpend(spent: 480, startsAt: start, resetsAt: end, checkedAt: utc(2026, 9, 30, 20), now: utc(2026, 10, 1, 2)), "Read before the month ended, seen after")

        let spend = RelayWindow(id: "spend-month", kind: "monthly", title: "This month", used: 0, resetsAt: end, startsAt: start, amount: QuotaAmount(used: 100, unit: "usd"), metered: false)
        XCTAssertEqual(Forecast.text(for: spend, history: nil, checkedAt: read, now: utc(2026, 9, 7, 20)), "On track for \(AmountFormat.text(500, unit: "usd")) this month")
        XCTAssertNil(Forecast.text(for: spend, history: nil, checkedAt: read, now: utc(2026, 9, 9)))
        let macSpend = QuotaWindow(id: "spend-month", kind: .monthly, title: "This month", usedPercent: 0, resetsAt: end, startsAt: start, amount: QuotaAmount(used: 100, unit: "usd"), metered: false)
        XCTAssertEqual(Forecast.text(for: macSpend, history: nil, checkedAt: read, now: utc(2026, 9, 7, 20)), Forecast.text(for: spend, history: nil, checkedAt: read, now: utc(2026, 9, 7, 20)))
    }

    func testProjectionText() {
        XCTAssertEqual(Forecast.projectionText(500, unit: "usd", budget: nil), "On track for \(AmountFormat.text(500, unit: "usd")) this month")
        XCTAssertEqual(Forecast.projectionText(499.6, unit: "usd", budget: 600), "On track for \(AmountFormat.text(500, unit: "usd")) this month", "Whole amounts")
        XCTAssertEqual(Forecast.projectionText(620, unit: "usd", budget: 500), "On track for \(AmountFormat.text(620, unit: "usd")) this month, over budget")
        XCTAssertEqual(Forecast.projectionText(620, unit: "cny", budget: nil), "On track for \(AmountFormat.text(620, unit: "cny")) this month")
    }

    // MARK: Which windows get a forecast

    func testForecastLinePerKindOfWindow() throws {
        let balance = RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 0, resetsAt: nil, amount: QuotaAmount(remaining: 26, unit: "usd"), metered: false)
        let week = history((0..<8).map { 30 - Double($0) } + (0...24).map { 50 - Double($0) })
        XCTAssertEqual(Forecast.text(for: balance, history: week, now: now), "≈ 1 day left at this week's rate")

        let spend = RelayWindow(
            id: "spend-month", kind: "monthly", title: "This month", used: 0, resetsAt: utc(2026, 10, 1), startsAt: utc(2026, 9, 1),
            amount: QuotaAmount(used: 100, unit: "usd"), metered: false
        )
        XCTAssertEqual(Forecast.text(for: spend, history: nil, now: utc(2026, 9, 7)), "On track for \(AmountFormat.text(500, unit: "usd")) this month")
        var budgeted = spend
        budgeted.amount?.limit = 400
        XCTAssertEqual(Forecast.text(for: budgeted, history: nil, now: utc(2026, 9, 7)), "On track for \(AmountFormat.text(500, unit: "usd")) this month, over budget")

        let requests = RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 83, resetsAt: utc(2026, 10, 1), startsAt: utc(2026, 9, 1), amount: QuotaAmount(used: 249, limit: 300, remaining: 51, unit: "requests"))
        XCTAssertNil(Forecast.text(for: requests, history: nil, now: utc(2026, 9, 7)), "Only money is forecast")
        let percent = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 70, resetsAt: utc(2026, 9, 28))
        XCTAssertNil(Forecast.text(for: percent, history: nil, now: now), "Percent windows have pace instead")

        let macBalance = QuotaWindow(id: "balance-usd", kind: .pool, title: "Balance", usedPercent: 0, resetsAt: nil, amount: QuotaAmount(remaining: 26, unit: "usd"), metered: false)
        XCTAssertEqual(Forecast.text(for: macBalance, history: week, now: now), Forecast.text(for: balance, history: week, now: now), "The Mac's readings get the same line")
    }
}
