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
            "threshold-80", "lowBalance-80", "threshold-95", "lowBalance-95",
            "reset", "bankedNew", "bankedExpiring-48", "bankedExpiring-6", "test",
        ])
        var few = AlertPreferences()
        few.thresholds = [95]
        few.lowBalance = false
        few.resets = false
        few.banked = false
        XCTAssertEqual(few.subscribedKeys, ["threshold-95", "test"], "Test alerts always come through")
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
