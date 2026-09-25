import XCTest
@testable import Tokenroom

final class APIKeyTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []
    private var stores: [APIKeyStore] = []

    override func tearDown() {
        for store in stores {
            for provider in Provider.allCases where provider.usesAPIKey {
                try? store.remove(for: provider)
            }
        }
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        stores = []
        suites = []
        folders = []
        super.tearDown()
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return folder
    }

    // MARK: Parsers

    func testOpenRouterKeyLimitIsAMonthlyMeter() throws {
        let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        let snapshot = try OpenRouterParser.snapshot(from: fixture("openrouter-limited"), fetchedAt: now)
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.kind, .monthly)
        XCTAssertTrue(window.isMetered)
        XCTAssertEqual(window.usedPercent, 25.5, accuracy: 0.001)
        XCTAssertEqual(window.amount?.remaining ?? 0, 74.5, accuracy: 0.001)
        XCTAssertEqual(window.resetsAt, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(window.startsAt, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertNil(snapshot.planLabel)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("masked"), "The key's label is never kept")
    }

    func testOpenRouterWithoutLimitShowsSpendUnmetered() throws {
        let snapshot = try OpenRouterParser.snapshot(from: fixture("openrouter-unlimited"))
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertFalse(window.isMetered)
        XCTAssertEqual(window.amount?.used ?? 0, 61.35, accuracy: 0.001)
        XCTAssertEqual(snapshot.planLabel, "Free tier")
        XCTAssertEqual(ProviderCard.amountHeadline(window.amount!)?.hasSuffix("spent"), true)
    }

    func testOpenRouterPeriodsResetAtUTCMidnight() {
        let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))! // Thursday
        let daily = OpenRouterParser.period("daily", now: now, calendar: .gregorianUTC)
        XCTAssertEqual(daily.end, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25)))
        let weekly = OpenRouterParser.period("weekly", now: now, calendar: .gregorianUTC)
        XCTAssertEqual(weekly.start, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 21)), "Weeks start Monday")
        XCTAssertEqual(OpenRouterParser.period(nil, now: now, calendar: .gregorianUTC).kind, .pool)
    }

    func testDeepSeekBalancePerCurrency() throws {
        let snapshot = try DeepSeekParser.snapshot(from: fixture("deepseek-balance"))
        XCTAssertEqual(snapshot.windows.map(\.id), ["balance-usd", "balance-cny"])
        XCTAssertEqual(snapshot.windows.first?.amount?.remaining ?? 0, 12.4, accuracy: 0.001)
        XCTAssertFalse(snapshot.windows.first?.isMetered ?? true)
        XCTAssertEqual(AmountFormat.text(12.4, unit: "usd", locale: Locale(identifier: "en_US")), "$12.40")
    }

    func testMoonshotRegionPicksHostAndCurrency() throws {
        let global = try MoonshotParser.snapshot(from: fixture("moonshot-balance"), region: "Global")
        XCTAssertEqual(global.windows.first?.amount?.unit, "usd")
        XCTAssertEqual(global.windows.first?.amount?.remaining ?? 0, 49.58894, accuracy: 0.0001)
        let china = try MoonshotParser.snapshot(from: fixture("moonshot-balance"), region: "China")
        XCTAssertEqual(china.windows.first?.amount?.unit, "cny")
        XCTAssertEqual(MoonshotEndpoint.balanceURL(region: "China").host, "api.moonshot.cn")
        XCTAssertEqual(MoonshotEndpoint.balanceURL(region: nil).host, "api.moonshot.ai")
    }

    func testVercelCredits() throws {
        let snapshot = try VercelGatewayParser.snapshot(from: fixture("vercel-credits"))
        XCTAssertEqual(snapshot.windows.first?.amount?.remaining ?? 0, 95.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows.first?.amount?.used ?? 0, 4.5, accuracy: 0.001)
    }

    // MARK: Keychain

    func testKeyStoreRoundTripShowsOnlyTheLastFour() throws {
        let store = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).")
        stores.append(store)
        XCTAssertNil(store.key(for: .openrouter))
        try store.save("  test-key-value-a1b2  ", for: .openrouter)
        XCTAssertEqual(store.key(for: .openrouter), "test-key-value-a1b2", "Pasted whitespace is trimmed")
        XCTAssertEqual(store.metadata(for: .openrouter)?.last4, "a1b2")
        try store.save("second-key-9z9z", for: .openrouter, region: "China")
        XCTAssertEqual(store.key(for: .openrouter), "second-key-9z9z", "Saving again replaces the key")
        XCTAssertEqual(store.metadata(for: .openrouter)?.region, "China")
        try store.remove(for: .openrouter)
        XCTAssertFalse(store.hasKey(for: .openrouter))
        XCTAssertThrowsError(try store.save("   ", for: .deepseek))
    }

    func testMissingKeyReadsAsSignedOut() async {
        let store = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).")
        let result = await APIKeyClient(provider: .deepseek, keys: store).fetch()
        XCTAssertEqual(result, .failure(.signedOut(Provider.deepseek.signInHint)))
    }

    // MARK: Menu bar and popover

    @MainActor
    func testBalancesStayOutOfTheMenuBarAndHighestShowsOne() async throws {
        let defaults = makeDefaults()
        defaults.set(["claude", "cursor", "deepseek"], forKey: "enabledProviders")
        let balance = try DeepSeekParser.snapshot(from: fixture("deepseek-balance"))
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [
                StaticClient(provider: .deepseek, snapshot: balance),
                StaticClient(provider: .claude, snapshot: meterSnapshot(.claude, used: 30)),
                StaticClient(provider: .cursor, snapshot: meterSnapshot(.cursor, used: 80)),
            ],
            cache: SnapshotCache(directory: makeFolder())
        )
        await store.refresh(force: true)
        XCTAssertEqual(Set(store.menuMeters.map(\.provider)), [.claude, .cursor])
        XCTAssertEqual(MenuBarLayout.displayed(store.menuMeters, style: .highest).map(\.provider), [.cursor])

        store.settings.setShowsInMenuBar(.cursor, false)
        XCTAssertEqual(store.menuMeters.map(\.provider), [.claude])
        XCTAssertEqual(AppSettings(defaults: defaults).hiddenFromMenuBar, [.cursor], "Choice persists")
    }

    @MainActor
    func testPopoverListsConnectedFirst() async throws {
        let defaults = makeDefaults()
        defaults.set(["claude", "cursor"], forKey: "enabledProviders")
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [
                StaticClient(provider: .claude, snapshot: meterSnapshot(.claude, used: 30)),
                FailingClient(provider: .cursor, error: .signedOut(Provider.cursor.signInHint)),
            ],
            cache: SnapshotCache(directory: makeFolder())
        )
        await store.refresh(force: true)
        XCTAssertEqual(store.connectedProviders, [.claude])
        XCTAssertEqual(store.disconnectedProviders, [.cursor])
    }

    private func meterSnapshot(_ provider: Provider, used: Double) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider, usedPercent: used, resetsAt: nil, fetchedAt: .now, primaryTitle: "Weekly",
            windows: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: nil)]
        )
    }
}

private struct StaticClient: ProviderClient {
    let provider: Provider
    let snapshot: QuotaSnapshot
    func fetch() async -> Result<QuotaSnapshot, ProviderError> { .success(snapshot) }
}

private struct FailingClient: ProviderClient {
    let provider: Provider
    let error: ProviderError
    func fetch() async -> Result<QuotaSnapshot, ProviderError> { .failure(error) }
}
