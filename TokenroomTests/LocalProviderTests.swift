import XCTest
@testable import Tokenroom

/// Copilot, Devin, and Antigravity: providers read with another tool's login on the Mac.
final class LocalProviderTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    // MARK: Copilot

    func testCopilotFreeHidesThePremiumPlaceholder() throws {
        let snapshot = try CopilotParser.snapshot(from: fixture("copilot-user-free"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["chat", "completions"])
        XCTAssertEqual(snapshot.usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].amount, QuotaAmount(used: 50, limit: 200, remaining: 150, unit: "messages"))
        XCTAssertEqual(snapshot.resetsAt, utc(2026, 10, 1))
        XCTAssertEqual(snapshot.windows[0].startsAt, utc(2026, 9, 1))
        XCTAssertEqual(snapshot.planLabel, "Copilot Free", "The SKU says Free even though copilot_plan says individual")
    }

    func testCopilotProLeadsWithPremiumRequestsAndHidesUnlimited() throws {
        let snapshot = try CopilotParser.snapshot(from: fixture("copilot-user-pro"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["premium_interactions"])
        XCTAssertEqual(snapshot.usedPercent, 100, "Overage reads as a full meter")
        XCTAssertEqual(snapshot.windows[0].amount, QuotaAmount(used: 312, limit: 300, remaining: 0, unit: "requests"))
        XCTAssertEqual(snapshot.resetsAt, utc(2026, 10, 1), "A date-only reset is midnight UTC")
        XCTAssertEqual(snapshot.planLabel, "Copilot Pro")
    }

    func testCopilotOlderFreeShape() throws {
        let snapshot = try CopilotParser.snapshot(from: fixture("copilot-user-legacy"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["chat", "completions"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [50, 50])
        XCTAssertEqual(snapshot.resetsAt, utc(2026, 10, 15))
    }

    func testCopilotTokenBillingCountsAICredits() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("copilot-user-pro")) as? [String: Any])
        object["token_based_billing"] = true
        let snapshot = try CopilotParser.snapshot(from: JSONSerialization.data(withJSONObject: object), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.title), ["AI credits"])
        XCTAssertEqual(snapshot.windows[0].id, "premium_interactions", "Same bucket, same ID, so history carries on")
        XCTAssertEqual(snapshot.windows[0].amount?.unit, "credits")
        XCTAssertEqual(snapshot.primaryTitle, "AI credits")
        XCTAssertEqual(try CopilotParser.snapshot(from: fixture("copilot-user-free"), fetchedAt: now).windows.map(\.title), ["Chat", "Completions"], "Only the premium bucket is renamed")
    }

    // MARK: Copilot billing API

    func testCopilotBillingSumsGrossQuantityAcrossModels() throws {
        XCTAssertEqual(try CopilotBilling.used(from: fixture("copilot-ai-credit-usage")), 600.5, accuracy: 0.0001, "What the plan covered counts too")
        XCTAssertEqual(try CopilotBilling.used(from: Data(#"{"usageItems":[]}"#.utf8)), 0)
        XCTAssertThrowsError(try CopilotBilling.used(from: Data(#"{"timePeriod":{"year":2026,"month":9}}"#.utf8)))
        XCTAssertEqual(try CopilotBilling.login(from: Data(#"{"login":"octocat-placeholder","id":1}"#.utf8)), "octocat-placeholder")
        XCTAssertThrowsError(try CopilotBilling.login(from: Data(#"{"login":""}"#.utf8)))
    }

    func testCopilotBillingPlans() throws {
        let pro = try CopilotBilling.snapshot(used: 600.5, plan: CopilotBilling.plan(named: "Pro"), now: now)
        let credits = try XCTUnwrap(pro.windows.first)
        XCTAssertEqual(credits.id, "ai_credits")
        XCTAssertEqual(credits.title, "AI credits")
        XCTAssertEqual(credits.usedPercent, 600.5 / 1_500 * 100, accuracy: 0.001)
        XCTAssertEqual(credits.amount, QuotaAmount(used: 600.5, limit: 1_500, remaining: 899.5, unit: "credits"))
        XCTAssertTrue(credits.isMetered)
        XCTAssertEqual(pro.planLabel, "Copilot Pro")

        let yearly = try XCTUnwrap(CopilotBilling.snapshot(used: 312, plan: CopilotBilling.plan(named: "Pro, yearly"), now: now).windows.first)
        XCTAssertEqual(yearly.id, "premium_interactions", "Yearly plans from before June 2026 still count premium requests")
        XCTAssertEqual(yearly.amount?.unit, "requests")
        XCTAssertEqual(yearly.usedPercent, 100)
        XCTAssertEqual(yearly.amount?.remaining, 0)

        let free = try XCTUnwrap(CopilotBilling.snapshot(used: 40, plan: CopilotBilling.plan(named: "Free"), now: now).windows.first)
        XCTAssertFalse(free.isMetered, "No published allowance: an amount, not a meter")
        XCTAssertEqual(free.usedPercent, 0)
        XCTAssertNil(free.amount?.limit)
        XCTAssertNil(free.amount?.remaining)

        XCTAssertEqual(CopilotBilling.plan(named: nil).name, "Pro")
        XCTAssertEqual(CopilotBilling.plan(named: "Something new").name, "Pro")
    }

    func testCopilotBillingMonthIsUTC() throws {
        let lastEvening = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30))!
        let december = CopilotBilling.month(containing: lastEvening)
        XCTAssertEqual(december.start, utc(2026, 12, 1))
        XCTAssertEqual(december.end, utc(2027, 1, 1))
        XCTAssertEqual(december.year, 2026)
        XCTAssertEqual(december.month, 12)
        // 00:30 on 1 October in Madrid is still September in UTC, and GitHub bills in UTC.
        let september = CopilotBilling.month(containing: Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 22, minute: 30))!)
        XCTAssertEqual(september.month, 9)
        XCTAssertEqual(september.end, utc(2026, 10, 1))
        let snapshot = try CopilotBilling.snapshot(used: 10, plan: CopilotBilling.plan(named: "Pro"), now: lastEvening)
        XCTAssertEqual(snapshot.resetsAt, utc(2027, 1, 1))
        XCTAssertEqual(snapshot.windows.first?.startsAt, utc(2026, 12, 1))
    }

    func testCopilotWithoutQuotasIsNotEntitled() {
        XCTAssertThrowsError(try CopilotParser.snapshot(from: Data(#"{"copilot_plan":"business","quota_snapshots":{}}"#.utf8), fetchedAt: now)) { error in
            guard case ProviderError.notEntitled = error else { return XCTFail("\(error)") }
        }
    }

    func testGhHostsFileGivesTheActiveUserAndOnlyGithubComTokens() {
        let keyring = """
        github.com:
            git_protocol: https
            users:
                octocat-placeholder:
            user: octocat-placeholder
        """
        XCTAssertEqual(CopilotCredentials.ghHost(keyring)?.user, "octocat-placeholder")
        XCTAssertNil(CopilotCredentials.ghHost(keyring)?.token, "Tokens kept in the Keychain aren't in the file")

        let plain = """
        enterprise.example:
            user: someone
            oauth_token: placeholder-enterprise
        github.com:
            users:
                octocat-placeholder:
                    oauth_token: placeholder-nested
            oauth_token: "placeholder-plain"
            user: octocat-placeholder
        """
        XCTAssertEqual(CopilotCredentials.ghHost(plain)?.token, "placeholder-plain")
        XCTAssertNil(CopilotCredentials.ghHost("enterprise.example:\n    oauth_token: placeholder\n"), "Enterprise tokens go to other hosts")
    }

    func testCopilotAppsFileAndKeyringWrapping() throws {
        let config = try makeFolder()
        let apps = config.appendingPathComponent("github-copilot/apps.json")
        try FileManager.default.createDirectory(at: apps.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"github.com:Iv1.placeholder":{"user":"octocat-placeholder","oauth_token":"placeholder-app"}}"#.utf8).write(to: apps)
        XCTAssertEqual(CopilotCredentials.copilotToken(configDirectory: config), "placeholder-app")
        XCTAssertNotNil(CopilotCredentials.sessionStamp(configDirectory: config))

        XCTAssertEqual(CopilotCredentials.decodeKeyring("go-keyring-base64:" + Data("placeholder".utf8).base64EncodedString()), "placeholder")
        XCTAssertEqual(CopilotCredentials.decodeKeyring("go-keyring-encoded:706c616365686f6c646572"), "placeholder")
        XCTAssertEqual(CopilotCredentials.decodeKeyring("placeholder"), "placeholder")
    }

    // MARK: Devin

    func testDevinRemainingPercentsAndOverage() throws {
        let snapshot = try DevinParser.snapshot(from: fixture("devin-user-status"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "daily"])
        XCTAssertEqual(snapshot.usedPercent, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.resetsAt, now.addingTimeInterval(3 * 86_400), "Unix seconds as int64 strings")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 0)
        XCTAssertEqual(snapshot.planLabel, "Pro")
        XCTAssertEqual(snapshot.extra?.amount.remaining ?? 0, 964.22, accuracy: 0.0001)
    }

    func testDevinMissingPercentBesideAResetIsExhausted() throws {
        let snapshot = try DevinParser.snapshot(from: fixture("devin-user-status-exhausted"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly"])
        XCTAssertEqual(snapshot.usedPercent, 100, "Proto3 JSON leaves out a zero")
        XCTAssertNil(snapshot.extra, "A negative overage balance isn't money left")
        let changed = Data(#"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":"lots","weeklyQuotaResetAtUnix":"1790000000"}}}"#.utf8)
        XCTAssertThrowsError(try DevinParser.snapshot(from: changed, fetchedAt: now), "A percent that isn't a number is a schema change, not an empty quota")
    }

    func testDevinRequestCarriesTheKeyInItsBody() throws {
        let body = try JSONFlex.object(from: DevinParser.requestBody(apiKey: "placeholder"))
        let metadata = try XCTUnwrap(JSONFlex.dictionary(body["metadata"]))
        XCTAssertEqual(JSONFlex.string(metadata["apiKey"]), "placeholder")
        XCTAssertEqual(JSONFlex.string(metadata["ideName"]), "devin")
    }

    func testDevinCredentialsCLIFirstThenAppsWithoutDuplicates() throws {
        let folder = try makeFolder()
        let cli = folder.appendingPathComponent("credentials.toml")
        try Data("""
        # Devin CLI
        windsurf_api_key = "placeholder-cli"
        api_server_url = "http://insecure.example"
        [other]
        windsurf_api_key = "ignored"
        """.utf8).write(to: cli)
        let devin = folder.appendingPathComponent("devin.vscdb")
        let windsurf = folder.appendingPathComponent("windsurf.vscdb")
        try makeStateDatabase(devin, apiKey: "placeholder-cli")
        try makeStateDatabase(windsurf, apiKey: "placeholder-windsurf")

        let credentials = DevinCredentials.all(cliCredentials: cli, appDatabases: [devin, windsurf, folder.appendingPathComponent("missing.vscdb")])
        XCTAssertEqual(credentials.map(\.apiKey), ["placeholder-cli", "placeholder-windsurf"])
        XCTAssertEqual(credentials.first?.server, DevinClient.defaultServer, "A custom server only over https")
    }

    private func makeStateDatabase(_ url: URL, apiKey: String) throws {
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{\"apiKey\":\"\(apiKey)\"}');"]
        try sqlite.run()
        sqlite.waitUntilExit()
    }

    // MARK: Antigravity

    func testAgyUsageKeepsUnknownFractionsUnknown() throws {
        let snapshot = try AntigravityParser.snapshot(from: fixture("agy-usage"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-weekly", "gemini-5h", "3p-5h"], "A bucket with no fraction is left out, not shown as 0% or 100%")
        XCTAssertEqual(snapshot.usedPercent, 14, accuracy: 0.001)
        XCTAssertEqual(snapshot.primaryTitle, "Gemini weekly")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 5, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].usedPercent, 0, accuracy: 0.001)
    }

    func testAntigravityServerSpellings() throws {
        let snapshot = try AntigravityParser.snapshot(from: fixture("antigravity-remote"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-weekly", "3p-weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [50, 25])
    }

    func testAntigravityUnknownBucketsAndFailures() throws {
        let perModel = Data(#"{"groups":[{"name":"Models","buckets":[{"id":"gemini-pro","window":"weekly","remaining_fraction":0.3}]}]}"#.utf8)
        let snapshot = try AntigravityParser.snapshot(from: perModel, fetchedAt: now)
        XCTAssertEqual(snapshot.windows.first?.kind, .weekly)
        XCTAssertEqual(snapshot.usedPercent, 70, accuracy: 0.001)

        let signedOut = Data(#"{"status":"ERROR","error":"You are not logged in."}"#.utf8)
        XCTAssertThrowsError(try AntigravityParser.snapshot(from: signedOut, fetchedAt: now)) { error in
            XCTAssertEqual(error as? ProviderError, .signedOut(Provider.antigravity.signInHint))
        }
    }

    // MARK: Catalog

    @MainActor
    func testEveryProviderHasADescriptorAndAMacClient() {
        let clients = Set(QuotaStore.defaultClients.map(\.provider))
        XCTAssertEqual(clients, Set(Provider.allCases))
        XCTAssertEqual(Provider.allCases.count, 19)
        for provider in Provider.allCases where provider.access == .codingPlanKey {
            XCTAssertNil(provider.login, "\(provider) connects with a key")
            XCTAssertEqual(provider.category, .subscription)
        }
    }
}
