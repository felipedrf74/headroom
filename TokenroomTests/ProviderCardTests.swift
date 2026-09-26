import XCTest
@testable import Tokenroom

/// What a popover card says besides its numbers: where a reading came from, whether it's
/// current, and what the week's line shows.
final class ProviderCardTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    private func reading(_ provider: Provider, source: String? = nil, fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider, usedPercent: 40, resetsAt: nil, fetchedAt: fetchedAt, primaryTitle: "Weekly",
            windows: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 40, resetsAt: nil)],
            source: source
        )
    }

    @MainActor
    func testCopilotReadWithATokenIsntUnofficial() {
        XCTAssertTrue(ProviderCard.readsUnofficially(.copilot, snapshot: reading(.copilot, fetchedAt: now)), "The login reads copilot_internal")
        XCTAssertFalse(ProviderCard.readsUnofficially(.copilot, snapshot: reading(.copilot, source: "copilot-token", fetchedAt: now)), "The token reads GitHub's documented billing API")
        XCTAssertTrue(ProviderCard.readsUnofficially(.claude, snapshot: reading(.claude, source: "bridge", fetchedAt: now)))
        XCTAssertFalse(ProviderCard.readsUnofficially(.openrouter, snapshot: reading(.openrouter, fetchedAt: now)))
    }

    /// No time with it: the direct call may be what confirmed a status line reading last, and
    /// "Checked …" says when.
    @MainActor
    func testAStatusLineReadingSaysWhereItCameFrom() {
        let kept = reading(.claude, source: "bridge", fetchedAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(ProviderCard.sourceCaption(kept), "via Claude Code's status line")
        XCTAssertEqual(ProviderCard.sourceCaption(reading(.copilot, source: "copilot-token", fetchedAt: now)), "With your fine-grained token")
        XCTAssertNil(ProviderCard.sourceCaption(reading(.claude, fetchedAt: now)), "Claude's own usage call needs no caption")
    }

    /// One-line rows gray out a reading that isn't current; they also say why, in a tooltip and
    /// to VoiceOver.
    @MainActor
    func testCompactRowsSayWhyAReadingIsntCurrent() throws {
        let old = reading(.claude, fetchedAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertNil(ProviderCard.compactNote(.live(old), provider: .claude, checkedAt: now, now: now))

        let stale = try XCTUnwrap(ProviderCard.compactNote(.stale(old), provider: .claude, checkedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertEqual(stale.text, "Last good reading, 1h ago.")
        XCTAssertEqual(ProviderCard.compactNote(.unreachable(cached: old), provider: .claude, checkedAt: nil, now: now)?.text, "Last good reading, 3h ago.")

        let until = now.addingTimeInterval(1800)
        let limited = try XCTUnwrap(ProviderCard.compactNote(.rateLimited(until: until, cached: old), provider: .claude, checkedAt: now, now: now))
        XCTAssertEqual(limited.text, "Couldn't refresh. Claude asked to wait until \(until.formatted(date: .omitted, time: .shortened)).")
        XCTAssertNotEqual(limited.symbol, stale.symbol, "Waiting and out of date look different")
    }

    @MainActor
    func testTheWeeksLineIsDescribedForVoiceOver() {
        var week = UsageHistory(endingAt: now)
        week.record(20, at: now.addingTimeInterval(-5 * 3600))
        week.record(82, at: now.addingTimeInterval(-2 * 3600))
        week.record(40, at: now)
        XCTAssertEqual(ProviderCard.weekSummary(week), "Highest 82%, latest 40%")
        XCTAssertEqual(ProviderCard.weekSummary(UsageHistory(endingAt: now)), "No readings")
    }
}
