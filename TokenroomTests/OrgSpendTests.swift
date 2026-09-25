import XCTest
@testable import Tokenroom

final class OrgSpendTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    func testOpenAICostsSumEveryResultAcrossPages() throws {
        let first = try OpenAICostsParser.page(from: fixture("openai-costs-page1"))
        XCTAssertEqual(first.total, 16, accuracy: 0.0001)
        XCTAssertEqual(first.nextPage, "page_2")
        let second = try OpenAICostsParser.page(from: fixture("openai-costs-page2"))
        XCTAssertEqual(second.total, 4, accuracy: 0.0001)
        XCTAssertNil(second.nextPage)
    }

    func testAnthropicCostReportIsInCents() throws {
        let page = try AnthropicCostParser.page(from: fixture("anthropic-cost-report"))
        XCTAssertEqual(page.total, 13.345, accuracy: 0.0001)
        XCTAssertNil(page.nextPage)
    }

    func testXAITeamCreditsAndInvoice() throws {
        XCTAssertEqual(try XAIBillingParser.teamID(fromValidation: fixture("xai-validation")), "team-placeholder", "scopeId wins over the deprecated teamId")
        XCTAssertFalse(XAIBillingParser.canWrite(fromValidation: fixture("xai-validation")))
        XCTAssertTrue(XAIBillingParser.canWrite(fromValidation: Data(#"{"scopeId":"t","acls":["api-key:endpoint:*"]}"#.utf8)))

        let invoice = try XAIBillingParser.invoice(from: fixture("xai-invoice-preview"))
        XCTAssertEqual(invoice.spend, 312.5, accuracy: 0.001)
        XCTAssertEqual(invoice.limit ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(try XAIBillingParser.prepaidCredits(from: fixture("xai-prepaid-balance")), 25, accuracy: 0.001)

        let window = OrgSpend.spendWindow(invoice.spend, limit: invoice.limit, now: now)
        XCTAssertTrue(window.isMetered)
        XCTAssertEqual(window.usedPercent, 31.25, accuracy: 0.001)
        XCTAssertEqual(window.resetsAt, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    }

    func testSpendWithoutLimitIsAnAmount() {
        let window = OrgSpend.spendWindow(312.5, now: now)
        XCTAssertFalse(window.isMetered)
        XCTAssertEqual(ReadingText.amountHeadline(window.amount!)?.hasSuffix("spent"), true)
    }

    // MARK: Budgets

    func testBudgetTurnsSpendAndBalancesIntoMeters() throws {
        let spend = OrgSpend.snapshot(.openaiOrg, window: OrgSpend.spendWindow(250, now: now), fetchedAt: now)
        let budgeted = spend.applyingBudget(1000)
        XCTAssertTrue(budgeted.windows[0].isMetered)
        XCTAssertEqual(budgeted.usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(budgeted.windows[0].amount?.limit, 1000)

        let balance = try DeepSeekParser.snapshot(from: fixture("deepseek-balance"))
        let reference = balance.applyingBudget(50)
        XCTAssertEqual(reference.windows[0].usedPercent, 75.2, accuracy: 0.001, "$12.40 left of $50 is 75.2% used")

        let credits = try VercelGatewayParser.snapshot(from: fixture("vercel-credits"))
        XCTAssertEqual(credits.applyingBudget(100).usedPercent, 4.5, accuracy: 0.001, "Balances measure what's left, not lifetime use")
    }

    func testABudgetIsInTheFirstBalancesCurrency() throws {
        let balance = try DeepSeekParser.snapshot(from: fixture("deepseek-balance"))
        XCTAssertEqual(balance.budgetUnit, "usd")
        XCTAssertEqual(balance.budgetCurrencyCode, "USD")
        let budgeted = balance.applyingBudget(50)
        let dollars = budgeted.windows[0]
        XCTAssertTrue(dollars.isMetered)
        XCTAssertEqual(dollars.amount?.used ?? 0, 37.6, accuracy: 0.001, "Spent from the $50 reference, not a lifetime total")
        XCTAssertEqual(dollars.amount?.limit, 50)
        XCTAssertEqual(dollars.amount?.remaining, 12.4)
        XCTAssertEqual(ReadingText.amountDetail(try XCTUnwrap(dollars.amount)), "\(AmountFormat.text(37.6, unit: "usd")) of \(AmountFormat.text(50, unit: "usd"))")
        XCTAssertEqual(budgeted.windows[1], balance.windows[1], "A yuan balance isn't measured against a dollar budget")

        let china = try MoonshotParser.snapshot(from: fixture("moonshot-balance"), region: "China")
        XCTAssertEqual(china.budgetCurrencyCode, "CNY")
        let reference = china.applyingBudget(100)
        XCTAssertEqual(reference.usedPercent, 100 - 49.58894, accuracy: 0.001)
        XCTAssertEqual(reference.windows[0].amount?.unit, "cny")
        XCTAssertEqual(reference.windows[0].amount?.used ?? 0, 100 - 49.58894, accuracy: 0.001)

        let spend = OrgSpend.snapshot(.openaiOrg, window: OrgSpend.spendWindow(250, now: now), fetchedAt: now)
        XCTAssertEqual(spend.budgetCurrencyCode, "USD")
        XCTAssertEqual(spend.applyingBudget(1000).windows[0].amount?.used, 250, "Spend keeps what was spent")
        let plain = QuotaSnapshot(provider: .claude, usedPercent: 0, resetsAt: nil, fetchedAt: now, primaryTitle: "Weekly", windows: [])
        XCTAssertNil(plain.budgetUnit)
        XCTAssertEqual(plain.budgetCurrencyCode, "USD")
    }

    func testAmountsSayWhatIsLeftOrSpent() {
        XCTAssertEqual(ReadingText.amountHeadline(QuotaAmount(remaining: 12.4, unit: "usd")), "\(AmountFormat.text(12.4, unit: "usd")) left")
        XCTAssertEqual(ReadingText.amountHeadline(QuotaAmount(used: 37.6, limit: 50, unit: "usd")), "\(AmountFormat.text(12.4, unit: "usd")) left", "Worked out from a limit")
        XCTAssertEqual(ReadingText.amountHeadline(QuotaAmount(remaining: 80, unit: "cny")), "\(AmountFormat.text(80, unit: "cny")) left")
        XCTAssertEqual(ReadingText.amountHeadline(QuotaAmount(used: 312.5, unit: "usd")), "\(AmountFormat.text(312.5, unit: "usd")) spent")
        XCTAssertNil(ReadingText.amountHeadline(QuotaAmount(unit: "usd")))
    }

    func testBudgetLeavesMeteredWindowsAndMissingBudgetsAlone() throws {
        let metered = try OpenRouterParser.snapshot(from: fixture("openrouter-limited"), fetchedAt: now)
        XCTAssertEqual(metered.applyingBudget(10), metered)
        let spend = OrgSpend.snapshot(.anthropicOrg, window: OrgSpend.spendWindow(250, now: now), fetchedAt: now)
        XCTAssertEqual(spend.applyingBudget(nil), spend)
        XCTAssertEqual(spend.applyingBudget(0), spend)
    }

    @MainActor
    func testChangingABudgetUpdatesTheReadingAtOnce() async throws {
        let suite = "tokenroom.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["openaiOrg"], forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = OrgSpend.snapshot(.openaiOrg, window: OrgSpend.spendWindow(250, now: now), fetchedAt: now)
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [FixedClient(provider: .openaiOrg, snapshot: snapshot)],
            cache: SnapshotCache(directory: folder)
        )
        await store.refresh(force: true)
        XCTAssertTrue(store.menuMeters.isEmpty, "Spend without a budget stays out of the menu bar")

        store.settings.setBudget(500, for: .openaiOrg)
        store.budgetDidChange(for: .openaiOrg)
        XCTAssertEqual(store.statuses[.openaiOrg]?.snapshot?.usedPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(store.menuMeters.map(\.provider), [.openaiOrg])
        XCTAssertEqual(AppSettings(defaults: defaults).budget(for: .openaiOrg), 500, "Budgets persist")
    }
}

private struct FixedClient: ProviderClient {
    let provider: Provider
    let snapshot: QuotaSnapshot
    func fetch() async -> Result<QuotaSnapshot, ProviderError> { .success(snapshot) }
}
