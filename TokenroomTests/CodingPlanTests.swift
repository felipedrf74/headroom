import XCTest
@testable import Tokenroom

final class CodingPlanTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    // MARK: Z.ai

    func testZaiWeeklyLeadsAndUsesTheExactCounts() throws {
        let snapshot = try ZaiParser.snapshot(from: fixture("zai-quota"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session", "tools-monthly"])
        XCTAssertEqual(snapshot.usedPercent, 25.5, accuracy: 0.001, "(limit − remaining) / limit, not the rounded percentage")
        XCTAssertEqual(snapshot.resetsAt, now.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(snapshot.windows[1].usedPercent, 17, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].resetsAt, now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(snapshot.windows[2].kind, .monthly)
        XCTAssertEqual(snapshot.planLabel, "GLM Coding Pro")
    }

    func testZaiIdleSessionHasNoReset() throws {
        let snapshot = try ZaiParser.snapshot(from: fixture("zai-idle-session"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["session"])
        XCTAssertNil(snapshot.resetsAt, "A 5-hour window can't reset a month out; it hasn't started")
        XCTAssertEqual(snapshot.planLabel, "GLM Coding Lite")
    }

    func testZaiErrorsArriveAsSuccessfulResponses() {
        XCTAssertThrowsError(try ZaiParser.snapshot(from: fixture("zai-no-plan"), fetchedAt: now)) { error in
            guard case ProviderError.notEntitled = error else { return XCTFail("\(error)") }
        }
        let unauthenticated = Data(#"{"code":1001,"msg":"Authentication parameter not received in Header","success":false}"#.utf8)
        XCTAssertThrowsError(try ZaiParser.snapshot(from: unauthenticated, fetchedAt: now)) { error in
            XCTAssertEqual(error as? ProviderError, .expired(Provider.zai.expiredHint))
        }
        let limited = Data(#"{"code":1302,"msg":"slow down","success":false}"#.utf8)
        XCTAssertThrowsError(try ZaiParser.snapshot(from: limited, fetchedAt: now)) { error in
            XCTAssertEqual(error as? ProviderError, .rateLimited(until: nil))
        }
    }

    // MARK: Kimi Code

    func testKimiRatioPoolsAndBooster() throws {
        let snapshot = try KimiCodeParser.snapshot(from: fixture("kimi-usages"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session", "monthly"])
        XCTAssertEqual(snapshot.usedPercent, 12.5, accuracy: 0.001, "String ratios read as numbers")
        XCTAssertEqual(snapshot.resetsAt!.timeIntervalSince1970, now.addingTimeInterval(4 * 86_400).timeIntervalSince1970, accuracy: 1, "Nanosecond fractions parse")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 62.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].usedPercent, 0.56, accuracy: 0.001)
        XCTAssertEqual(snapshot.planLabel, "Allegretto")
        let booster = try XCTUnwrap(snapshot.extra)
        XCTAssertEqual(booster.amount.remaining ?? 0, 12.34, accuracy: 0.0001, "Fixed point: 1e6 per cent")
        XCTAssertEqual(booster.amount.used ?? 0, 7.66, accuracy: 0.0001)
        XCTAssertEqual(booster.amount.limit ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(booster.amount.unit, "usd")
    }

    func testKimiOlderCountsAndALaggingRatio() throws {
        let snapshot = try KimiCodeParser.snapshot(from: fixture("kimi-usages-legacy"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session"])
        XCTAssertEqual(snapshot.usedPercent, 214.0 / 2048 * 100, accuracy: 0.001, "int64 strings")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 69.5, accuracy: 0.001, "A zero ratio beside a count that shows use lags behind")
        XCTAssertEqual(snapshot.windows[1].windowSeconds, 300 * 60)
        XCTAssertNil(snapshot.planLabel)
        XCTAssertNil(snapshot.extra)
    }

    // MARK: MiniMax

    func testMiniMaxTokenPlanReadsRemainingPercents() throws {
        let snapshot = try MiniMaxParser.snapshot(from: fixture("minimax-token-plan"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session"], "A lane outside the plan is hidden")
        XCTAssertEqual(snapshot.usedPercent, 29, accuracy: 0.001)
        XCTAssertEqual(snapshot.resetsAt, now.addingTimeInterval(5 * 86_400))
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 7 * 86_400)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 4, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].resetsAt, now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(snapshot.planLabel, "Token Plan Plus")
    }

    func testMiniMaxCodingPlanCountsAreWhatsLeft() throws {
        let snapshot = try MiniMaxParser.snapshot(from: fixture("minimax-coding-plan"), legacy: true, fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.title), ["MiniMax-M2"])
        XCTAssertEqual(snapshot.usedPercent, 75, accuracy: 0.001, "250 of 1,000 left")
        XCTAssertEqual(snapshot.resetsAt, now.addingTimeInterval(240), "A past end time falls back to remains_time")
        XCTAssertEqual(snapshot.planLabel, "Max")
        XCTAssertThrowsError(try MiniMaxParser.snapshot(from: fixture("minimax-invalid-key"), fetchedAt: now)) { error in
            XCTAssertEqual(error as? ProviderError, .expired(Provider.minimax.expiredHint))
        }
    }

    // MARK: OpenCode Go

    func testOpenCodeGoPercentsAreUsedOutOfAHundred() throws {
        let snapshot = try OpenCodeGoParser.snapshot(from: fixture("opencode-go-usage"), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session", "monthly"])
        XCTAssertEqual(snapshot.usedPercent, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 0.5, accuracy: 0.001, "0.5 means half a percent, not half")
        XCTAssertEqual(snapshot.windows[2].usedPercent, 100, "A rate-limited window is spent")
        XCTAssertEqual(snapshot.planLabel, "Go")
        XCTAssertThrowsError(try OpenCodeGoParser.snapshot(from: Data(#"{"usage":{}}"#.utf8), fetchedAt: now))
    }

    func testOpenCodeGoEntitlementError() {
        let body = Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
        guard case .notEntitled = OpenCodeGoParser.error(status: 403, body: body) else { return XCTFail("Expected notEntitled") }
        XCTAssertNil(OpenCodeGoParser.error(status: 401, body: body))
        XCTAssertNil(OpenCodeGoParser.error(status: 403, body: Data(#"{"error":{"type":"AuthError"}}"#.utf8)))
    }

    // MARK: Keys found on this Mac

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func testClaudeSettingsHostPicksTheRegion() throws {
        let claude = try makeFolder()
        try writeJSON(["env": ["ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic", "ANTHROPIC_AUTH_TOKEN": "placeholder-glm"]], to: claude.appendingPathComponent("settings.json"))
        let empty = try makeFolder()
        let found = try XCTUnwrap(LocalKeys.find(.zai, claudeDirectory: claude, kimiHome: empty, opencodeData: empty))
        XCTAssertEqual(try found.credential.get(), APIKeyCredential(key: "placeholder-glm", region: "China", source: "claude-settings"))
        XCTAssertNil(LocalKeys.find(.minimax, claudeDirectory: claude, kimiHome: empty, opencodeData: empty), "A Z.ai key never goes to MiniMax")
    }

    func testKimiCLILoginIsUsedOnlyWhileValid() throws {
        let home = try makeFolder()
        let empty = try makeFolder()
        let file = home.appendingPathComponent("credentials/kimi-code.json")
        try writeJSON(["access_token": "placeholder-access", "refresh_token": "placeholder-refresh", "expires_at": now.addingTimeInterval(3600).timeIntervalSince1970], to: file)
        let found = try XCTUnwrap(LocalKeys.find(.kimiCode, claudeDirectory: empty, kimiHome: home, opencodeData: empty, now: now))
        XCTAssertEqual(try found.credential.get(), APIKeyCredential(key: "placeholder-access", region: "China", source: "kimi-cli"))
        XCTAssertEqual(found.file, file)

        let expired = try XCTUnwrap(LocalKeys.find(.kimiCode, claudeDirectory: empty, kimiHome: home, opencodeData: empty, now: now.addingTimeInterval(3600 - 30)))
        XCTAssertThrowsError(try expired.credential.get()) { error in
            XCTAssertEqual(error as? ProviderError, .expired(Provider.kimiCode.expiredHint), "Within a minute of expiry the CLI must refresh it, not Tokenroom")
        }
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("placeholder-refresh"), "The CLI's file is never rewritten")
    }

    func testKimiFallsBackToClaudeSettingsAndOpenCodeReadsAuthJSON() throws {
        let claude = try makeFolder()
        try writeJSON(["env": ["ANTHROPIC_BASE_URL": "https://api.kimi.ai/coding/", "ANTHROPIC_API_KEY": "placeholder-kimi"]], to: claude.appendingPathComponent("settings.json"))
        let data = try makeFolder()
        try writeJSON(["opencode-go": ["type": "api", "key": "placeholder-go"]], to: data.appendingPathComponent("auth.json"))
        let empty = try makeFolder()

        let kimi = try XCTUnwrap(LocalKeys.find(.kimiCode, claudeDirectory: claude, kimiHome: empty, opencodeData: data))
        XCTAssertEqual(try kimi.credential.get(), APIKeyCredential(key: "placeholder-kimi", region: "Global", source: "claude-settings"))
        let go = try XCTUnwrap(LocalKeys.find(.opencodeGo, claudeDirectory: claude, kimiHome: empty, opencodeData: data))
        XCTAssertEqual(try go.credential.get(), APIKeyCredential(key: "placeholder-go", source: "opencode"))
    }

    // MARK: Requests

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    func testAChinaKeyOnlyGoesToTheChinaHost() async throws {
        let quota = fixture("zai-quota")
        stub { _ in (200, quota) }
        _ = try await APIKeyClient.snapshot(for: .zai, key: "placeholder", region: "China")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["open.bigmodel.cn"])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder")
    }

    func testMiniMaxFallsBackToTheCodingPlanEndpoint() async throws {
        let legacy = fixture("minimax-coding-plan")
        stub { request in
            request.url?.path.contains("token_plan") == true ? (404, Data()) : (200, legacy)
        }
        let snapshot = try await APIKeyClient.snapshot(for: .minimax, key: "placeholder", region: nil)
        XCTAssertEqual(snapshot.usedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"])
        XCTAssertEqual(Set(StubURLProtocol.requests.compactMap { $0.url?.host }), ["api.minimax.io"])
    }

    func testOpenCodeGoWithoutASubscriptionIsNotAnExpiredKey() async {
        stub { _ in (403, Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)) }
        do {
            _ = try await APIKeyClient.snapshot(for: .opencodeGo, key: "placeholder", region: nil)
            XCTFail("Expected an error")
        } catch {
            guard case ProviderError.notEntitled = error else { return XCTFail("\(error)") }
        }
    }

    func testAPastedKeyWinsOverOneFoundOnTheMac() async throws {
        let usage = fixture("opencode-go-usage")
        stub { _ in (200, usage) }
        let keys = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).")
        defer { try? keys.remove(for: .opencodeGo) }
        var client = APIKeyClient(provider: .opencodeGo, keys: keys)
        client.localCredential = { _ in APIKeyCredential(key: "placeholder-local", source: "opencode") }

        let local = try await client.fetch().get()
        XCTAssertEqual(local.source, "opencode")
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-local")

        try keys.save("placeholder-pasted", for: .opencodeGo, region: nil)
        let pasted = try await client.fetch().get()
        XCTAssertNil(pasted.source)
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-pasted")
    }

    func testAnExpiredLocalLoginReportsExpired() async {
        var client = APIKeyClient(provider: .kimiCode, keys: APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString)."))
        client.localCredential = { _ in throw ProviderError.expired(Provider.kimiCode.expiredHint) }
        let result = await client.fetch()
        XCTAssertEqual(result, .failure(.expired(Provider.kimiCode.expiredHint)))
    }
}

/// Answers every request with `handler` and records it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
