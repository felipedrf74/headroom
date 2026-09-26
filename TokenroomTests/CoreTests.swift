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
        let passed = try XCTUnwrap(Pace.evaluate(used: 70, kind: .weekly, resetsAt: reset, measured: RelayPace(runsOutAt: now.addingTimeInterval(-60)), now: now))
        XCTAssertEqual(passed.runsOutAt, now, "A run-out time that has passed means it has run out by now, not that it won't")
        XCTAssertEqual(passed.severity, .critical)

        var window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 70, resetsAt: reset, periodSec: week, pace: RelayPace(runsOutAt: now.addingTimeInterval(10 * 3600)))
        XCTAssertEqual(UsageRanking.pace(for: window, isStale: false, history: nil, now: now)?.runsOutAt, now.addingTimeInterval(10 * 3600), "Readers use the relayed pace")
        window.pace = RelayPace(runsOutAt: now.addingTimeInterval(-600))
        XCTAssertEqual(UsageRanking.pace(for: window, isStale: false, history: nil, now: now)?.severity, .critical, "Seen after the relayed run-out, it reads as out")
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

    // MARK: Resets used early

    private let week: TimeInterval = 7 * 86_400

    /// A weekly window at 92%, its reset a day away.
    private func busyWeek() -> UsageHistory {
        var history = UsageHistory(endingAt: base)
        history.record(92, at: base)
        history.recordResetTime(base.addingTimeInterval(86_400), used: 92, length: week, at: base)
        return history
    }

    func testABankedResetUsedEarlyIsNoted() {
        // Used 20 minutes after the last reading, and seen 10 minutes later, in the same hour.
        let opened = base.addingTimeInterval(20 * 60)
        let seen = opened.addingTimeInterval(10 * 60)
        var sameHour = busyWeek()
        sameHour.record(0, at: seen)
        XCTAssertTrue(sameHour.recordResetTime(opened.addingTimeInterval(week), used: 0, length: week, at: seen))
        XCTAssertEqual(sameHour.resets, [opened], "Marked when the new window opened, a day before the old reset")
        XCTAssertEqual(sameHour.windowResetsAt, opened.addingTimeInterval(week))
        XCTAssertFalse(sameHour.recordResetTime(opened.addingTimeInterval(week + 60), used: 1, length: week, at: seen.addingTimeInterval(600)), "Only once")
        XCTAssertEqual(sameHour.resets, [opened])

        // Seen hours later, with the reset time checked before the reading's use is recorded.
        let later = base.addingTimeInterval(3 * 3600)
        var hoursLater = busyWeek()
        XCTAssertTrue(hoursLater.recordResetTime(opened.addingTimeInterval(week), used: 6, length: week, at: later))
        hoursLater.record(6, at: later)
        XCTAssertEqual(hoursLater.resets, [opened])
    }

    func testOnlyASharpDropInANewWindowIsAnEarlyReset() {
        let movedOn = base.addingTimeInterval(2 * 86_400)
        let next = base.addingTimeInterval(10 * 60)
        var noise = busyWeek()
        XCTAssertTrue(noise.recordResetTime(movedOn, used: 91, length: week, at: next), "The new reset time is kept")
        XCTAssertNil(noise.resets, "A point of noise or rounding isn't a reset")

        var slid = busyWeek()
        slid.recordResetTime(movedOn, used: 80, length: week, at: next)
        XCTAssertNil(slid.resets, "Nor is falling 12 points, well short of half")

        var replanned = busyWeek()
        replanned.recordResetTime(next.addingTimeInterval(week), used: 30, length: week, at: next)
        XCTAssertNil(replanned.resets, "Nor a fall to a third, as when a plan changes mid-week or a reset follows the last use: a window that just started is near nothing")

        var ahead = busyWeek()
        ahead.recordResetTime(base.addingTimeInterval(86_400 + week), used: 0, length: week, at: next)
        XCTAssertNil(ahead.resets, "A reset time for the window after this one, which hasn't begun")

        var unknown = busyWeek()
        unknown.recordResetTime(next.addingTimeInterval(week), used: 0, at: next)
        XCTAssertNil(unknown.resets, "Without the window's length, only a reset whose time has passed counts")
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

/// Weeks as the Mac and the iPhone record them from readings.
final class HistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let week: TimeInterval = 7 * 86_400

    private func reading(_ windows: [QuotaWindow], at date: Date) -> QuotaSnapshot {
        try! QuotaSnapshot.headlined(by: windows, provider: .openai, fetchedAt: date)
    }

    private func weekly(_ used: Double, resetsAt: Date, id: String = "weekly") -> QuotaWindow {
        QuotaWindow(id: id, kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: resetsAt, windowSeconds: week)
    }

    /// Codex's reset credits: one used a day early shows on the week's chart.
    @MainActor
    func testABankedResetUsedEarlyIsMarked() {
        let store = HistoryStore(directory: nil)
        store.record(reading([weekly(92, resetsAt: now.addingTimeInterval(86_400))], at: now), now: now)
        let used = now.addingTimeInterval(15 * 60)
        let seen = now.addingTimeInterval(25 * 60)
        store.record(reading([weekly(0, resetsAt: used.addingTimeInterval(week))], at: seen), now: seen)
        XCTAssertEqual(store.weeks(for: .openai)["weekly"]?.resets, [used])
    }

    @MainActor
    func testAReadingDatedAheadOfTheClockStaysOut() {
        let store = HistoryStore(directory: nil)
        let reset = now.addingTimeInterval(3 * 86_400)
        store.record(reading([weekly(40, resetsAt: reset)], at: now.addingTimeInterval(365 * 86_400)), now: now)
        XCTAssertTrue(store.weeks.isEmpty, "Dated a year ahead, it would move the week past every later reading")
        store.record(reading([weekly(41, resetsAt: reset)], at: now.addingTimeInterval(30 * 60)), now: now)
        XCTAssertEqual(store.weeks(for: .openai)["weekly"]?.points.map(\.used), [41], "Within the hour is fine")
    }

    @MainActor
    func testAWeekAheadOfTheClockStartsOver() throws {
        // Saved from a reading dated a year ahead, before those were left out.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let yearAhead = now.addingTimeInterval(365 * 86_400)
        var ahead = UsageHistory(endingAt: yearAhead)
        ahead.record(40, at: yearAhead)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")
        try RelayEnvelope.encoder.encode([key: ahead]).write(to: folder.appendingPathComponent(HistoryStore.fileName))

        let store = HistoryStore(directory: folder)
        store.record(reading([weekly(41, resetsAt: now.addingTimeInterval(3 * 86_400))], at: now), now: now)
        let recorded = try XCTUnwrap(store.weeks(for: .openai)["weekly"])
        XCTAssertEqual(recorded.points.map(\.date), [UsageHistory.hourStart(now)], "Readings land again instead of being older than the week")
        XCTAssertEqual(recorded.points.map(\.used), [41])
    }

    @MainActor
    func testWindowsWithoutAReadingForAWeekAreForgotten() {
        let store = HistoryStore(directory: nil)
        let reset = now.addingTimeInterval(3 * 86_400)
        store.record(reading([weekly(40, resetsAt: reset), weekly(30, resetsAt: reset, id: "opus")], at: now), now: now)
        // The provider stops reporting the second window.
        let sixDays = now.addingTimeInterval(6 * 86_400)
        store.record(reading([weekly(50, resetsAt: sixDays.addingTimeInterval(86_400))], at: sixDays), now: sixDays)
        XCTAssertEqual(Set(store.weeks(for: .openai).keys), ["weekly", "opus"], "Still inside the week")
        let aWeek = now.addingTimeInterval(week + 3600)
        store.record(reading([weekly(55, resetsAt: aWeek.addingTimeInterval(86_400))], at: aWeek), now: aWeek)
        XCTAssertEqual(Set(store.weeks(for: .openai).keys), ["weekly"], "Nothing left of it in the last week")
        XCTAssertEqual(Set(store.relayHistory(for: [.openai]).series.keys), [RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")])
    }

    /// Widgets read keys while the app isn't running; the app records what they read.
    @MainActor
    func testReadingsWidgetsTookReachTheWeek() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reset = now.addingTimeInterval(3 * 86_400)
        let key = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")
        HistoryStore.queue([reading([weekly(30, resetsAt: reset)], at: now)], in: folder, now: now)
        HistoryStore.queue([reading([weekly(35, resetsAt: reset)], at: now.addingTimeInterval(3600))], in: folder, now: now)
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: now.addingTimeInterval(3600))[key]?.points.map(\.used), [30, 35], "A widget shows them at once")
        XCTAssertTrue(HistoryStore.load(from: folder).isEmpty, "Only the app writes the week")

        let store = HistoryStore(directory: folder)
        store.takePending(now: now.addingTimeInterval(2 * 3600))
        store.saveIfNeeded()
        XCTAssertEqual(HistoryStore.load(from: folder)[key]?.points.map(\.used), [30, 35])
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty, "Taken once")
    }

    func testTheWidgetQueueKeepsAnHoursLatestReading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reset = now.addingTimeInterval(3 * 86_400)
        let readings = (0..<150).map { reading([weekly(Double($0 % 100), resetsAt: reset)], at: now.addingTimeInterval(Double($0) * 60)) }
        HistoryStore.queue(readings, in: folder, now: now)
        let hours = Set(readings.map { UsageHistory.hourStart($0.fetchedAt) })
        XCTAssertEqual(HistoryStore.pending(in: folder).count, hours.count, "One reading a provider an hour")
        XCTAssertEqual(HistoryStore.pending(in: folder).last?.fetchedAt, readings.last?.fetchedAt)
        HistoryStore.queue([readings[readings.count - 2]], in: folder, now: now)
        XCTAssertEqual(HistoryStore.pending(in: folder).last?.fetchedAt, readings.last?.fetchedAt, "An earlier reading doesn't replace a later one")

        let later = now.addingTimeInterval(8 * 86_400)
        HistoryStore.queue([reading([weekly(5, resetsAt: later.addingTimeInterval(86_400))], at: later)], in: folder, now: later)
        XCTAssertEqual(HistoryStore.pending(in: folder).map(\.fetchedAt), [later], "What the week no longer holds goes")
    }

    /// A refresh cut short after moving the queue aside records it the next time.
    @MainActor
    func testQueuedReadingsSurviveARefreshCutShort() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reset = now.addingTimeInterval(3 * 86_400)
        let key = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")
        HistoryStore.queue([reading([weekly(30, resetsAt: reset)], at: now)], in: folder, now: now)
        let queue = folder.appendingPathComponent(HistoryStore.pendingFolderName)
        let taking = folder.appendingPathComponent(HistoryStore.takingFolderName)
        try FileManager.default.moveItem(at: queue, to: taking)
        HistoryStore.queue([reading([weekly(45, resetsAt: reset)], at: now.addingTimeInterval(2 * 3600))], in: folder, now: now)
        XCTAssertEqual(HistoryStore.pending(in: folder).count, 2, "Both still waiting")

        let store = HistoryStore(directory: folder)
        store.takePending(now: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(HistoryStore.load(from: folder)[key]?.points.map(\.used), [30, 45], "Saved as it's taken")
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    /// Copilot's month read with a token had its own ID in 2.0.0; its week carries on.
    @MainActor
    func testCopilotsOlderHistoryCarriesOn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var week = UsageHistory(endingAt: now)
        week.record(40, at: now)
        let old = RelayHistory.key(provider: Provider.copilot.rawValue, window: CopilotBilling.legacyWindowID)
        try RelayEnvelope.encoder.encode([old: week]).write(to: folder.appendingPathComponent(HistoryStore.fileName))

        let current = RelayHistory.key(provider: Provider.copilot.rawValue, window: CopilotBilling.windowID)
        XCTAssertEqual(HistoryStore.load(from: folder), [current: week], "Widgets read it under the new ID")
        let store = HistoryStore(directory: folder)
        XCTAssertEqual(store.weeks(for: .copilot)[CopilotBilling.windowID], week)
        store.saveIfNeeded()
        let saved = try RelayEnvelope.decoder.decode([String: UsageHistory].self, from: Data(contentsOf: folder.appendingPathComponent(HistoryStore.fileName)))
        XCTAssertEqual(Array(saved.keys), [current], "Saved under it")
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
