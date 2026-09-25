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
        let relayed = RelayHistory(series: [RelayHistory.key(provider: "claude", window: "weekly"): week])
        XCTAssertEqual(try RelayHistory.decode(relayed.encoded()), relayed)
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
