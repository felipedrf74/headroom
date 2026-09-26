import SwiftUI
import XCTest
@testable import TokenroomMobile

/// What only the iPhone app does: its store, and the state it shares with its widgets. Shared
/// logic is tested on the Mac in TokenroomTests.
final class MobileStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600) // 2026-09-25 12:00 UTC
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        super.tearDown()
    }

    /// A throwaway stand-in for the App Group's defaults, named by the class and a count so runs
    /// reuse a few preferences files instead of leaving one behind per test.
    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A store with no iCloud, a Keychain prefix no real key uses, and its own folder.
    @MainActor
    private func makeStore(defaults: UserDefaults, folder: URL) -> MobileStore {
        MobileStore(
            defaults: defaults,
            containerIdentifier: nil,
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString)."),
            directory: folder
        )
    }

    // MARK: Store

    @MainActor
    func testSampleModeShowsLabelledSamplesAndSavesThemForWidgets() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileStore.Keys.sampleMode)
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)

        XCTAssertTrue(store.sampleMode)
        XCTAssertEqual(store.relayPhase, .unavailable, "No iCloud container")
        XCTAssertEqual(Set(store.readings.map(\.id)), Set(SampleData.cache().items.map(\.id)))
        XCTAssertTrue(store.readings.allSatisfy { $0.source == SampleData.sourceLabel })
        XCTAssertEqual(store.sourceSummary, SampleData.sourceLabel)
        XCTAssertNotNil(store.reading(id: "claude")?.history["weekly"])
        XCTAssertTrue(store.disconnected.isEmpty)

        let saved = try XCTUnwrap(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName)))
        XCTAssertTrue(saved.isSample, "Widgets show the same samples, labelled")
        XCTAssertEqual(saved.items.map(\.id), store.readings.map(\.id))
    }

    @MainActor
    func testALaunchThatCantReadICloudKeepsTheOtherDevicesReadings() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let fromMac = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 42, resetsAt: now.addingTimeInterval(86_400))]
        )
        let cacheURL = folder.appendingPathComponent(ReadingCache.fileName)
        try ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: fromMac, source: "Mac")]).save(to: cacheURL)

        // No iCloud in this store, like a launch that's offline.
        let store = makeStore(defaults: defaults, folder: folder)
        await store.refresh(force: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(store.readings.map(\.id), ["claude"], "The Mac's reading stays until iCloud answers")
        XCTAssertEqual(store.readings.first?.source, "Mac")
        let saved = try XCTUnwrap(ReadingCache.load(from: cacheURL))
        XCTAssertEqual(saved.items.map(\.id), ["claude"], "Widgets and the Watch keep it too")
    }

    @MainActor
    func testLeavingSampleModeWithNothingConnectedShowsNothing() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileStore.Keys.sampleMode)
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        store.sampleMode = false
        XCTAssertFalse(defaults.bool(forKey: MobileStore.Keys.sampleMode))
        XCTAssertTrue(store.readings.isEmpty)

        await store.refresh(force: true)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertTrue(store.keyedProviders.isEmpty)
        XCTAssertEqual(store.relayStatusText, "Not available in this build")
        XCTAssertNotNil(store.lastRefresh)
        XCTAssertEqual(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName))?.isSample, false, "Widgets stop showing samples")
    }

    @MainActor
    func testBudgetsAreInDollarsUntilABalanceSaysOtherwise() throws {
        let store = makeStore(defaults: makeDefaults(), folder: try makeFolder())
        XCTAssertEqual(store.budgetCurrency(for: .deepseek), "USD")
        XCTAssertEqual(store.budgetCurrency(for: .moonshot), "USD")
        XCTAssertNil(store.budget(for: .deepseek))
    }

    @MainActor
    func testAlertChoicesMadeOnTheIPhoneAreStampedAndKept() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        XCTAssertNil(store.alertPreferences.updatedAt)
        store.alertPreferences.lowBalance = false
        XCTAssertNotNil(store.alertPreferences.updatedAt, "Stamped, so the newer copy wins against a Mac's")
        XCTAssertFalse(defaults.bool(forKey: MobileStore.Keys.alertPreferencesShared), "Waiting to reach iCloud")
        XCTAssertEqual(makeStore(defaults: defaults, folder: folder).alertPreferences, store.alertPreferences)
    }

    @MainActor
    func testQuietHoursFollowThisIPhoneOnlyWhenItsZoneChanges() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        var elsewhere = AlertPreferences()
        elsewhere.timeZoneID = TimeZone.current.identifier == "Pacific/Auckland" ? "Europe/Madrid" : "Pacific/Auckland"
        defaults.set(try JSONEncoder().encode(elsewhere), forKey: MobileStore.Keys.alertPreferences)

        let store = makeStore(defaults: defaults, folder: folder)
        await store.refresh(force: true)
        XCTAssertEqual(store.alertPreferences.timeZoneID, TimeZone.current.identifier, "The shared choices take this iPhone's zone")
        XCTAssertNil(store.alertPreferences.updatedAt, "Not a change of choices")

        // Another iPhone in its own zone set it since; this one hasn't moved.
        defaults.set(try JSONEncoder().encode(elsewhere), forKey: MobileStore.Keys.alertPreferences)
        let again = makeStore(defaults: defaults, folder: folder)
        await again.refresh(force: true)
        XCTAssertEqual(again.alertPreferences.timeZoneID, elsewhere.timeZoneID, "Two iPhones don't take turns rewriting it")
    }

    /// Anthropic's report is 15 minutes apart: a budget changed before the next call shows on
    /// the saved reading at once.
    @MainActor
    func testABudgetShowsOnASavedReadingAtOnce() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let checked = Date()
        let balance = QuotaWindow(id: "balance-cny", kind: .pool, title: "Balance", usedPercent: 0, resetsAt: nil, amount: QuotaAmount(remaining: 12.4, unit: "cny"), metered: false)
        let snapshot = QuotaSnapshot(provider: .deepseek, usedPercent: 0, resetsAt: nil, fetchedAt: checked, primaryTitle: "Balance", windows: [balance])
        let saved = RelayProvider(provider: .deepseek, status: .live(snapshot.applyingBudget(50)), checkedAt: checked)
        try ReadingCache(savedAt: checked, isSample: false, items: [ReadingCache.Item(provider: saved, source: MobileStore.localLabel)])
            .save(to: folder.appendingPathComponent(ReadingCache.fileName))
        defaults.set([Provider.deepseek.rawValue], forKey: MobileStore.Keys.keyedProviders)

        let store = makeStore(defaults: defaults, folder: folder)
        XCTAssertEqual(store.budgetCurrency(for: .deepseek), "CNY", "From the saved reading, before this launch reads it")
        store.setBudget(100, for: .deepseek)
        let window = try XCTUnwrap(store.reading(id: Provider.deepseek.rawValue)?.provider.windows.first)
        XCTAssertEqual(window.used, 87.6, accuracy: 0.001, "12.40 left of 100")
        XCTAssertEqual(window.amount?.limit, 100)
    }

    // MARK: Shared with the widgets

    func testWidgetsSeeTheAppsCallsThroughTheSharedGate() {
        let defaults = makeDefaults()
        KeyFetchGate(defaults: defaults).recordAttempt(.anthropicOrg, at: now)
        let widget = KeyFetchGate(defaults: defaults)
        XCTAssertTrue(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(60)), "Anthropic's cost report allows a call every 15 minutes")
        XCTAssertFalse(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(15 * 60)))

        widget.block(.openrouter, until: now.addingTimeInterval(600))
        XCTAssertTrue(KeyFetchGate(defaults: defaults).isResting(.openrouter, now: now), "A 429 in a widget holds the app off too")
        XCTAssertFalse(KeyFetchGate(defaults: makeDefaults()).isResting(.openrouter, now: now))
    }

    @MainActor
    func testResetCountdownTicksWithinADay() {
        XCTAssertEqual(ResetCountdown.text(resetsAt: now.addingTimeInterval(-60), date: now), Text("now"))
        XCTAssertEqual(ResetCountdown.text(resetsAt: now.addingTimeInterval(3 * 86_400 + 3600), date: now), Text(String("3d 1h")))
        let ticking = ResetCountdown.text(resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60), date: now)
        XCTAssertNotEqual(ticking, Text("now"))
        XCTAssertNotEqual(ticking, Text(String("2h 13m")), "Within a day the clock counts down by itself, without reloads")
    }
}
