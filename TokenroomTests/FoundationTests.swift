import XCTest
@testable import Tokenroom

final class FoundationTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        suites = []
        folders = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func snapshot(_ provider: Provider, used: Double = 40, fetchedAt: Date = .now, resetsAt: Date? = nil) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            usedPercent: used,
            resetsAt: resetsAt ?? fetchedAt.addingTimeInterval(86_400),
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: nil)]
        )
    }

    // MARK: Settings

    func testDisabledGrokBotStaysDisabledAcrossLaunches() {
        let defaults = makeDefaults()
        defaults.set(["claude", "cursor", "grok", "openai"], forKey: "enabledProviders")

        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.isEnabled(.grokBot))
        XCTAssertTrue(first.isEnabled(.claude))

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled(.grokBot))
        XCTAssertEqual(defaults.integer(forKey: "settingsVersion"), 2)
    }

    func testEmptySavedListStaysEmpty() {
        let defaults = makeDefaults()
        defaults.set([String](), forKey: "enabledProviders")
        XCTAssertTrue(AppSettings(defaults: defaults).enabled.isEmpty)
        XCTAssertTrue(AppSettings(defaults: defaults).enabled.isEmpty)
    }

    func testFreshInstallEnablesDefaultProviders() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(settings.enabled, Provider.legacy)
    }

    func testProviderUnknownToSavedSettingsGetsDefaultRule() {
        let defaults = makeDefaults()
        defaults.set(2, forKey: "settingsVersion")
        defaults.set(["claude"], forKey: "enabledProviders")
        defaults.set(["claude", "grok", "grokBot", "openai"], forKey: "knownProviders")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(.cursor), "Cursor was never seen, and legacy providers start enabled")
        XCTAssertFalse(settings.isEnabled(.grok), "Known and saved as off")
    }

    // MARK: Blocking I/O

    func testProcessOutputLargerThanPipeBufferDoesNotDeadlock() {
        let output = BlockingIO.runProcess(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\000' a"],
            timeout: 10
        )
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.stdout.count, 300_000)
    }

    func testProcessIsKilledAfterTimeout() {
        let start = Date()
        let output = BlockingIO.runProcess(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3)
        XCTAssertTrue(output.timedOut)
        XCTAssertFalse(output.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testBlockingRunReturnsValue() async throws {
        let value = try await BlockingIO.run { 21 * 2 }
        XCTAssertEqual(value, 42)
    }

    // MARK: HTTP

    func testStatusMapping() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(TokenroomHTTP.mapStatus(200, provider: .claude))
        XCTAssertEqual(TokenroomHTTP.mapStatus(401, provider: .claude), .expired(Provider.claude.expiredHint))
        XCTAssertEqual(TokenroomHTTP.mapStatus(403, provider: .cursor), .expired(Provider.cursor.expiredHint))
        XCTAssertEqual(
            TokenroomHTTP.mapStatus(429, retryAfter: "120", provider: .claude, now: now),
            .rateLimited(until: now.addingTimeInterval(120))
        )
        XCTAssertEqual(TokenroomHTTP.mapStatus(429, provider: .claude, now: now), .rateLimited(until: nil))
        XCTAssertEqual(TokenroomHTTP.mapStatus(503, provider: .openai), .unreachable)
    }

    func testRetryAfterHTTPDate() {
        let date = TokenroomHTTP.retryDate("Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_445_412_480))
        XCTAssertNil(TokenroomHTTP.retryDate("soon"))
    }

    func testRetryIsClampedBetweenAMinuteAndSixHours() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaStore.clampedRetry(nil, now: now), now.addingTimeInterval(15 * 60))
        XCTAssertEqual(QuotaStore.clampedRetry(now.addingTimeInterval(5), now: now), now.addingTimeInterval(60))
        XCTAssertEqual(QuotaStore.clampedRetry(now.addingTimeInterval(36_000), now: now), now.addingTimeInterval(6 * 3600))
    }

    // MARK: Snapshot cache

    func testCacheKeepsGoodEntriesWhenOthersAreBad() throws {
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(.claude)))
        let payload: [String: Any] = [
            "claude": good,
            "cursor": ["bogus": true],
            "someFutureProvider": good,
        ]
        let decoded = SnapshotCache.decode(try JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(Array(decoded.keys), [.claude])
    }

    func testUnknownWindowKindReadsAsPool() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(.openai))) as! [String: Any]
        var window = (object["windows"] as! [[String: Any]])[0]
        window["kind"] = "someFutureKind"
        object["windows"] = [window]
        let data = try JSONSerialization.data(withJSONObject: ["openai": object])
        XCTAssertEqual(SnapshotCache.decode(data)[.openai]?.windows.first?.kind, .pool)
    }

    func testLegacyGrokBotPlanWindowBecomesLabel() throws {
        var legacy = snapshot(.grokBot)
        legacy.windows.append(QuotaWindow(id: "plan", kind: .pool, title: "SuperGrok Heavy", usedPercent: 40, resetsAt: nil))
        let data = try JSONEncoder().encode(["grokBot": legacy])
        let migrated = try XCTUnwrap(SnapshotCache.decode(data)[.grokBot])
        XCTAssertEqual(migrated.planLabel, "SuperGrok Heavy")
        XCTAssertEqual(migrated.windows.map(\.id), ["weekly"])
    }

    func testCacheRoundTrip() throws {
        let cache = SnapshotCache(directory: try makeFolder())
        let saved = [Provider.claude: snapshot(.claude), .cursor: snapshot(.cursor, used: 12)]
        cache.save(saved)
        XCTAssertEqual(cache.load(), saved)
    }

    // MARK: Headroom migration

    func testMigrationImportsHeadroomSettingsAndCacheOnce() throws {
        let defaults = makeDefaults()
        let legacy = makeDefaults()
        legacy.set(["claude", "openai"], forKey: "enabledProviders")
        legacy.set(15, forKey: "refreshMinutes")
        legacy.set("percents", forKey: "menuStyle")

        let support = try makeFolder()
        let legacyFolder = support.appendingPathComponent("Headroom", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacyFolder.appendingPathComponent("snapshots.json"))

        LegacyMigration.runIfNeeded(defaults: defaults, legacyDefaults: legacy, supportDirectory: support)
        XCTAssertEqual(defaults.array(forKey: "enabledProviders") as? [String], ["claude", "openai"])
        XCTAssertEqual(defaults.integer(forKey: "refreshMinutes"), 15)
        XCTAssertEqual(defaults.string(forKey: "menuStyle"), "percents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Tokenroom/snapshots.json").path))

        defaults.set(30, forKey: "refreshMinutes")
        LegacyMigration.runIfNeeded(defaults: defaults, legacyDefaults: legacy, supportDirectory: support)
        XCTAssertEqual(defaults.integer(forKey: "refreshMinutes"), 30, "Runs once; never overwrites later changes")
    }

    func testMigrationLeavesExistingTokenroomSettingsAlone() throws {
        let defaults = makeDefaults()
        defaults.set(["cursor"], forKey: "enabledProviders")
        let legacy = makeDefaults()
        legacy.set(["claude"], forKey: "enabledProviders")
        LegacyMigration.runIfNeeded(defaults: defaults, legacyDefaults: legacy, supportDirectory: try makeFolder())
        XCTAssertEqual(defaults.array(forKey: "enabledProviders") as? [String], ["cursor"])
    }

    // MARK: Read-only sessions

    func testGrokTokenIsNeverRefreshed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let live = CredentialReaders.GrokAuth(accessToken: "tok", expiresAt: now.addingTimeInterval(3600), userID: nil)
        XCTAssertEqual(try CredentialReaders.usableGrokToken(live, now: now), "tok")
        let noExpiry = CredentialReaders.GrokAuth(accessToken: "tok", expiresAt: nil, userID: nil)
        XCTAssertEqual(try CredentialReaders.usableGrokToken(noExpiry, now: now), "tok")
        let expired = CredentialReaders.GrokAuth(accessToken: "tok", expiresAt: now.addingTimeInterval(-5), userID: nil)
        XCTAssertThrowsError(try CredentialReaders.usableGrokToken(expired, now: now)) { error in
            XCTAssertEqual(error as? ProviderError, .expired(Provider.grok.expiredHint))
        }
    }

    func testClaudeUserAgentFollowsInstalledCLI() {
        let cli = URL(fileURLWithPath: "/nonexistent/.local/share/claude/versions/2.1.280")
        XCTAssertEqual(CredentialReaders.claudeUserAgent(forCLI: cli), "claude-cli/2.1.280 (external, cli)")
        let desktop = URL(fileURLWithPath: "/nonexistent/claude-code/2.1.281/claude.app/Contents/MacOS/claude")
        XCTAssertEqual(CredentialReaders.claudeVersion(of: desktop), "2.1.281")
        XCTAssertNil(CredentialReaders.claudeVersion(of: URL(fileURLWithPath: "/nonexistent/bin/claude")))
        XCTAssertEqual(CredentialReaders.claudeUserAgent(forCLI: nil), "claude-cli (external, cli)")
    }

    // MARK: Store

    @MainActor
    func testExpiredSessionKeepsLastReadingFaded() async throws {
        let client = ScriptedClient(provider: .claude, results: [
            .success(snapshot(.claude, used: 63)),
            .failure(.expired(Provider.claude.expiredHint)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)

        guard case .expired(_, let cached?) = store.statuses[.claude] else {
            return XCTFail("Expected an expired status with the last reading, got \(String(describing: store.statuses[.claude]))")
        }
        XCTAssertEqual(cached.usedPercent, 63)
        let meter = try XCTUnwrap(store.menuMeters.first { $0.provider == .claude })
        XCTAssertTrue(meter.isStale)
        XCTAssertEqual(meter.valueText, "63")
    }

    @MainActor
    func testRateLimitedProviderWaitsForRetryAfter() async throws {
        let client = ScriptedClient(provider: .claude, results: [
            .failure(.rateLimited(until: Date().addingTimeInterval(600))),
            .success(snapshot(.claude)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        guard case .rateLimited = store.statuses[.claude] else {
            return XCTFail("Expected rate limited, got \(String(describing: store.statuses[.claude]))")
        }
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "No call before Retry-After")
    }

    @MainActor
    func testUnchangedUsageStillUpdatesCheckedAt() async throws {
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        let reset = Date(timeIntervalSince1970: 90_000)
        let client = ScriptedClient(provider: .claude, results: [
            .success(snapshot(.claude, fetchedAt: first, resetsAt: reset)),
            .success(snapshot(.claude, fetchedAt: second, resetsAt: reset)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(store.checkedAt[.claude], second)
        XCTAssertEqual(store.statuses[.claude]?.snapshot?.fetchedAt, first, "Same usage keeps the first reading")
    }
}

/// Returns queued results in order, then repeats the last one.
private final class ScriptedClient: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var results: [Result<QuotaSnapshot, ProviderError>]
    private var count = 0

    init(provider: Provider, results: [Result<QuotaSnapshot, ProviderError>]) {
        self.provider = provider
        self.results = results
    }

    var calls: Int {
        lock.withLock { count }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}
