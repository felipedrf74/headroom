import XCTest
@testable import Tokenroom

final class AlertTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private var preferences: AlertPreferences {
        var preferences = AlertPreferences()
        preferences.timeZoneID = "UTC"
        return preferences
    }

    private func reading(used: Double, resetsAt: Date? = nil, state: String = "live", banked: BankedResets? = nil) -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: state,
            checkedAt: now, fetchedAt: now, primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: resetsAt ?? now.addingTimeInterval(2 * 86_400), periodSec: 7 * 86_400)],
            banked: banked
        )
    }

    func testFirstSightRaisesNothing() {
        XCTAssertTrue(AlertRules.alerts(previous: nil, current: reading(used: 97), preferences: preferences, now: now).isEmpty)
    }

    func testCrossingsAlertOnceAtTheHighestLevel() throws {
        let eighty = AlertRules.alerts(previous: reading(used: 70), current: reading(used: 82), preferences: preferences, now: now)
        XCTAssertEqual(eighty.map(\.level), [80])
        XCTAssertEqual(eighty.first?.title, "Claude: 80% of weekly used")
        XCTAssertFalse(try XCTUnwrap(eighty.first).isUrgent)

        let jump = AlertRules.alerts(previous: reading(used: 70), current: reading(used: 97), preferences: preferences, now: now)
        XCTAssertEqual(jump.map(\.level), [95], "A jump past both thresholds sends only the higher one")
        XCTAssertTrue(try XCTUnwrap(jump.first).isUrgent)

        XCTAssertTrue(AlertRules.alerts(previous: reading(used: 85), current: reading(used: 88), preferences: preferences, now: now).isEmpty, "Already past 80% in this window")
        XCTAssertTrue(AlertRules.alerts(previous: reading(used: 70), current: reading(used: 97, state: "stale"), preferences: preferences, now: now).isEmpty, "Only live readings alert")
    }

    func testResetJitterIsTheSameWindow() {
        let reset = now.addingTimeInterval(2 * 86_400)
        let alerts = AlertRules.alerts(previous: reading(used: 85, resetsAt: reset), current: reading(used: 86, resetsAt: reset.addingTimeInterval(180)), preferences: preferences, now: now)
        XCTAssertTrue(alerts.isEmpty, "Reset times a few minutes apart are one window, not a reset")
    }

    func testAResetAfterHeavyUseSaysSo() throws {
        let oldReset = now.addingTimeInterval(-60)
        let alerts = AlertRules.alerts(previous: reading(used: 91, resetsAt: oldReset), current: reading(used: 2, resetsAt: now.addingTimeInterval(7 * 86_400)), preferences: preferences, now: now)
        let reset = try XCTUnwrap(alerts.first { $0.kind == .reset })
        XCTAssertEqual(reset.body, "Fresh headroom. It was at 91% before the reset.")
        XCTAssertEqual(reset.id, "evt-claude-weekly-reset-\(AlertRules.instance(oldReset))")

        var quiet = preferences
        quiet.resets = false
        XCTAssertTrue(AlertRules.alerts(previous: reading(used: 91, resetsAt: oldReset), current: reading(used: 2, resetsAt: now.addingTimeInterval(7 * 86_400)), preferences: quiet, now: now).isEmpty)
        XCTAssertTrue(AlertRules.alerts(previous: reading(used: 40, resetsAt: oldReset), current: reading(used: 2, resetsAt: now.addingTimeInterval(7 * 86_400)), preferences: preferences, now: now).isEmpty, "A light week's reset isn't news")
    }

    func testANewWindowAlreadyPastAThresholdAlerts() {
        let alerts = AlertRules.alerts(previous: reading(used: 30, resetsAt: now.addingTimeInterval(-60)), current: reading(used: 81, resetsAt: now.addingTimeInterval(5 * 3600)), preferences: preferences, now: now)
        XCTAssertEqual(alerts.map(\.kind), [.threshold])
    }

    func testBankedResets() {
        let soon = now.addingTimeInterval(5 * 3600)
        let alerts = AlertRules.alerts(
            previous: reading(used: 10, banked: BankedResets(available: 1, expiries: [soon])),
            current: reading(used: 10, banked: BankedResets(available: 2, expiries: [soon, now.addingTimeInterval(9 * 86_400)])),
            preferences: preferences,
            now: now
        )
        XCTAssertEqual(alerts.map(\.kind), [.bankedNew, .bankedExpiring])
        XCTAssertEqual(alerts.last?.level, 6)
        XCTAssertEqual(alerts.last?.isUrgent, true, "Expiring within 6 hours is worth waking for")

        let later = AlertRules.alerts(
            previous: reading(used: 10, banked: BankedResets(available: 1, expiries: [now.addingTimeInterval(40 * 3600)])),
            current: reading(used: 10, banked: BankedResets(available: 1, expiries: [now.addingTimeInterval(40 * 3600)])),
            preferences: preferences,
            now: now
        )
        XCTAssertEqual(later.map(\.level), [48])
        XCTAssertEqual(later.first?.isUrgent, false)
    }

    func testQuietHours() {
        var preferences = self.preferences
        let at = { (hour: Int) in Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: hour))! }
        XCTAssertTrue(preferences.isQuiet(at: at(23)))
        XCTAssertTrue(preferences.isQuiet(at: at(3)))
        XCTAssertFalse(preferences.isQuiet(at: at(8)))
        XCTAssertFalse(preferences.isQuiet(at: at(21)))
        let eighty = UsageAlert(id: "a", provider: "claude", kind: .threshold, level: 80, title: "", body: "", isUrgent: false)
        let ninetyFive = UsageAlert(id: "b", provider: "claude", kind: .threshold, level: 95, title: "", body: "", isUrgent: true)
        XCTAssertFalse(preferences.shouldSend(eighty, at: at(23)))
        XCTAssertTrue(preferences.shouldSend(ninetyFive, at: at(23)))

        preferences.timeZoneID = "America/Los_Angeles"
        XCTAssertFalse(preferences.isQuiet(at: at(23)), "23:00 UTC is afternoon in Los Angeles")
        preferences.quietHours = false
        XCTAssertFalse(preferences.isQuiet(at: at(3)))
    }

    func testLedgerSendsEachAlertOnceAndDevicesAgreeOnIDs() {
        var mac = AlertLedger()
        var otherMac = AlertLedger()
        XCTAssertTrue(mac.process([reading(used: 70)], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(otherMac.process([reading(used: 71)], preferences: preferences, now: now).isEmpty)

        let first = mac.process([reading(used: 82)], preferences: preferences, now: now)
        let second = otherMac.process([reading(used: 83)], preferences: preferences, now: now.addingTimeInterval(90))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "Two Macs make the same record, so iCloud notifies once")

        // Stale in between, then back: judged against the last live reading, and not sent twice.
        XCTAssertTrue(mac.process([reading(used: 10, state: "stale")], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(mac.process([reading(used: 84)], preferences: preferences, now: now).isEmpty)

        let expired = mac.process([reading(used: 99)], preferences: preferences, now: now.addingTimeInterval(20 * 86_400))
        XCTAssertEqual(expired.map(\.level), [95])
        XCTAssertFalse(mac.sent.keys.contains(first[0].id), "IDs are forgotten after two weeks")
    }
}
