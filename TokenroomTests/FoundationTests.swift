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

    /// Named by the class and a count rather than at random: macOS keeps an empty preferences
    /// file for every name, so runs reuse a few instead of leaving one behind per test.
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

    func testChoicesForProvidersFromANewerVersionAreKept() {
        let defaults = makeDefaults()
        defaults.set(2, forKey: "settingsVersion")
        defaults.set(["claude", "futureBot"], forKey: "enabledProviders")
        defaults.set(Provider.allCases.map(\.rawValue) + ["futureBot"], forKey: "knownProviders")
        defaults.set(["futureBot"], forKey: "menuBarHidden")
        defaults.set(["futureBot": 20.0, "deepseek": 10.0], forKey: "budgets")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.enabled, [.claude])
        settings.setEnabled(.cursor, true)
        settings.setBudget(nil, for: .deepseek)
        XCTAssertEqual(defaults.array(forKey: "enabledProviders") as? [String], ["claude", "cursor", "futureBot"], "Going back to the newer version finds its provider still on")
        XCTAssertTrue((defaults.array(forKey: "knownProviders") as? [String] ?? []).contains("futureBot"), "…and known, so it isn't treated as new")
        XCTAssertEqual(defaults.array(forKey: "menuBarHidden") as? [String], ["futureBot"])
        XCTAssertEqual(defaults.dictionary(forKey: "budgets") as? [String: Double], ["futureBot": 20.0])
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
        let value = await BlockingIO.run { 21 * 2 }
        XCTAssertEqual(value, 42)
        let thrown = try await BlockingIO.run { () throws -> Int in 21 * 2 }
        XCTAssertEqual(thrown, 42, "The throwing overload too")
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

    func testAReadingIsKeptOnlyWhileNothingButItsTimeChanges() {
        let earlier = snapshot(.openai, fetchedAt: Date(timeIntervalSince1970: 1_000), resetsAt: Date(timeIntervalSince1970: 90_000))
        var later = earlier
        later.fetchedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(QuotaStore.usageEqual(earlier, later), "Checking again isn't a change")
        var banked = later
        banked.banked = BankedResets(available: 1, expiries: [Date(timeIntervalSince1970: 500_000)])
        XCTAssertFalse(QuotaStore.usageEqual(earlier, banked), "A newly banked reset is")
        var credits = later
        credits.extra = ExtraUsage(title: "Credits", amount: QuotaAmount(remaining: 18.4, unit: "usd"))
        XCTAssertFalse(QuotaStore.usageEqual(earlier, credits), "So are credits or extra usage")
        var bridged = later
        bridged.source = "bridge"
        XCTAssertTrue(QuotaStore.usageEqual(earlier, bridged), "The same values from another source aren't, so sources don't take turns")
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
        let client = ScriptedClient(provider: .cursor, results: [
            .success(snapshot(.cursor, used: 63)),
            .failure(.expired(Provider.cursor.expiredHint)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)

        guard case .expired(_, let cached?) = store.statuses[.cursor] else {
            return XCTFail("Expected an expired status with the last reading, got \(String(describing: store.statuses[.cursor]))")
        }
        XCTAssertEqual(cached.usedPercent, 63)
        let meter = try XCTUnwrap(store.menuMeters.first { $0.provider == .cursor })
        XCTAssertTrue(meter.isStale)
        XCTAssertEqual(meter.valueText, "63")
    }

    @MainActor
    func testClaudeIsNotAskedTwiceWithinItsMinimumInterval() async throws {
        let client = ScriptedClient(provider: .claude, results: [.success(snapshot(.claude))])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "Claude's usage endpoint allows about one call every few minutes")
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
        // Cursor has no minimum interval, so both refreshes call it.
        let client = ScriptedClient(provider: .cursor, results: [
            .success(snapshot(.cursor, fetchedAt: first, resetsAt: reset)),
            .success(snapshot(.cursor, fetchedAt: second, resetsAt: reset)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(store.checkedAt[.cursor], second)
        XCTAssertEqual(store.statuses[.cursor]?.snapshot?.fetchedAt, first, "Same usage keeps the first reading")
        XCTAssertEqual(store.lastChanged(.cursor), first)
    }

    @MainActor
    func testAFailedCallStillCountsTowardClaudesSpacing() async throws {
        let client = ScriptedClient(provider: .claude, results: [
            .failure(.unreachable),
            .success(snapshot(.claude)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "Spacing counts from the last call, so an outage doesn't bring the next one closer")
    }

    @MainActor
    func testAMissingLoginDoesNotSpaceOutTheNextCheck() async throws {
        let client = ScriptedClient(provider: .claude, results: [
            .failure(.signedOut(Provider.claude.signInHint)),
            .success(snapshot(.claude)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 2, "Nothing was called without a login: signing in is met with a check")
        guard case .live = store.statuses[.claude] else {
            return XCTFail("Expected live, got \(String(describing: store.statuses[.claude]))")
        }

        // A refused session may have reached the server, so it keeps the spacing.
        let refused = ScriptedClient(provider: .claude, results: [.failure(.expired(Provider.claude.expiredHint)), .success(snapshot(.claude))])
        let other = QuotaStore(settings: AppSettings(defaults: makeDefaults()), clients: [refused], cache: SnapshotCache(directory: try makeFolder()))
        await other.refresh(force: true)
        await other.refresh(force: true)
        XCTAssertEqual(refused.calls, 1)
    }

    @MainActor
    func testChecksThatAllFailedToConnectDontSpaceOutTheNext() async throws {
        let defaults = makeDefaults()
        defaults.set(["claude", "antigravity"], forKey: "enabledProviders")
        let claude = ScriptedClient(provider: .claude, results: [.failure(.unreachable), .success(snapshot(.claude))])
        let agy = ScriptedClient(provider: .antigravity, results: [.failure(.unreachable), .success(snapshot(.antigravity))])
        let store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [claude, agy], cache: SnapshotCache(directory: try makeFolder()))
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(claude.calls, 2, "Nothing answered at all: the Mac was offline, so no call counts")
        XCTAssertEqual(agy.calls, 2)
    }

    @MainActor
    func testSigningInIsCheckedAtOnce() async throws {
        let client = ScriptedClient(provider: .claude, results: [
            .failure(.unreachable),
            .success(snapshot(.claude)),
        ])
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.credentialsChanged(for: .claude)
        XCTAssertEqual(client.calls, 2, "New credentials aren't held to the old ones' spacing")
        XCTAssertEqual(client.credentialChanges, 1, "The client forgets what it kept from the old login")
    }

    func testSigningInClearsClaudesOwnWait() {
        let now = Date()
        let client = ClaudeClient()
        client.state.recordDirect(snapshot(.claude, fetchedAt: now))
        client.state.block(until: now.addingTimeInterval(3600))
        client.credentialsChanged()
        XCTAssertNil(client.state.blockedUntil, "Claude's Retry-After came from the old login")
        XCTAssertNil(client.state.lastDirect, "So did its last direct read")
    }

    @MainActor
    func testARateLimitedProviderStillTakesLocalReadings() async throws {
        let local = snapshot(.claude, used: 55)
        let client = ScriptedClient(provider: .claude, results: [.failure(.rateLimited(until: Date().addingTimeInterval(3600)))], between: local)
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "No call before Retry-After")
        XCTAssertEqual(client.betweenCalls.count, 1, "Claude's status line still counts meanwhile")
        XCTAssertEqual(store.statuses[.claude]?.snapshot?.usedPercent, 55)
    }

    @MainActor
    func testForcedRefreshesDuringACheckShareOneMore() async throws {
        let client = GatedClient(provider: .cursor)
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        let first = Task { await store.refresh(force: true) }
        while client.calls == 0 {
            await Task.yield()
        }
        let waiting = (0..<3).map { _ in Task { await store.refresh(force: true) } }
        for _ in 0..<20 {
            await Task.yield()
        }
        client.release()
        await first.value
        for task in waiting {
            await task.value
        }
        XCTAssertEqual(client.calls, 2, "Three refreshes asked for during a check share one more, not three overlapping ones")
    }

    func testTheSameResetWithinAMinuteIsNoChange() {
        let reset = Date(timeIntervalSince1970: 1_790_400_000.123_456)
        var direct = snapshot(.claude, used: 40, resetsAt: reset)
        direct.windows[0].resetsAt = reset
        var bridge = direct
        bridge.resetsAt = reset.addingTimeInterval(-0.123_456)
        bridge.windows[0].resetsAt = reset.addingTimeInterval(-0.123_456)
        bridge.source = "bridge"
        XCTAssertTrue(QuotaStore.usageEqual(direct, bridge), "Microseconds from one source, whole seconds from the other")
        bridge.windows[0].resetsAt = reset.addingTimeInterval(3600)
        XCTAssertFalse(QuotaStore.usageEqual(direct, bridge))
    }

    @MainActor
    func testARestingProviderStillTakesACheapLocalReading() async throws {
        let now = Date()
        let direct = snapshot(.claude, used: 40, fetchedAt: now.addingTimeInterval(-60))
        let local = snapshot(.claude, used: 55, fetchedAt: now)
        let client = ScriptedClient(provider: .claude, results: [.success(direct)], between: local)
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [client],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        XCTAssertEqual(client.betweenCalls, [], "Due providers are called directly")
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "Claude's endpoint rests between calls")
        XCTAssertEqual(client.betweenCalls, [direct], "The local reading builds on the last one")
        XCTAssertEqual(store.statuses[.claude]?.snapshot?.usedPercent, 55)
        XCTAssertEqual(store.checkedAt[.claude], now)
    }

    @MainActor
    func testCheckTimesSurviveARelaunch() async throws {
        let folder = try makeFolder()
        let defaults = makeDefaults()
        let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [ScriptedClient(provider: .cursor, results: [.success(snapshot(.cursor, fetchedAt: fetchedAt))])],
            cache: SnapshotCache(directory: folder)
        )
        await store.refresh(force: true)
        let relaunched = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: folder))
        XCTAssertEqual(relaunched.checkedAt[.cursor], fetchedAt)
        XCTAssertEqual(relaunched.lastChecked(.cursor), fetchedAt)
    }

    @MainActor
    func testRelayedWindowsCarryTheMacsPaceAndCategory() async throws {
        let now = Date()
        let reset = now.addingTimeInterval(3.5 * 86_400)
        let reading = QuotaSnapshot(
            provider: .claude, usedPercent: 70, resetsAt: reset, fetchedAt: now, primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 70, resetsAt: reset, windowSeconds: 7 * 86_400),
                QuotaWindow(id: "credits", kind: .pool, title: "Credits", usedPercent: 0, resetsAt: nil, amount: QuotaAmount(remaining: 5, unit: "usd"), metered: false),
            ]
        )
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults()),
            clients: [ScriptedClient(provider: .claude, results: [.success(reading)])],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        let relayed = try XCTUnwrap(store.relayEnvelope(at: now).providers.first { $0.id == "claude" })
        XCTAssertEqual(relayed.category, "subscription")
        let weekly = try XCTUnwrap(relayed.windows.first { $0.id == "weekly" })
        // 70% in half a week: the last 30% takes a day and a half.
        let runsOut = try XCTUnwrap(weekly.pace?.runsOutAt)
        XCTAssertEqual(runsOut.timeIntervalSince(now), 1.5 * 86_400, accuracy: 60)
        XCTAssertNil(relayed.windows.first { $0.id == "credits" }?.pace, "A balance has no pace")
        XCTAssertEqual(store.windowPaces(for: .claude, now: now)["weekly"]?.verdict, .ahead)
        XCTAssertNil(store.windowPaces(for: .claude, now: now)["credits"])

        let weeks = store.weeks(for: .claude)
        XCTAssertEqual(Set(weeks.keys), ["weekly", "credits"], "Keyed by window, without the provider")
        XCTAssertEqual(weeks["credits"]?.amountPoints.map(\.remaining), [5], "Dollar balances keep their amount")
        XCTAssertEqual(weeks["weekly"]?.points.map(\.used), [70])
        XCTAssertNil(weeks["weekly"]?.amounts)
    }

    @MainActor
    func testNewsIsOnlyFetchedOnceTurnedOn() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (404, Data()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        let defaults = makeDefaults()
        let news = NewsStore(defaults: defaults, directory: try makeFolder())
        // Feeds are fetched in parallel; the model list alone keeps the stub's record simple.
        news.followedSources = []
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [],
            cache: SnapshotCache(directory: try makeFolder()),
            news: news
        )
        await store.refreshNews(force: true)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "News is opt-in: nothing goes out")

        store.settings.newsEnabled = true
        await store.refreshNews(force: true)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["openrouter.ai"], "OpenRouter's public model list, with no key")
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    @MainActor
    func testBudgetCurrencyFollowsTheBalance() async throws {
        let defaults = makeDefaults()
        defaults.set(["moonshot", "deepseek"], forKey: "enabledProviders")
        let china = try MoonshotParser.snapshot(from: Data(#"{"data":{"available_balance":80}}"#.utf8), region: "China")
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [ScriptedClient(provider: .moonshot, results: [.success(china)])],
            cache: SnapshotCache(directory: try makeFolder())
        )
        XCTAssertEqual(store.budgetCurrency(for: .moonshot), "USD", "Dollars until a reading says otherwise")
        await store.refresh(force: true)
        XCTAssertEqual(store.budgetCurrency(for: .moonshot), "CNY")
        XCTAssertEqual(store.budgetCurrency(for: .deepseek), "USD")
    }

    @MainActor
    func testBankedResetsAddUpAcrossConnectedProviders() async throws {
        let defaults = makeDefaults()
        defaults.set(["openai", "claude", "cursor"], forKey: "enabledProviders")
        var codex = snapshot(.openai)
        codex.banked = BankedResets(available: 2)
        var claude = snapshot(.claude)
        claude.banked = BankedResets(available: 0)
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [
                ScriptedClient(provider: .openai, results: [.success(codex)]),
                ScriptedClient(provider: .claude, results: [.success(claude)]),
                ScriptedClient(provider: .cursor, results: [.failure(.signedOut(Provider.cursor.signInHint))]),
            ],
            cache: SnapshotCache(directory: try makeFolder())
        )
        await store.refresh(force: true)
        XCTAssertEqual(store.bankedResets.count, 2)
        XCTAssertEqual(store.bankedResets.providers, [.openai])
    }

    @MainActor
    func testAlertChoicesMadeOnTheMacAreStampedAndKept() throws {
        let defaults = makeDefaults()
        let store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: try makeFolder()))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        store.updateAlertPreferences({ $0.lowBalance = false }, now: now)
        XCTAssertFalse(store.settings.alertPreferences.lowBalance)
        XCTAssertEqual(store.settings.alertPreferences.updatedAt, now, "Stamped so the newer copy wins in iCloud")
        XCTAssertEqual(AppSettings(defaults: defaults).alertPreferences, store.settings.alertPreferences, "Saved")

        store.updateAlertPreferences({ $0.lowBalance = false }, now: now.addingTimeInterval(60))
        XCTAssertEqual(store.settings.alertPreferences.updatedAt, now, "No change, no new stamp")
    }

    @MainActor
    func testWithoutICloudTheMacsOwnAlertChoicesApply() async throws {
        let settings = AppSettings(defaults: makeDefaults())
        settings.alertPreferences.thresholds = [95]
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: try makeFolder()))
        let preferences = await store.currentAlertPreferences()
        XCTAssertEqual(preferences.thresholds, [95])
    }

    // MARK: Settings: new providers

    func testOrganizationKeysNeverTurnOnByThemselves() {
        let settings = AppSettings(defaults: makeDefaults(), detectsSession: { _ in true })
        for provider in Provider.allCases {
            XCTAssertEqual(settings.isEnabled(provider), provider.category != .orgSpend, "\(provider)")
        }
    }

    func testDetectionOnlyTurnsOnProvidersNewToThisInstall() {
        let defaults = makeDefaults()
        let unseen: [Provider] = [.copilot, .devin, .xaiOrg]
        defaults.set(2, forKey: "settingsVersion")
        defaults.set(["claude"], forKey: "enabledProviders")
        defaults.set(Provider.allCases.filter { !unseen.contains($0) }.map(\.rawValue), forKey: "knownProviders")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.newlyKnown, unseen)
        XCTAssertEqual(settings.enabled, [.claude], "Nothing turns on before detection")

        settings.enableDetected([.copilot, .xaiOrg, .cursor])
        XCTAssertEqual(settings.enabled, [.claude, .copilot], "Cursor was known and off; xAI is an organization key; Devin wasn't found")
        XCTAssertTrue(settings.newlyKnown.isEmpty)
        settings.enableDetected([.devin])
        XCTAssertFalse(settings.isEnabled(.devin), "Only once per launch")
        XCTAssertTrue(AppSettings(defaults: defaults).newlyKnown.isEmpty, "Now they're known")
    }

    func testNewsAndAlertChoicesPersist() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.newsEnabled, "News is opt-in")
        settings.newsEnabled = true
        settings.alertPreferences.lowBalance = false
        settings.alertPreferences.touch(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertTrue(relaunched.newsEnabled)
        XCTAssertEqual(relaunched.alertPreferences, settings.alertPreferences)
    }

    // MARK: Snapshot cache: check times

    func testCheckTimesRoundTripAndSkipUnknownProviders() throws {
        let cache = SnapshotCache(directory: try makeFolder())
        XCTAssertTrue(cache.loadChecked().isEmpty)
        let checked: [Provider: Date] = [.claude: Date(timeIntervalSince1970: 1_790_000_000), .deepseek: Date(timeIntervalSince1970: 1_790_000_600)]
        cache.saveChecked(checked)
        XCTAssertEqual(cache.checkedURL.lastPathComponent, "checked.json")
        XCTAssertEqual(cache.loadChecked(), checked)

        try Data(#"{"claude":812030400,"someFutureProvider":812030400}"#.utf8).write(to: cache.checkedURL)
        XCTAssertEqual(cache.loadChecked(), [.claude: Date(timeIntervalSince1970: 1_790_337_600)])
        try Data("not json".utf8).write(to: cache.checkedURL)
        XCTAssertTrue(cache.loadChecked().isEmpty)
    }
}

/// Returns queued results in order, then repeats the last one. Between calls it answers with
/// `between`, like Claude's status line.
/// A client whose calls wait until `release()`, to hold a check in flight.
private final class GatedClient: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var count = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(provider: Provider) {
        self.provider = provider
    }

    var calls: Int {
        lock.withLock { count }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let waits = lock.withLock { () -> Bool in
            count += 1
            return !isOpen
        }
        if waits {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        let now = Date()
        return .success(QuotaSnapshot(
            provider: provider, usedPercent: 40, resetsAt: now.addingTimeInterval(86_400), fetchedAt: now, primaryTitle: "This cycle",
            windows: [QuotaWindow(id: "cycle", kind: .billingCycle, title: "This cycle", usedPercent: 40, resetsAt: now.addingTimeInterval(86_400))]
        ))
    }

    func release() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }
}

private final class ScriptedClient: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var results: [Result<QuotaSnapshot, ProviderError>]
    private var count = 0
    private let between: QuotaSnapshot?
    private var previousSnapshots: [QuotaSnapshot?] = []

    init(provider: Provider, results: [Result<QuotaSnapshot, ProviderError>], between: QuotaSnapshot? = nil) {
        self.provider = provider
        self.results = results
        self.between = between
    }

    var calls: Int {
        lock.withLock { count }
    }

    /// The previous readings `fetchBetweenCalls` was given.
    var betweenCalls: [QuotaSnapshot?] {
        lock.withLock { previousSnapshots }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        lock.withLock {
            previousSnapshots.append(previous)
            return between
        }
    }

    private var changes = 0

    /// How many times `credentialsChanged` was called.
    var credentialChanges: Int {
        lock.withLock { changes }
    }

    func credentialsChanged() {
        lock.withLock { changes += 1 }
    }
}
