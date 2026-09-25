import XCTest
@testable import Tokenroom

final class PaceTests: XCTestCase {
    private let week: TimeInterval = 7 * 86_400
    private let reset = Date(timeIntervalSince1970: 2_000_000)

    private func weekly(used: Double, elapsed: Double, samples: [(date: Date, used: Double)] = [], stale: Bool = false) -> Pace? {
        let now = reset.addingTimeInterval(-week + elapsed * week)
        return Pace.evaluate(used: used, kind: .weekly, resetsAt: reset, samples: samples, isStale: stale, now: now)
    }

    func testVerdictsAroundAnEvenPace() {
        XCTAssertEqual(weekly(used: 50, elapsed: 0.5)?.verdict, .onPace)
        XCTAssertEqual(weekly(used: 58, elapsed: 0.5)?.verdict, .onPace)
        XCTAssertEqual(weekly(used: 30, elapsed: 0.5)?.verdict, .plentyLeft)
        XCTAssertEqual(weekly(used: 70, elapsed: 0.5)?.verdict, .ahead)
        XCTAssertEqual(weekly(used: 70, elapsed: 0.5)?.delta ?? 0, 20, accuracy: 0.001)
    }

    func testAheadProjectsRunOutBeforeReset() throws {
        let pace = try XCTUnwrap(weekly(used: 70, elapsed: 0.5))
        let now = reset.addingTimeInterval(-week / 2)
        // 70% in 3.5 days → the last 30% takes 1.5 days.
        let runsOut = try XCTUnwrap(pace.runsOutAt)
        XCTAssertEqual(runsOut.timeIntervalSince(now), 1.5 * 86_400, accuracy: 1)
        XCTAssertEqual(pace.severity, .tight)
    }

    func testRunOutInLastQuarterIsOnlyWatch() throws {
        // 55% at 50% elapsed runs out at ~91% of the window: inside the last quarter.
        let pace = try XCTUnwrap(weekly(used: 55, elapsed: 0.5))
        XCTAssertNotNil(pace.runsOutAt)
        XCTAssertEqual(pace.severity, .watch)
    }

    func testNoRunOutWhenUsageLastsPastReset() throws {
        let pace = try XCTUnwrap(weekly(used: 30, elapsed: 0.5))
        XCTAssertNil(pace.runsOutAt)
        XCTAssertEqual(pace.severity, .none)
    }

    func testNoPaceWithoutEnoughSignal() {
        XCTAssertNil(weekly(used: 50, elapsed: 0.02), "Window too young")
        XCTAssertNil(weekly(used: 3, elapsed: 0.5), "Usage too small")
        XCTAssertNil(weekly(used: 50, elapsed: 0.5, stale: true), "Stale reading")
        XCTAssertNil(Pace.evaluate(used: 50, kind: .weekly, resetsAt: nil), "No reset time")
        XCTAssertNil(Pace.evaluate(used: 50, kind: .pool, resetsAt: reset, now: reset.addingTimeInterval(-3600)), "Pool has no length")
    }

    func testLimitReached() throws {
        let pace = try XCTUnwrap(weekly(used: 100, elapsed: 0.8))
        XCTAssertEqual(pace.verdict, .limitReached)
        XCTAssertEqual(pace.severity, .critical)
        XCTAssertTrue(pace.caption(now: reset.addingTimeInterval(-3600)).hasPrefix("Limit reached · resets in"))
    }

    func testRecentSamplesDriveTheRate() throws {
        let now = reset.addingTimeInterval(-week / 2)
        // Flat for the last three hours: nothing will run out even though usage is ahead.
        let flat = (0..<4).map { (now.addingTimeInterval(Double(-$0) * 3_600), 70.0) }.reversed()
        let pace = try XCTUnwrap(weekly(used: 70, elapsed: 0.5, samples: Array(flat)))
        XCTAssertEqual(pace.verdict, .ahead)
        XCTAssertNil(pace.runsOutAt)
    }

    func testWindowLengthSources() {
        let start = reset.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(Pace.windowLength(kind: .weekly, resetsAt: reset, startsAt: nil, windowSeconds: 18_000), 18_000)
        XCTAssertEqual(Pace.windowLength(kind: .weekly, resetsAt: reset, startsAt: start, windowSeconds: nil), 3 * 86_400)
        XCTAssertEqual(Pace.windowLength(kind: .session, resetsAt: reset, startsAt: nil, windowSeconds: nil), 5 * 3_600)
        // A billing cycle ending 1 March 2026 (UTC) started 1 February: 28 days.
        let march = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        XCTAssertEqual(Pace.windowLength(kind: .billingCycle, resetsAt: march, startsAt: nil, windowSeconds: nil), 28 * 86_400)
    }

    func testCaptionMoments() {
        let utc = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000) // a Thursday
        XCTAssertEqual(Pace.shortMoment(now.addingTimeInterval(3_600), now: now, timeZone: utc).contains(":"), true)
        XCTAssertFalse(Pace.shortMoment(now.addingTimeInterval(2 * 86_400), now: now, timeZone: utc).isEmpty)
    }

    // MARK: Clock changes and calendar months

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func clock(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// Europe leaves summer time on 25 October 2026 at 01:00 UTC. A week across it is still 168
    /// hours, and captions show the local clock on the far side of the change.
    func testAWeekAcrossTheEndOfEuropeanSummerTime() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let reset = utcDate(2026, 10, 29, 12) // opened Thursday 22 October, 14:00 in Berlin (CEST)
        let now = utcDate(2026, 10, 26) // Monday, halfway through, after the change
        var pace = try XCTUnwrap(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, now: now))
        XCTAssertEqual(pace.elapsedFraction, 0.5, accuracy: 1e-9, "An hour of the week isn't lost to the clock change")
        XCTAssertEqual(pace.verdict, .ahead)
        let runsOut = utcDate(2026, 10, 27, 12)
        XCTAssertEqual(try XCTUnwrap(pace.runsOutAt).timeIntervalSince1970, runsOut.timeIntervalSince1970, accuracy: 1, "The last 30% takes 36 real hours")

        pace.runsOutAt = runsOut
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        XCTAssertEqual(calendar.component(.hour, from: runsOut), 13, "12:00 UTC is 13:00 in Berlin in winter")
        let caption = pace.caption(now: now, timeZone: berlin)
        XCTAssertTrue(caption.hasPrefix("Ahead of pace · runs out "))
        XCTAssertTrue(caption.hasSuffix(" \(clock(runsOut, in: berlin))"))
        XCTAssertNotEqual(clock(runsOut, in: berlin), clock(runsOut, in: TimeZone(secondsFromGMT: 2 * 3600)!), "Summer time's offset would be an hour off")
    }

    /// The US leaves daylight time on 1 November 2026 at 06:00 UTC. Whether a run-out is "today"
    /// is decided on the local calendar.
    func testTodayIsTheLocalDayAcrossTheUSClockChange() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = utcDate(2026, 11, 1, 3) // Saturday 31 October, 23:00 in New York (EDT)
        let runsOut = utcDate(2026, 11, 1, 18) // Sunday 1 November, 13:00 in New York (EST)
        let pace = Pace(verdict: .ahead, delta: 20, elapsedFraction: 0.6, resetsAt: utcDate(2026, 11, 3), runsOutAt: runsOut, severity: .tight)
        XCTAssertEqual(pace.caption(now: now, timeZone: TimeZone(identifier: "UTC")!), "Ahead of pace · runs out \(clock(runsOut, in: TimeZone(identifier: "UTC")!))", "Same day in UTC")
        let local = pace.caption(now: now, timeZone: newYork)
        XCTAssertNotEqual(local, "Ahead of pace · runs out \(clock(runsOut, in: newYork))", "Tomorrow in New York: the weekday is shown")
        XCTAssertTrue(local.hasSuffix(" \(clock(runsOut, in: newYork))"))
    }

    /// Calendar months are counted in UTC, so a daylight change inside one doesn't stretch it.
    func testMonthsAreUTCAndFebruaryHasItsOwnLength() {
        XCTAssertEqual(Pace.windowLength(kind: .billingCycle, resetsAt: utcDate(2026, 11, 1), startsAt: nil, windowSeconds: nil), 31 * 86_400, "October, with both clock changes")
        XCTAssertEqual(Pace.windowLength(kind: .monthly, resetsAt: utcDate(2028, 3, 1), startsAt: nil, windowSeconds: nil), 29 * 86_400, "A leap February")
        XCTAssertEqual(Pace.windowLength(kind: .monthly, resetsAt: utcDate(2026, 3, 1), startsAt: nil, windowSeconds: nil), 28 * 86_400)
        // A mid-February reading is judged against 28 days, not 30 or 31.
        let pace = Pace.evaluate(used: 50, kind: .monthly, resetsAt: utcDate(2026, 3, 1), now: utcDate(2026, 2, 15))
        XCTAssertEqual(pace?.elapsedFraction ?? 0, 0.5, accuracy: 1e-9)
    }

    // MARK: A collector's measured pace

    func testMeasuredRunOutReplacesTheEstimate() throws {
        let now = reset.addingTimeInterval(-week / 2)
        let measured = try XCTUnwrap(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, measured: RelayPace(runsOutAt: now.addingTimeInterval(10 * 3600)), now: now))
        XCTAssertEqual(measured.runsOutAt, now.addingTimeInterval(10 * 3600), "The Mac's frequent readings beat hourly buckets")
        XCTAssertEqual(measured.severity, .tight)

        let steady = try XCTUnwrap(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, measured: RelayPace(runsOutAt: nil), now: now))
        XCTAssertEqual(steady.verdict, .ahead, "The verdict is still about the clock")
        XCTAssertNil(steady.runsOutAt, "Measured as lasting, even though the average says otherwise")
        XCTAssertEqual(steady.severity, .none)

        XCTAssertNil(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, measured: RelayPace(runsOutAt: reset.addingTimeInterval(3600)), now: now)?.runsOutAt, "After the reset isn't a run-out")
        XCTAssertNil(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, measured: RelayPace(runsOutAt: now.addingTimeInterval(-60)), now: now)?.runsOutAt, "A measurement from before now is stale")

        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 70, resetsAt: reset, periodSec: week, pace: RelayPace(runsOutAt: now.addingTimeInterval(10 * 3600)))
        XCTAssertEqual(UsageRanking.pace(for: window, isStale: false, history: nil, now: now)?.runsOutAt, now.addingTimeInterval(10 * 3600), "Readers use the relayed pace")
    }

    func testNeedsAttention() throws {
        XCTAssertTrue(try XCTUnwrap(weekly(used: 70, elapsed: 0.5)).needsAttention)
        XCTAssertTrue(try XCTUnwrap(weekly(used: 100, elapsed: 0.8)).needsAttention)
        XCTAssertFalse(try XCTUnwrap(weekly(used: 50, elapsed: 0.5)).needsAttention)
        XCTAssertFalse(try XCTUnwrap(weekly(used: 30, elapsed: 0.5)).needsAttention)
    }
}

final class UsageHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    func testKeepsTheHoursHighestReading() {
        var history = UsageHistory(endingAt: base)
        history.record(30, at: base)
        history.record(45, at: base.addingTimeInterval(60))
        history.record(40, at: base.addingTimeInterval(120))
        XCTAssertEqual(history.used.last, 45)
        XCTAssertEqual(history.points.count, 1)
    }

    func testRollsForwardAndDropsOldHours() {
        var history = UsageHistory(endingAt: base)
        history.record(10, at: base)
        history.record(20, at: base.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(history.used.count, UsageHistory.capacity)
        XCTAssertEqual(history.used.last, 20)
        XCTAssertEqual(history.used[UsageHistory.capacity - 4], 10)

        history.record(5, at: base.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(history.points.map(\.used), [5], "Readings older than a week fall off")
    }

    func testIgnoresReadingsOlderThanTheWeekAndClamps() {
        var history = UsageHistory(endingAt: base)
        XCTAssertFalse(history.record(50, at: base.addingTimeInterval(-8 * 86_400)))
        history.record(140, at: base)
        XCTAssertEqual(history.used.last, 100)
    }

    func testRelayHistoryRoundTrip() throws {
        var week = UsageHistory(endingAt: base)
        week.record(33, at: base)
        week.recordAmount(12.4, at: base)
        week.recordResetTime(base.addingTimeInterval(3600), at: base)
        let relayed = RelayHistory(series: [RelayHistory.key(provider: "claude", window: "weekly"): week])
        XCTAssertEqual(try RelayHistory.decode(relayed.encoded()), relayed)
    }

    // MARK: Balances and resets

    func testABalanceKeepsTheHoursLatestAmount() {
        var history = UsageHistory(endingAt: base)
        XCTAssertTrue(history.recordAmount(30, at: base))
        XCTAssertTrue(history.recordAmount(28.5, at: base.addingTimeInterval(60)))
        XCTAssertEqual(history.amountPoints.map(\.remaining), [28.5], "Down within the hour: the latest")
        XCTAssertTrue(history.recordAmount(50, at: base.addingTimeInterval(120)))
        XCTAssertEqual(history.amountPoints.map(\.remaining), [50], "A top-up shows at once, unlike used-%'s highest")
        XCTAssertFalse(history.recordAmount(50, at: base.addingTimeInterval(180)))
        XCTAssertEqual(history.amountPoints.first?.date, UsageHistory.hourStart(base))
        XCTAssertFalse(history.isEmpty, "Amounts alone count as history")
        XCTAssertTrue(history.points.isEmpty)
    }

    func testAmountsAndResetsMoveWithTheWeek() throws {
        let hour = UsageHistory.hourStart(base)
        var history = UsageHistory(endingAt: base)
        history.recordAmount(30, at: hour)
        history.recordAmount(25, at: hour.addingTimeInterval(3 * 3600))
        XCTAssertEqual(history.amountPoints.map(\.date), [hour, hour.addingTimeInterval(3 * 3600)], "The week moved forward three hours")

        // A reset seen an hour in.
        history.recordResetTime(hour.addingTimeInterval(3600), at: hour)
        history.recordResetTime(hour.addingTimeInterval(3600 + 5 * 86_400), at: hour.addingTimeInterval(2 * 3600))
        XCTAssertEqual(history.resets, [hour.addingTimeInterval(3600)])

        // A week later the first reading and the reset have fallen off; the rest moved with it.
        let later = hour.addingTimeInterval(7 * 86_400 + 2 * 3600)
        history.recordAmount(20, at: later)
        XCTAssertEqual(history.used.count, UsageHistory.capacity)
        XCTAssertEqual(history.amounts?.count, UsageHistory.capacity)
        XCTAssertEqual(history.amountPoints.map(\.remaining), [25, 20])
        XCTAssertEqual(history.amountPoints.last?.date, later)
        XCTAssertEqual(history.resets, [], "The reset left the week")
    }

    func testResetsAreNotedOnlyWhenTheWindowMovesOn() {
        let reset = base.addingTimeInterval(3600)
        var history = UsageHistory(endingAt: base)
        XCTAssertTrue(history.recordResetTime(reset, at: base))
        XCTAssertEqual(history.windowResetsAt, reset)
        XCTAssertFalse(history.recordResetTime(reset, at: base.addingTimeInterval(60)), "Nothing new")
        XCTAssertFalse(history.recordResetTime(reset.addingTimeInterval(300), at: base.addingTimeInterval(120)), "Minutes of drift aren't worth saving")
        XCTAssertEqual(history.windowResetsAt, reset.addingTimeInterval(300), "But the latest time is kept")
        XCTAssertTrue(history.recordResetTime(reset.addingTimeInterval(300 + 20 * 60), at: base.addingTimeInterval(150)), "A bigger move is")
        XCTAssertNil(history.resets, "Minutes of jitter aren't a reset")
        history.recordResetTime(reset.addingTimeInterval(86_400), at: base.addingTimeInterval(180))
        XCTAssertNil(history.resets, "Moved later before it came: not a reset")
        XCTAssertFalse(history.recordResetTime(nil, at: base.addingTimeInterval(240)))
        XCTAssertEqual(history.windowResetsAt, reset.addingTimeInterval(86_400), "No reset time reported changes nothing")
    }

    /// Weeks saved before amounts and resets were kept still read, and write nothing new.
    func testAnOlderWeekStillDecodes() throws {
        let used = (0..<UsageHistory.capacity).map { $0 == UsageHistory.capacity - 1 ? "40" : "null" }.joined(separator: ",")
        let saved = Data(#"{"start":1789736400,"used":[\#(used)]}"#.utf8)
        let week = try RelayEnvelope.decoder.decode(UsageHistory.self, from: saved)
        XCTAssertEqual(week.start, Date(timeIntervalSince1970: 1_789_736_400))
        XCTAssertEqual(week.points.map(\.used), [40])
        XCTAssertNil(week.amounts)
        XCTAssertNil(week.resets)
        XCTAssertNil(week.windowResetsAt)
        XCTAssertTrue(week.amountPoints.isEmpty)
        let written = String(decoding: try RelayEnvelope.encoder.encode(week), as: UTF8.self)
        XCTAssertFalse(written.contains("amounts") || written.contains("resets") || written.contains("windowResetsAt"), "An older reader sees the same keys")
    }
}

final class RelayMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func provider(_ id: String, state: String = "live", used: Double, checked: TimeInterval) -> RelayProvider {
        RelayProvider(
            id: id, name: id.capitalized, shortName: id, monogram: "X", tint: "#000000", state: state,
            message: nil, checkedAt: now.addingTimeInterval(checked), fetchedAt: nil, plan: nil,
            primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: nil)]
        )
    }

    private func source(_ id: String, checked: TimeInterval = 0, _ providers: [RelayProvider]) -> RelayMerge.Source {
        RelayMerge.Source(
            id: id,
            label: id,
            envelope: RelayEnvelope(producer: "mac", appVersion: "2", checkedAt: now.addingTimeInterval(checked), providers: providers)
        )
    }

    func testNewestLiveReadingWins() {
        let entries = RelayMerge.entries(from: [
            source("a", [provider("claude", used: 40, checked: -600)]),
            source("b", [provider("claude", used: 55, checked: -60)]),
        ], now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sourceID, "b")
    }

    func testStaleNeverHidesAnotherLiveReading() {
        let entries = RelayMerge.entries(from: [
            source("a", [provider("claude", state: "expired", used: 90, checked: -10)]),
            source("b", [provider("claude", used: 55, checked: -3_600)]),
        ], now: now)
        XCTAssertEqual(entries.first?.sourceID, "b")
    }

    func testSilentSourcesAreDroppedAndOrderIsMostUsedFirst() {
        let entries = RelayMerge.entries(from: [
            source("old", checked: -8 * 86_400, [provider("cursor", used: 99, checked: -8 * 86_400)]),
            source("mac", [provider("claude", used: 20, checked: 0), provider("openai", used: 80, checked: 0)]),
        ], now: now)
        XCTAssertEqual(entries.map(\.id), ["openai", "claude"])
    }
}
