import XCTest
@testable import Tokenroom

final class AlertTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private var preferences: AlertPreferences {
        var preferences = AlertPreferences()
        preferences.timeZoneID = "UTC"
        return preferences
    }

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func reading(used: Double, resetsAt: Date? = nil, state: String = "live", banked: BankedResets? = nil) -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: state,
            checkedAt: now, fetchedAt: now, primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: resetsAt ?? now.addingTimeInterval(2 * 86_400), periodSec: 7 * 86_400)],
            banked: banked
        )
    }

    /// A DeepSeek balance measured against a $20 reference, as a collector relays it.
    private func balance(remaining: Double, reference: Double = 20) -> RelayProvider {
        RelayProvider(
            id: "deepseek", name: "DeepSeek", shortName: "DeepSeek", monogram: "DS", tint: "#4D6BFE", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: "balance-usd",
            windows: [RelayWindow(
                id: "balance-usd", kind: "pool", title: "Balance", used: (1 - remaining / reference) * 100, resetsAt: nil,
                amount: QuotaAmount(used: reference - remaining, limit: reference, remaining: remaining, unit: "usd"), metered: true
            )]
        )
    }

    /// This month's organization spend against a $1,000 budget.
    private func spend(_ spent: Double, resetsAt: Date) -> RelayProvider {
        RelayProvider(
            id: "anthropicOrg", name: "Anthropic API", shortName: "Anthropic API", monogram: "AN", tint: "#B85C38", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: "spend-month",
            windows: [RelayWindow(
                id: "spend-month", kind: "monthly", title: "This month", used: spent / 1000 * 100, resetsAt: resetsAt,
                amount: QuotaAmount(used: spent, limit: 1000, unit: "usd"), metered: true
            )]
        )
    }

    private func session(used: Double, resetsAt: Date) -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: "session",
            windows: [RelayWindow(id: "session", kind: "session", title: "Session", used: used, resetsAt: resetsAt, periodSec: 5 * 3600)]
        )
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    // MARK: Rules

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
        let before = reading(used: 91, resetsAt: oldReset)
        let alerts = AlertRules.alerts(previous: before, current: reading(used: 2, resetsAt: now.addingTimeInterval(7 * 86_400)), preferences: preferences, now: now)
        let reset = try XCTUnwrap(alerts.first { $0.kind == .reset })
        XCTAssertEqual(reset.body, "Fresh headroom. It was at 91% before the reset.")
        XCTAssertEqual(reset.id, "evt-claude-weekly-reset-\(AlertRules.instance(oldReset, window: before.windows[0], now: now))", "Named by the window that ended, to the hour for a week")
        XCTAssertEqual(reset.key, "reset")

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

    func testInstancesRoundToTheHourForLongWindows() {
        let weekly = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 50, resetsAt: nil, periodSec: 7 * 86_400)
        let session = RelayWindow(id: "session", kind: "session", title: "Session", used: 50, resetsAt: nil, periodSec: 5 * 3600)
        let early = utc(2026, 9, 27, 19, 10)
        let late = utc(2026, 9, 27, 19, 25)
        XCTAssertEqual(AlertRules.instance(early, window: weekly), AlertRules.instance(late, window: weekly), "Readings 15 minutes apart name the same week")
        XCTAssertNotEqual(AlertRules.instance(early, window: session), AlertRules.instance(late, window: session), "Sessions keep 10-minute precision")

        let onTheHour = utc(2026, 9, 27, 19)
        XCTAssertEqual(AlertRules.instance(onTheHour, window: weekly), AlertRules.instance(onTheHour), "Both roundings count in 10-minute units")
        let unsized = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 50, resetsAt: nil)
        XCTAssertEqual(AlertRules.instance(early, window: unsized), AlertRules.instance(late, window: unsized), "A week without a reported length is still a week")

        XCTAssertEqual(AlertRules.instance(nil, window: weekly, now: now), "d20721", "No reset: the day names it")
        XCTAssertEqual(AlertRules.instance(nil, window: weekly, now: now.addingTimeInterval(86_400)), "d20722")
        XCTAssertEqual(AlertRules.instance(nil), "open")
    }

    // MARK: Balances and budgets

    func testBalancesRaiseLowBalanceInsteadOfThresholds() throws {
        let alerts = AlertRules.alerts(previous: balance(remaining: 6), current: balance(remaining: 3), preferences: preferences, now: now)
        XCTAssertEqual(alerts.map(\.kind), [.lowBalance], "Money never raises a percent threshold")
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.level, 80)
        XCTAssertEqual(alert.key, "lowBalance-80")
        XCTAssertEqual(alert.title, "DeepSeek: balance is low")
        XCTAssertEqual(alert.body, "\(AmountFormat.text(3, unit: "usd")) left of your \(AmountFormat.text(20, unit: "usd")) reference.")
        XCTAssertNil(alert.resetsAt)
        XCTAssertFalse(alert.isUrgent)

        let nearlyOut = AlertRules.alerts(previous: balance(remaining: 6), current: balance(remaining: 0.5), preferences: preferences, now: now)
        XCTAssertEqual(nearlyOut.map(\.key), ["lowBalance-95"])
        XCTAssertEqual(nearlyOut.first?.isUrgent, true)

        var off = preferences
        off.lowBalance = false
        XCTAssertTrue(AlertRules.alerts(previous: balance(remaining: 6), current: balance(remaining: 3), preferences: off, now: now).isEmpty)
    }

    func testASpendBudgetReadsAsSpend() throws {
        let monthEnd = utc(2026, 10, 1)
        let alert = try XCTUnwrap(AlertRules.alerts(previous: spend(700, resetsAt: monthEnd), current: spend(812.5, resetsAt: monthEnd), preferences: preferences, now: now).first)
        XCTAssertEqual(alert.kind, .lowBalance)
        XCTAssertEqual(alert.title, "Anthropic API: 80% of the budget spent")
        XCTAssertEqual(alert.body, "\(AmountFormat.text(812.5, unit: "usd")) of \(AmountFormat.text(1000, unit: "usd")) so far. It resets in 5d 12h.")
        XCTAssertEqual(alert.resetsAt, monthEnd)

        let newMonth = AlertRules.alerts(
            previous: spend(950, resetsAt: now.addingTimeInterval(-60)),
            current: spend(5, resetsAt: utc(2026, 11, 1)),
            preferences: preferences,
            now: now
        )
        XCTAssertTrue(newMonth.isEmpty, "A new month after heavy spend isn't fresh headroom")
    }

    func testALowBalanceAlertReArmsTheNextDay() throws {
        var ledger = AlertLedger()
        ledger.process([balance(remaining: 6)], preferences: preferences, now: now)
        let first = ledger.process([balance(remaining: 3)], preferences: preferences, now: now.addingTimeInterval(600))
        XCTAssertEqual(first.map(\.kind), [.lowBalance])
        ledger.markSent(first.map(\.id), at: now.addingTimeInterval(600))

        // Topped up and spent down again the same day: the same alert, already sent.
        ledger.process([balance(remaining: 18)], preferences: preferences, now: now.addingTimeInterval(3600))
        XCTAssertTrue(ledger.process([balance(remaining: 2.8)], preferences: preferences, now: now.addingTimeInterval(2 * 3600)).isEmpty)

        // The next day it can warn again.
        ledger.process([balance(remaining: 18)], preferences: preferences, now: now.addingTimeInterval(86_400))
        let nextDay = ledger.process([balance(remaining: 3)], preferences: preferences, now: now.addingTimeInterval(86_400 + 3600))
        XCTAssertEqual(nextDay.map(\.kind), [.lowBalance])
        XCTAssertNotEqual(nextDay.first?.id, first.first?.id)
    }

    // MARK: Delivery

    func testNonUrgentAlertsWaitOutQuietHours() throws {
        let late = utc(2026, 9, 25, 23)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: late)
        let raised = ledger.process([reading(used: 82)], preferences: preferences, now: late)
        XCTAssertEqual(raised.map(\.level), [80])
        XCTAssertEqual(ledger.pending.map(\.alert.id), raised.map(\.id), "Raised, not yet sent")
        XCTAssertTrue(ledger.sent.isEmpty)
        XCTAssertTrue(ledger.due(preferences: preferences, now: late).isEmpty, "80% can wait for the morning")

        let morning = utc(2026, 9, 26, 8, 5)
        XCTAssertEqual(ledger.due(preferences: preferences, now: morning).map(\.id), raised.map(\.id))
        ledger.markSent(raised.map(\.id), at: morning)
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(ledger.sent[raised[0].id], morning)
        XCTAssertTrue(ledger.due(preferences: preferences, now: morning).isEmpty)
    }

    func testUrgentAlertsGoOutDuringQuietHours() throws {
        let late = utc(2026, 9, 25, 23)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: late)
        let raised = ledger.process([reading(used: 97)], preferences: preferences, now: late)
        XCTAssertEqual(try XCTUnwrap(raised.first).isUrgent, true)
        XCTAssertEqual(ledger.due(preferences: preferences, now: late).map(\.id), raised.map(\.id))
    }

    func testAHeldAlertIsDroppedOnceItsWindowResets() {
        let late = utc(2026, 9, 25, 23)
        let sessionEnds = utc(2026, 9, 26, 2)
        var ledger = AlertLedger()
        ledger.process([session(used: 60, resetsAt: sessionEnds)], preferences: preferences, now: late)
        XCTAssertEqual(ledger.process([session(used: 85, resetsAt: sessionEnds)], preferences: preferences, now: late).map(\.kind), [.threshold])

        ledger.process([session(used: 3, resetsAt: utc(2026, 9, 26, 7))], preferences: preferences, now: utc(2026, 9, 26, 3))
        XCTAssertFalse(ledger.pending.contains { $0.alert.kind == .threshold }, "The session it warned about is over")
        XCTAssertEqual(ledger.due(preferences: preferences, now: utc(2026, 9, 26, 8, 5)).map(\.kind), [.reset], "The morning brings the reset instead")
    }

    func testHeldAlertsExpireAfterEighteenHours() {
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: now)
        let raised = ledger.process([reading(used: 82)], preferences: preferences, now: now)
        // iCloud never took it.
        ledger.process([], preferences: preferences, now: now.addingTimeInterval(17 * 3600))
        XCTAssertEqual(ledger.pending.map(\.alert.id), raised.map(\.id))
        ledger.process([], preferences: preferences, now: now.addingTimeInterval(19 * 3600))
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertNil(ledger.sent[raised[0].id], "Dropped, not sent")
    }

    func testShownHereIsRememberedForTwoWeeks() {
        var ledger = AlertLedger()
        ledger.markShownHere(["evt-a"], at: now)
        XCTAssertEqual(ledger.shownHere["evt-a"], now)
        ledger.process([], preferences: preferences, now: now.addingTimeInterval(13 * 86_400))
        XCTAssertNotNil(ledger.shownHere["evt-a"])
        ledger.process([], preferences: preferences, now: now.addingTimeInterval(15 * 86_400))
        XCTAssertNil(ledger.shownHere["evt-a"])
    }

    func testLedgerQueuesEachAlertOnceAndDevicesAgreeOnIDs() {
        var mac = AlertLedger()
        var otherMac = AlertLedger()
        XCTAssertTrue(mac.process([reading(used: 70)], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(otherMac.process([reading(used: 71)], preferences: preferences, now: now).isEmpty)

        let first = mac.process([reading(used: 82)], preferences: preferences, now: now)
        let second = otherMac.process([reading(used: 83)], preferences: preferences, now: now.addingTimeInterval(90))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "Two Macs make the same record, so iCloud notifies once")

        // Still waiting to go out: dipping under 80% and crossing again doesn't queue a second one.
        XCTAssertTrue(mac.process([reading(used: 75)], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(mac.process([reading(used: 82)], preferences: preferences, now: now).isEmpty)
        XCTAssertEqual(mac.pending.map(\.alert.id), first.map(\.id))
        mac.markSent(first.map(\.id), at: now)

        // Stale in between: judged against the last live reading.
        XCTAssertTrue(mac.process([reading(used: 10, state: "stale")], preferences: preferences, now: now).isEmpty)
        XCTAssertEqual(mac.lastSeen["claude"]?.windows.first?.used, 82)
        // Once sent, never again for the same week.
        XCTAssertTrue(mac.process([reading(used: 75)], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(mac.process([reading(used: 84)], preferences: preferences, now: now).isEmpty, "Crossing 80% again in the same week was already sent")
        XCTAssertTrue(mac.pending.isEmpty)

        let expired = mac.process([reading(used: 99)], preferences: preferences, now: now.addingTimeInterval(20 * 86_400))
        XCTAssertEqual(expired.map(\.level), [95])
        XCTAssertFalse(mac.sent.keys.contains(first[0].id), "IDs are forgotten after two weeks")
    }

    func testALedgerFromAnOlderBuildStillLoads() throws {
        let folder = try makeFolder()
        try Data(#"{"lastSeen":{},"sent":{"evt-claude-weekly-80-2983896":1790337600}}"#.utf8)
            .write(to: folder.appendingPathComponent(AlertLedger.fileName))
        let older = AlertLedger.load(from: folder)
        XCTAssertEqual(older.sent.count, 1)
        XCTAssertTrue(older.pending.isEmpty)
        XCTAssertTrue(older.shownHere.isEmpty)

        var queued = AlertLedger()
        queued.process([reading(used: 70)], preferences: preferences, now: now)
        queued.process([reading(used: 82)], preferences: preferences, now: now)
        queued.markShownHere(queued.pending.map(\.alert.id), at: now)
        queued.save(to: folder)
        XCTAssertEqual(AlertLedger.load(from: folder), queued, "Held alerts survive a relaunch")
    }

    // MARK: Preferences

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

    func testPreferencesFromAnOlderBuildKeepTheirChoices() throws {
        let saved = Data(#"{"thresholds":[95],"quietHours":false}"#.utf8)
        let preferences = try JSONDecoder().decode(AlertPreferences.self, from: saved)
        XCTAssertEqual(preferences.thresholds, [95])
        XCTAssertFalse(preferences.quietHours)
        XCTAssertTrue(preferences.resets, "Keys an older build didn't write take their defaults")
        XCTAssertTrue(preferences.newModels)
        XCTAssertTrue(preferences.lowBalance)
        XCTAssertNil(preferences.updatedAt, "Never changed since dates were kept")
    }

    func testQuietHoursEndForHeldNotifications() {
        let late = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!
        XCTAssertEqual(preferences.quietEnd(after: late), Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 8)))
        XCTAssertNil(preferences.quietEnd(after: now), "Noon isn't quiet")
    }

    func testAlertKeys() {
        func alert(_ kind: UsageAlert.Kind, _ level: Int) -> UsageAlert {
            UsageAlert(id: "x", provider: "claude", kind: kind, level: level, title: "", body: "", isUrgent: false)
        }
        XCTAssertEqual(alert(.threshold, 80).key, "threshold-80")
        XCTAssertEqual(alert(.lowBalance, 95).key, "lowBalance-95")
        XCTAssertEqual(alert(.bankedExpiring, 48).key, "bankedExpiring-48")
        XCTAssertEqual(alert(.reset, 0).key, "reset")
        XCTAssertEqual(alert(.bankedNew, 0).key, "bankedNew")
    }

    func testSubscriptionFollowsTheChoices() {
        XCTAssertEqual(AlertPreferences().subscribedKeys, [
            "threshold-80", "threshold-95", "lowBalance-80", "lowBalance-95",
            "reset", "bankedNew", "bankedExpiring-48", "bankedExpiring-6", "test",
        ])
        var few = AlertPreferences()
        few.thresholds = [95]
        few.lowBalance = false
        few.resets = false
        few.banked = false
        XCTAssertEqual(few.subscribedKeys, ["threshold-95", "test"], "Test alerts always come through")
        var balancesOnly = AlertPreferences()
        balancesOnly.thresholds = []
        balancesOnly.resets = false
        balancesOnly.banked = false
        XCTAssertEqual(balancesOnly.subscribedKeys, ["lowBalance-80", "lowBalance-95", "test"], "Balances have their own switch")
    }

    func testBalancesFollowTheirOwnSwitchAlone() {
        var balancesOnly = preferences
        balancesOnly.thresholds = []
        let alerts = AlertRules.alerts(previous: balance(remaining: 6), current: balance(remaining: 3), preferences: balancesOnly, now: now)
        XCTAssertEqual(alerts.map(\.key), ["lowBalance-80"], "With the usage levels off, a low balance still warns")
        let usage = AlertRules.alerts(previous: reading(used: 70), current: reading(used: 97), preferences: balancesOnly, now: now)
        XCTAssertTrue(usage.isEmpty, "Usage windows follow the usage levels")
    }

    // MARK: Held alerts

    func testAHeldEightyDoesNotFollowTheNinetyFive() {
        let late = utc(2026, 9, 25, 23)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: late)
        let eighty = ledger.process([reading(used: 82)], preferences: preferences, now: late)
        let ninetyFive = ledger.process([reading(used: 96)], preferences: preferences, now: late.addingTimeInterval(1800))
        XCTAssertEqual(ninetyFive.map(\.level), [95])
        XCTAssertEqual(ledger.due(preferences: preferences, now: late.addingTimeInterval(1800)).map(\.id), ninetyFive.map(\.id), "95% goes out at once, 80% waits")
        ledger.markSent(ninetyFive.map(\.id), at: late.addingTimeInterval(1800))

        let morning = utc(2026, 9, 26, 8, 5)
        XCTAssertTrue(ledger.due(preferences: preferences, now: morning).isEmpty, "The 80% held overnight would arrive after the 95%")
        ledger.process([], preferences: preferences, now: morning)
        XCTAssertFalse(ledger.pending.contains { $0.alert.id == eighty.first?.id }, "Dropped")
    }

    func testAHeldEightyDoesNotFollowTheNinetyFiveAcrossAMovedReset() throws {
        let late = utc(2026, 9, 25, 23)
        let reset = now.addingTimeInterval(2 * 86_400)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70, resetsAt: reset)], preferences: preferences, now: late)
        let eighty = try XCTUnwrap(ledger.process([reading(used: 82, resetsAt: reset)], preferences: preferences, now: late).first)
        // The provider moved the reset three hours on; the week goes on and crosses 95%.
        let ninetyFive = ledger.process([reading(used: 96, resetsAt: reset.addingTimeInterval(3 * 3600))], preferences: preferences, now: late.addingTimeInterval(1800))
        XCTAssertEqual(ninetyFive.map(\.level), [95])
        XCTAssertNotEqual(AlertRules.id(of: eighty, atLevel: 95), ninetyFive.first?.id, "Named by different reset times")
        ledger.markSent(ninetyFive.map(\.id), at: late.addingTimeInterval(1800))
        XCTAssertTrue(ledger.due(preferences: preferences, now: utc(2026, 9, 26, 8, 5)).isEmpty, "The 80% held overnight still doesn't follow it")
    }

    func testAHeldAlertSaysHowLongIsLeftWhenItGoesOut() throws {
        let late = utc(2026, 9, 25, 23)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: late)
        let raised = try XCTUnwrap(ledger.process([reading(used: 82)], preferences: preferences, now: late).first)
        let morning = utc(2026, 9, 26, 8, 5)
        let sent = try XCTUnwrap(ledger.due(preferences: preferences, now: morning).first)
        XCTAssertEqual(sent.id, raised.id)
        let left = try XCTUnwrap(RelativeTime.resets(try XCTUnwrap(raised.resetsAt), now: morning))
        XCTAssertEqual(sent.body, left.prefix(1).uppercased() + left.dropFirst() + ".")
        XCTAssertNotEqual(sent.body, raised.body)

        let monthEnd = utc(2026, 10, 1)
        let budget = try XCTUnwrap(AlertRules.alerts(previous: spend(700, resetsAt: monthEnd), current: spend(812.5, resetsAt: monthEnd), preferences: preferences, now: now).first)
        let later = AlertRules.refreshed(budget, now: now.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(later.body, "\(AmountFormat.text(812.5, unit: "usd")) of \(AmountFormat.text(1000, unit: "usd")) so far. It resets in 2d 12h.")
    }

    func testAHeldAlertTurnedOffMeanwhileIsDropped() {
        let late = utc(2026, 9, 25, 23)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: preferences, now: late)
        ledger.process([reading(used: 82)], preferences: preferences, now: late)
        var off = preferences
        off.thresholds = [95]
        let morning = utc(2026, 9, 26, 8, 5)
        XCTAssertTrue(ledger.due(preferences: off, now: morning).isEmpty)
        ledger.process([], preferences: off, now: morning)
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testLongQuietHoursKeepHeldAlertsUntilTheyEnd() {
        var long = preferences
        long.quietStartHour = 18
        long.quietEndHour = 16
        let evening = utc(2026, 9, 25, 19)
        var ledger = AlertLedger()
        ledger.process([reading(used: 70)], preferences: long, now: evening)
        let raised = ledger.process([reading(used: 82)], preferences: long, now: evening)
        ledger.process([], preferences: long, now: evening.addingTimeInterval(20 * 3600))
        XCTAssertEqual(ledger.pending.map(\.alert.id), raised.map(\.id), "22 quiet hours: still held after 20")
        XCTAssertEqual(ledger.due(preferences: long, now: utc(2026, 9, 26, 16, 5)).map(\.id), raised.map(\.id))
    }

    func testAResetLongAgoIsNotNews() {
        let daysAgo = now.addingTimeInterval(-3 * 86_400)
        let alerts = AlertRules.alerts(previous: reading(used: 91, resetsAt: daysAgo), current: reading(used: 2, resetsAt: now.addingTimeInterval(4 * 86_400)), preferences: preferences, now: now)
        XCTAssertFalse(alerts.contains { $0.kind == .reset }, "A device asleep for days doesn't announce a reset from then")
    }

    func testAMovedResetIsTheSameWindow() {
        let reset = now.addingTimeInterval(3 * 3600)
        let moved = AlertRules.alerts(previous: session(used: 85, resetsAt: reset), current: session(used: 86, resetsAt: reset.addingTimeInterval(3600)), preferences: preferences, now: now)
        XCTAssertTrue(moved.isEmpty, "The provider moved the reset; the session goes on, already past 80%")
        let dipped = AlertRules.alerts(previous: session(used: 85, resetsAt: reset), current: session(used: 81, resetsAt: reset.addingTimeInterval(3600)), preferences: preferences, now: now)
        XCTAssertTrue(dipped.isEmpty, "A small dip isn't a new window either")
        let farther = AlertRules.alerts(previous: session(used: 85, resetsAt: reset), current: session(used: 86, resetsAt: reset.addingTimeInterval(2 * 3600)), preferences: preferences, now: now)
        XCTAssertEqual(farther.map(\.level), [80], "Two hours on is more than a quarter of a session: another window")
        XCTAssertFalse(AlertRules.isSameInstance(
            before: session(used: 85, resetsAt: reset).windows[0],
            current: session(used: 4, resetsAt: reset.addingTimeInterval(5 * 3600)).windows[0],
            now: now
        ), "Use falling away means the window started over early")
    }

    func testABalanceAlertNamedByDayPointsAtTheDaysAround() throws {
        let alert = try XCTUnwrap(AlertRules.alerts(previous: balance(remaining: 6), current: balance(remaining: 3), preferences: preferences, now: now).first)
        XCTAssertEqual(alert.instanceName, "d20721")
        XCTAssertEqual(AlertRules.neighbouringDayIDs(of: alert), ["d20720", "d20722"].map { alert.id.replacingOccurrences(of: "d20721", with: $0) })
        let weekly = try XCTUnwrap(AlertRules.alerts(previous: reading(used: 70), current: reading(used: 82), preferences: preferences, now: now).first)
        XCTAssertEqual(AlertRules.neighbouringDayIDs(of: weekly), [], "A window with a reset is named by it, the same on every device")
        let fromOlderBuild = UsageAlert(id: "evt-deepseek-balance-usd-low-80-d20721", provider: "deepseek", kind: .lowBalance, level: 80, title: "", body: "", isUrgent: false)
        XCTAssertEqual(AlertRules.neighbouringDayIDs(of: fromOlderBuild), ["evt-deepseek-balance-usd-low-80-d20720", "evt-deepseek-balance-usd-low-80-d20722"])
    }

    // MARK: Sharing the choices

    func testChoicesMadeOnEachDeviceBothStay() {
        let utc = TimeZone(identifier: "UTC")!
        var base = preferences
        base.touch(now: now, timeZone: utc)
        var mac = base
        mac.quietHours = false
        mac.touch(now: now.addingTimeInterval(60), timeZone: utc)
        var phone = base
        phone.thresholds = [95]
        phone.touch(now: now.addingTimeInterval(30), timeZone: utc)

        let resolution = AlertPreferencesSync.resolve(base: base, local: mac, remote: phone)
        XCTAssertTrue(resolution.needsPublish)
        XCTAssertFalse(resolution.preferences.quietHours, "The Mac's change")
        XCTAssertEqual(resolution.preferences.thresholds, [95], "The iPhone's, made while the Mac's copy was older, isn't undone")
        XCTAssertEqual(resolution.preferences.updatedAt, now.addingTimeInterval(60))
    }

    func testSyncTakesChangesFromICloudAndSendsOnesMadeHere() {
        let utc = TimeZone(identifier: "UTC")!
        var base = preferences
        base.touch(now: now, timeZone: utc)
        var remote = base
        remote.banked = false
        remote.touch(now: now.addingTimeInterval(60), timeZone: utc)
        XCTAssertEqual(AlertPreferencesSync.resolve(base: base, local: base, remote: remote), AlertPreferencesSync.Resolution(preferences: remote, needsPublish: false), "Nothing changed here: take iCloud's")

        var local = base
        local.resets = false
        local.touch(now: now.addingTimeInterval(60), timeZone: utc)
        XCTAssertEqual(AlertPreferencesSync.resolve(base: base, local: local, remote: base), AlertPreferencesSync.Resolution(preferences: local, needsPublish: true), "Changed only here, offline say: send it")
        XCTAssertTrue(AlertPreferencesSync.resolve(base: nil, local: local, remote: nil).needsPublish)
        XCTAssertFalse(AlertPreferencesSync.resolve(base: nil, local: AlertPreferences(), remote: nil).needsPublish, "Never changed: nothing to share")

        var reloaded = base
        reloaded.updatedAt = base.updatedAt?.addingTimeInterval(0.000_000_1)
        XCTAssertFalse(AlertPreferencesSync.resolve(base: base, local: reloaded, remote: remote).needsPublish, "A saved copy's date coming back a hair off isn't a change")
    }

    func testThresholdLevelsMergeOneByOne() {
        let utc = TimeZone(identifier: "UTC")!
        var base = preferences
        base.touch(now: now, timeZone: utc)
        var phone = base
        phone.thresholds = [95]
        phone.touch(now: now.addingTimeInterval(30), timeZone: utc)
        var mac = base
        mac.thresholds = [80]
        mac.touch(now: now.addingTimeInterval(60), timeZone: utc)
        let resolution = AlertPreferencesSync.resolve(base: base, local: mac, remote: phone)
        XCTAssertTrue(resolution.needsPublish)
        XCTAssertEqual(resolution.preferences.thresholds, [], "80% turned off on the iPhone and 95% on the Mac: both stay off")

        var fewer = base
        fewer.thresholds = [95]
        var added = fewer
        added.thresholds = [80, 95]
        added.touch(now: now.addingTimeInterval(30), timeZone: utc)
        var removed = fewer
        removed.thresholds = []
        removed.touch(now: now.addingTimeInterval(60), timeZone: utc)
        XCTAssertEqual(AlertPreferencesSync.resolve(base: fewer, local: removed, remote: added).preferences.thresholds, [80], "80% added there, 95% removed here")
    }

    /// A copy dated before the base is still the shared copy: its device's clock may run behind,
    /// or an older Tokenroom dated it by that clock. (A read that began before the iPhone's own
    /// save finished is the iPhone's to skip, by when the read began.)
    func testACopyDatedBeforeTheBaseIsStillTaken() {
        let utc = TimeZone(identifier: "UTC")!
        var base = preferences
        base.touch(now: now.addingTimeInterval(60), timeZone: utc)
        var behind = base
        behind.resets = false
        behind.updatedAt = now
        XCTAssertEqual(AlertPreferencesSync.resolve(base: base, local: base, remote: behind), AlertPreferencesSync.Resolution(preferences: behind, needsPublish: false), "Taken")

        var changed = base
        changed.banked = false
        changed.touch(now: now.addingTimeInterval(120), timeZone: utc)
        let merged = AlertPreferencesSync.resolve(base: base, local: changed, remote: behind)
        XCTAssertTrue(merged.needsPublish)
        XCTAssertFalse(merged.preferences.resets, "Its change")
        XCTAssertFalse(merged.preferences.banked, "And this one's")
    }

    func testChoicesSentAreNeverDatedBeforeTheCopyTheyBuildOn() {
        let utc = TimeZone(identifier: "UTC")!
        var base = preferences
        // From a device whose clock runs ahead…
        base.touch(now: now.addingTimeInterval(600), timeZone: utc)
        var local = base
        local.quietHours = false
        // …changed on one whose clock runs behind.
        local.touch(now: now, timeZone: utc)
        let resolution = AlertPreferencesSync.resolve(base: base, local: local, remote: base)
        XCTAssertTrue(resolution.needsPublish)
        XCTAssertFalse(resolution.preferences.quietHours)
        XCTAssertEqual(resolution.preferences.updatedAt, base.updatedAt, "Otherwise the other device would take it for an older copy")
        XCTAssertEqual(AlertPreferencesSync.resolve(base: base, local: base, remote: resolution.preferences).preferences, resolution.preferences, "It takes it")
    }

    func testADeviceNewToSyncingKeepsChoicesOnlyTheSharedCopyKnows() throws {
        let remote = try RelayEnvelope.decoder.decode(AlertPreferences.self, from: Data(#"{"thresholds":[95],"digest":{"hour":9},"updatedAt":1790000000}"#.utf8))
        var local = preferences
        local.resets = false
        local.touch(now: Date(timeIntervalSince1970: 1_790_000_600), timeZone: TimeZone(identifier: "UTC")!)
        let resolution = AlertPreferencesSync.resolve(base: nil, local: local, remote: remote)
        XCTAssertTrue(resolution.needsPublish)
        XCTAssertFalse(resolution.preferences.resets, "The newer copy's choices")
        XCTAssertEqual(resolution.preferences.thresholds, [80, 95])
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: RelayEnvelope.encoder.encode(resolution.preferences)) as? [String: Any])
        XCTAssertNotNil(written["digest"], "A choice from a newer Tokenroom stays")
    }

    func testChoicesANewerVersionAddedSurviveBeingSavedHere() throws {
        let saved = Data(#"{"thresholds":[95],"digest":{"hour":9,"days":[1,5]},"quietHours":false}"#.utf8)
        var preferences = try RelayEnvelope.decoder.decode(AlertPreferences.self, from: saved)
        preferences.resets = false
        let written = try RelayEnvelope.encoder.encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let digest = try XCTUnwrap(object["digest"] as? [String: Any])
        XCTAssertEqual(digest["hour"] as? Int, 9, "A choice this build doesn't know goes back as it came")
        XCTAssertEqual(digest["days"] as? [Int], [1, 5])
        XCTAssertEqual(object["resets"] as? Bool, false)
        XCTAssertEqual(try RelayEnvelope.decoder.decode(AlertPreferences.self, from: written), preferences)
    }

    func testEveryAlertTheRulesRaiseIsSubscribedByDefault() {
        let soon = BankedResets(available: 1, expiries: [now.addingTimeInterval(5 * 3600)])
        let later = BankedResets(available: 1, expiries: [now.addingTimeInterval(40 * 3600)])
        let steps: [(RelayProvider, RelayProvider)] = [
            (reading(used: 70), reading(used: 82)),
            (reading(used: 70), reading(used: 97)),
            (reading(used: 91, resetsAt: now.addingTimeInterval(-60)), reading(used: 2, resetsAt: now.addingTimeInterval(7 * 86_400))),
            (reading(used: 10, banked: BankedResets(available: 0)), reading(used: 10, banked: soon)),
            (reading(used: 10, banked: later), reading(used: 10, banked: later)),
            (balance(remaining: 6), balance(remaining: 3)),
            (balance(remaining: 6), balance(remaining: 0.5)),
        ]
        var raised: [UsageAlert] = []
        for (previous, current) in steps {
            raised += AlertRules.alerts(previous: previous, current: current, preferences: preferences, now: now)
        }
        XCTAssertEqual(Set(raised.map(\.kind)), [.threshold, .reset, .bankedNew, .bankedExpiring, .lowBalance])
        let subscribed = Set(AlertPreferences().subscribedKeys)
        for alert in raised {
            XCTAssertTrue(subscribed.contains(alert.key), "\(alert.key) would never reach the iPhone")
        }
        XCTAssertEqual(Set(raised.map(\.key)), subscribed.subtracting(["test"]), "Nothing subscribed that can't be raised")
        var everything = AlertPreferences()
        everything.thresholds = AlertPreferences.supportedThresholds
        everything.lowBalance = true
        for alert in raised {
            XCTAssertFalse(everything.subscribedKeys.contains(alert.shownKey), "An alert an iPhone showed itself never comes back to it as a push")
        }
    }

    func testTheCopyChangedLastWins() {
        var mac = AlertPreferences()
        mac.touch(now: now, timeZone: TimeZone(identifier: "Europe/Madrid")!)
        XCTAssertEqual(mac.updatedAt, now)
        XCTAssertEqual(mac.timeZoneID, "Europe/Madrid", "Quiet hours follow the device that set them")

        var phone = AlertPreferences()
        phone.quietHours = false
        phone.touch(now: now.addingTimeInterval(60), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(AlertPreferences.newest(phone, mac), phone, "A newer shared copy wins")
        XCTAssertEqual(AlertPreferences.newest(mac, phone), phone, "A newer local copy wins")
        XCTAssertEqual(AlertPreferences.newest(nil, mac), mac, "Nothing shared yet")

        var undated = AlertPreferences()
        undated.thresholds = [95]
        XCTAssertEqual(AlertPreferences.newest(undated, mac), mac, "Never changed counts as oldest")
        XCTAssertEqual(AlertPreferences.newest(mac, undated), mac)
        XCTAssertEqual(AlertPreferences.newest(undated, AlertPreferences()), undated, "On a tie the shared copy wins")
        var sameMoment = phone
        sameMoment.banked = false
        XCTAssertEqual(AlertPreferences.newest(sameMoment, phone), sameMoment)
    }
}
