import XCTest
@testable import Tokenroom

/// Calls through `TokenroomHTTP` answered by a stub: what a status means, paging, and what each
/// request carries.
final class RequestTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private func stub(headers: [String: String] = [:], _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        StubURLProtocol.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    /// The error a GET answered with `status` throws, or nil when it succeeds.
    private func failure(_ status: Int, headers: [String: String] = [:]) async -> ProviderError? {
        stub(headers: headers) { _ in (status, Data("{}".utf8)) }
        do {
            _ = try await TokenroomHTTP.get(URL(string: "https://example.com/v1/usage")!, token: "placeholder", provider: .openrouter)
            return nil
        } catch {
            return error as? ProviderError ?? .parse
        }
    }

    private func query(_ request: URLRequest) -> [URLQueryItem] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    // MARK: Statuses

    // MARK: Budgets

    func testASlowCheckIsGivenUpOnAtItsBudget() async {
        let started = Date()
        let slow = await PausingClient(delay: 5).fetchWithinBudget()
        XCTAssertEqual(slow, .failure(.unreachable))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The slow check was cancelled, not awaited")
        let quick = await PausingClient(delay: 0).fetchWithinBudget()
        XCTAssertEqual(quick, .failure(.parse), "An answer inside the budget is kept")
        let widget = await PausingClient(delay: 1).fetchWithinBudget(0.05)
        XCTAssertEqual(widget, .failure(.unreachable), "A caller with less time left wins over the client's own budget")
    }

    func testUnauthorizedMeansExpired() async {
        let unauthorized = await failure(401)
        XCTAssertEqual(unauthorized, .expired(Provider.openrouter.expiredHint))
        let forbidden = await failure(403)
        XCTAssertEqual(forbidden, .expired(Provider.openrouter.expiredHint))
        let fine = await failure(200)
        XCTAssertNil(fine)
    }

    func testRetryAfterInSeconds() async {
        let error = await failure(429, headers: ["Retry-After": "120"])
        guard case .rateLimited(let until?) = error else { return XCTFail("Expected a wait, got \(String(describing: error))") }
        XCTAssertEqual(until.timeIntervalSinceNow, 120, accuracy: 5)
    }

    func testRetryAfterAsAnHTTPDate() async {
        let error = await failure(429, headers: ["Retry-After": "Wed, 21 Oct 2037 07:28:00 GMT"])
        XCTAssertEqual(error, .rateLimited(until: Date(timeIntervalSince1970: 2_139_722_880)))
    }

    func testRateLimitWithoutAUsableRetryAfter() async {
        let missing = await failure(429)
        XCTAssertEqual(missing, .rateLimited(until: nil), "The store then waits its default")
        let garbled = await failure(429, headers: ["Retry-After": "soon"])
        XCTAssertEqual(garbled, .rateLimited(until: nil))
    }

    func testServerErrorsAreUnreachable() async {
        let unavailable = await failure(503)
        XCTAssertEqual(unavailable, .unreachable)
        let broken = await failure(500)
        XCTAssertEqual(broken, .unreachable)
    }

    func testAProvidersOwnCallMapsTheSameWay() async {
        stub(headers: ["Retry-After": "120"]) { _ in (429, Data()) }
        do {
            _ = try await APIKeyClient.snapshot(for: .deepseek, key: "placeholder", region: nil)
            XCTFail("Expected a rate limit")
        } catch {
            guard case ProviderError.rateLimited(let until?) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(until.timeIntervalSinceNow, 120, accuracy: 5)
        }
    }

    // MARK: User-Agent

    func testUserAgentNamesTokenroomAndWhereToLearnMore() {
        let agent = TokenroomIdentity.userAgent
        XCTAssertEqual(agent, "Tokenroom/\(TokenroomIdentity.version) (+\(TokenroomIdentity.repositoryURL.absoluteString))")
        XCTAssertNotNil(agent.range(of: #"^Tokenroom/[0-9A-Za-z.\-]+ \(\+https://[^ ()]+\)$"#, options: .regularExpression), agent)
        XCTAssertEqual(TokenroomHTTP.defaultSession.configuration.httpAdditionalHeaders?["User-Agent"] as? String, agent, "Every provider call sends it")
    }

    // MARK: Organization cost paging

    func testOpenAICostsAddUpEveryPage() async throws {
        let first = fixture("openai-costs-page1")
        let second = fixture("openai-costs-page2")
        stub { request in
            let page = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.first { $0.name == "page" }?.value
            return (200, page == "page_2" ? second : first)
        }
        let snapshot = try await APIKeyClient.orgSnapshot(for: .openaiOrg, key: "placeholder", now: now)
        let spend = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(spend.amount?.used ?? 0, 20, accuracy: 0.0001, "16 on the first page, 4 on the second")
        XCTAssertFalse(spend.isMetered, "Spend without a budget is an amount")
        XCTAssertEqual(spend.resetsAt, Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 10, day: 1)))

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let monthStart = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        XCTAssertEqual(query(StubURLProtocol.requests[0]), [
            URLQueryItem(name: "start_time", value: String(Int(monthStart.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ])
        XCTAssertEqual(query(StubURLProtocol.requests[1]).last, URLQueryItem(name: "page", value: "page_2"))
        XCTAssertEqual(StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer placeholder", "Bearer placeholder"])
    }

    func testCostPagingStopsAfterThreePages() async throws {
        let endless = fixture("openai-costs-page1") // always says there's more
        stub { _ in (200, endless) }
        let snapshot = try await APIKeyClient.orgSnapshot(for: .openaiOrg, key: "placeholder", now: now)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(snapshot.windows.first?.amount?.used ?? 0, 48, accuracy: 0.0001, "What the three pages said")
    }

    func testAnthropicCostReportSendsTheKeyInItsOwnHeader() async throws {
        let report = fixture("anthropic-cost-report")
        stub { _ in (200, report) }
        let snapshot = try await APIKeyClient.orgSnapshot(for: .anthropicOrg, key: "placeholder", now: now)
        XCTAssertEqual(snapshot.windows.first?.amount?.used ?? 0, 13.345, accuracy: 0.0001)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Anthropic's admin key never goes out as a bearer token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(query(request).first { $0.name == "starting_at" }?.value, "2026-09-01T00:00:00Z")
    }

    // MARK: xAI key check

    func testAnXAIKeyThatCanWriteComesWithAWarning() async throws {
        let invoice = fixture("xai-invoice-preview")
        let prepaid = fixture("xai-prepaid-balance")
        let writable = Data(#"{"scopeId":"team-placeholder","acls":["billing:read","api-key:write"]}"#.utf8)
        for (validation, warns) in [(fixture("xai-validation"), false), (writable, true)] {
            stub { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("/management-keys/validation") { return (200, validation) }
                if path.hasSuffix("/teams/team-placeholder/prepaid/balance") { return (200, prepaid) }
                if path.hasSuffix("/teams/team-placeholder/postpaid/invoice/preview") { return (200, invoice) }
                return (404, Data())
            }
            let check = try await APIKeyClient.check(for: .xaiOrg, key: "placeholder", region: nil)
            XCTAssertEqual(check.snapshot.usedPercent, 31.25, accuracy: 0.001)
            XCTAssertEqual(check.snapshot.extra?.amount.remaining ?? 0, 25, accuracy: 0.001)
            XCTAssertEqual(check.warning != nil, warns, warns ? "Write access is worth a warning" : "A billing-only key is fine")
        }

        let balance = fixture("deepseek-balance")
        stub { _ in (200, balance) }
        let deepseek = try await APIKeyClient.check(for: .deepseek, key: "placeholder", region: nil)
        XCTAssertNil(deepseek.warning, "Only xAI keys are checked for write access")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.host, "api.deepseek.com")
    }

    // MARK: Copilot with a fine-grained token

    func testCopilotTokenReadsThisMonthsAICredits() async throws {
        let usage = fixture("copilot-ai-credit-usage")
        let user = Data(#"{"login":"octocat-placeholder","id":1,"type":"User"}"#.utf8)
        stub { request in
            switch request.url?.path {
            case "/user":
                return (200, user)
            case "/users/octocat-placeholder/settings/billing/ai_credit/usage":
                return (200, usage)
            default:
                return (404, Data())
            }
        }
        let snapshot = try await APIKeyClient.copilotSnapshot(key: "placeholder", planName: "Pro+", now: now)
        XCTAssertEqual(snapshot.planLabel, "Copilot Pro+")
        XCTAssertEqual(snapshot.windows.first?.amount?.used ?? 0, 600.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usedPercent, 600.5 / 7_000 * 100, accuracy: 0.001)

        XCTAssertEqual(StubURLProtocol.requests.map(\.url?.path), ["/user", "/users/octocat-placeholder/settings/billing/ai_credit/usage"])
        let usageRequest = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(query(usageRequest), [URLQueryItem(name: "year", value: "2026"), URLQueryItem(name: "month", value: "9")])
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder")
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testAYearlyLegacyPlanReadsPremiumRequests() async throws {
        let usage = fixture("copilot-ai-credit-usage")
        let user = Data(#"{"login":"octocat-placeholder"}"#.utf8)
        stub { request in
            request.url?.path == "/user" ? (200, user) : (200, usage)
        }
        let snapshot = try await APIKeyClient.snapshot(for: .copilot, key: "placeholder", region: "Pro, yearly")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/users/octocat-placeholder/settings/billing/premium_request/usage")
        XCTAssertEqual(snapshot.windows.map(\.id), ["premium_interactions"])
        XCTAssertEqual(snapshot.usedPercent, 100, "600.5 of 300 requests")
    }

    /// The Mac reads Copilot with the GitHub login its tools keep. When that login is missing or
    /// refused and a fine-grained token was pasted, the token answers; an outage stays an outage.
    func testCopilotFallsBackToAPastedTokenOnlyWhenTheLoginCantBeUsed() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let empty = config.appendingPathComponent("empty", isDirectory: true)
        let apps = config.appendingPathComponent("github-copilot/apps.json")
        try FileManager.default.createDirectory(at: apps.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(#"{"github.com:Iv1.placeholder":{"user":"octocat-placeholder","oauth_token":"placeholder-login"}}"#.utf8).write(to: apps)
        let keys = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).")
        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            CopilotCredentials.invalidate()
            try? keys.remove(for: .copilot)
            try? FileManager.default.removeItem(at: config)
        }
        // Only these folders, never this Mac's own GitHub login.
        setenv("XDG_CONFIG_HOME", config.path, 1)
        CopilotCredentials.invalidate()
        let client = CopilotClient(keys: keys)
        let usage = fixture("copilot-ai-credit-usage")
        let user = Data(#"{"login":"octocat-placeholder"}"#.utf8)

        stub { request in
            switch request.url?.path {
            case "/copilot_internal/user":
                return (401, Data())
            case "/user":
                return (200, user)
            default:
                return (200, usage)
            }
        }
        let refused = await client.fetch()
        XCTAssertEqual(refused, .failure(.expired(Provider.copilot.expiredHint)), "No token pasted: the login's error stands")

        try keys.save("placeholder-pasted", for: .copilot, region: "Pro")
        CopilotCredentials.invalidate()
        stub { request in
            switch request.url?.path {
            case "/copilot_internal/user":
                return (401, Data())
            case "/user":
                return (200, user)
            default:
                return (200, usage)
            }
        }
        let snapshot = try await client.fetch().get()
        XCTAssertEqual(snapshot.source, "copilot-token")
        XCTAssertEqual(snapshot.planLabel, "Copilot Pro", "The plan picked with the token")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "token placeholder-login", "The login is tried first")
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-pasted")

        CopilotCredentials.invalidate()
        stub { request in
            request.url?.path == "/copilot_internal/user" ? (503, Data()) : (200, usage)
        }
        let outage = await client.fetch()
        XCTAssertEqual(outage, .failure(.unreachable), "An outage isn't a refused login")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        setenv("XDG_CONFIG_HOME", empty.path, 1)
        CopilotCredentials.invalidate()
        stub { request in
            request.url?.path == "/user" ? (200, user) : (200, usage)
        }
        let withoutLogin = try await client.fetch().get()
        XCTAssertEqual(withoutLogin.source, "copilot-token", "No login on this Mac at all")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path == "/copilot_internal/user" })
    }

    func testCopilotTokensThatCantReadUsageAreNotEntitled() async {
        for status in [403, 404] {
            stub { _ in (status, Data()) }
            do {
                _ = try await APIKeyClient.copilotSnapshot(key: "placeholder", planName: nil, now: now)
                XCTFail("\(status) should fail")
            } catch {
                guard case ProviderError.notEntitled = error else { return XCTFail("\(status): \(error)") }
            }
        }
        stub { _ in (401, Data()) }
        do {
            _ = try await APIKeyClient.copilotSnapshot(key: "placeholder", planName: nil, now: now)
            XCTFail("401 should fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.copilot.expiredHint))
        }
    }
}

/// Answers after `delay`, within a 0.2-second budget of its own.
private struct PausingClient: ProviderClient {
    var delay: TimeInterval
    var provider: Provider { .openrouter }
    var fetchBudget: TimeInterval { 0.2 }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return .failure(.parse)
    }
}
