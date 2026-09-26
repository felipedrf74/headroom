import XCTest
@testable import Tokenroom

final class ClaudeTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    private func makeBridge() throws -> ClaudeStatusLineBridge {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(root)
        // A space in the path, like "Application Support".
        let bridge = ClaudeStatusLineBridge(
            claudeDirectory: root.appendingPathComponent(".claude", isDirectory: true),
            bridgeDirectory: root.appendingPathComponent("App Support/bridge", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: bridge.claudeDirectory, withIntermediateDirectories: true)
        return bridge
    }

    private func settings(_ bridge: ClaudeStatusLineBridge) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.settingsURL)) as! [String: Any]
    }

    /// Full copies of settings.json in the bridge folder, named as Tokenroom 2.0.0 kept them.
    private func fullCopies(_ bridge: ClaudeStatusLineBridge) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bridge.bridgeDirectory.path)
            .filter { $0 == "settings.original.json" || $0.hasPrefix("settings.backup-") }
            .sorted()
    }

    /// Writes a status-line reading as Claude Code's script would, `age` seconds ago.
    private func writeReading(_ bridge: ClaudeStatusLineBridge, weekly: Double, session: Double, age: TimeInterval) throws {
        try FileManager.default.createDirectory(at: bridge.bridgeDirectory, withIntermediateDirectories: true)
        // Resets far ahead, so nothing is dropped as past.
        let json = #"{"five_hour":{"used_percentage":\#(session),"resets_at":4102444800},"seven_day":{"used_percentage":\#(weekly),"resets_at":4102444800}}"#
        try Data(json.utf8).write(to: bridge.readingURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: bridge.readingURL.path)
    }

    /// Runs the installed script as Claude Code does, with `input` on stdin; returns what it printed.
    private func runScript(_ bridge: ClaudeStatusLineBridge, input: String) throws -> String {
        let process = Process()
        process.executableURL = bridge.scriptURL
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A direct read with every kind of window: the status line's two, model caps, and extra usage.
    private func directReading(at fetchedAt: Date, now: Date) -> QuotaSnapshot {
        let week = now.addingTimeInterval(3 * 86_400)
        return QuotaSnapshot(
            provider: .claude, usedPercent: 50, resetsAt: week, fetchedAt: fetchedAt, primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 50, resetsAt: week),
                QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 10, resetsAt: now.addingTimeInterval(3_600)),
                QuotaWindow(id: "seven_day_opus", kind: .weekly, title: "Opus weekly", usedPercent: 80, resetsAt: week),
                QuotaWindow(id: "limit-0", kind: .weekly, title: "Fable weekly", usedPercent: 30, resetsAt: week),
            ],
            extra: ExtraUsage(title: "Extra usage", amount: QuotaAmount(used: 5, limit: 50, remaining: 45, unit: "usd"))
        )
    }

    // MARK: Parser

    func testFullUsageWithModelCapsAndExtraUsage() throws {
        let snapshot = try ClaudeParser.snapshot(from: fixture("claude-usage-full"))
        XCTAssertEqual(snapshot.windows.map(\.title), ["Weekly", "Session", "Opus weekly", "Fable weekly"], "Inactive and unscoped limits are skipped")
        XCTAssertEqual(snapshot.windows[0].startsAt, ISO8601DateFormatter().date(from: "2026-09-21T19:00:00Z"))
        let extra = try XCTUnwrap(snapshot.extra)
        XCTAssertEqual(extra.amount.limit ?? 0, 50, accuracy: 0.001, "Minor units scale by decimal_places")
        XCTAssertEqual(extra.amount.used ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(extra.amount.remaining ?? 0, 37.5, accuracy: 0.001)
        XCTAssertEqual(extra.amount.unit, "usd")
    }

    func testMinimalUsageStillParses() throws {
        let snapshot = try ClaudeParser.snapshot(from: fixture("claude-usage"))
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session"])
        XCTAssertNil(snapshot.extra)
    }

    // MARK: Status-line bridge

    func testInstallIntoEmptyClaudeFolder() throws {
        let bridge = try makeBridge()
        try bridge.install()
        XCTAssertTrue(bridge.isInstalled)
        let statusLine = try XCTUnwrap(try settings(bridge)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, bridge.command)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.scriptURL.path))
    }

    func testChainsAndRestoresAnExistingStatusLine() throws {
        let bridge = try makeBridge()
        let original: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "echo mine", "padding": 2],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: bridge.settingsURL)

        try bridge.install()
        XCTAssertEqual(try fullCopies(bridge), [], "Only the previous status line is kept, never a copy of settings.json")
        try bridge.install() // idempotent: the first saved status line is kept
        let installed = try XCTUnwrap(try settings(bridge)["statusLine"] as? [String: Any])
        XCTAssertEqual(installed["padding"] as? Int, 2, "Other statusLine keys stay")
        XCTAssertEqual(try String(contentsOf: bridge.previousCommandURL, encoding: .utf8), "echo mine")
        XCTAssertEqual(try settings(bridge)["model"] as? String, "opus", "Other settings stay")

        try bridge.uninstall()
        let restored = try XCTUnwrap(try settings(bridge)["statusLine"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "echo mine")
        XCTAssertEqual(restored["padding"] as? Int, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.scriptURL.path))
    }

    func testUninstallWithoutPreviousStatusLineRemovesTheKey() throws {
        let bridge = try makeBridge()
        try bridge.install()
        try bridge.uninstall()
        XCTAssertNil(try settings(bridge)["statusLine"])
    }

    func testRefusesInvalidSettingsAndLeavesThemAlone() throws {
        let bridge = try makeBridge()
        let broken = Data("{ not json".utf8)
        try broken.write(to: bridge.settingsURL)
        XCTAssertThrowsError(try bridge.install()) { error in
            XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .invalidSettings)
        }
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), broken)
    }

    func testScriptSavesOnlyRateLimitsAndRunsThePreviousStatusLine() throws {
        let bridge = try makeBridge()
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "cat >/dev/null; echo previous line"]])
            .write(to: bridge.settingsURL)
        try bridge.install()

        let input = #"{"cwd":"/private/project","session_id":"abc","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":4102444800},"seven_day":{"used_percentage":40,"resets_at":4102444800}}}"#
        let printed = try runScript(bridge, input: input)

        XCTAssertEqual(printed.trimmingCharacters(in: .whitespacesAndNewlines), "previous line")
        let saved = String(decoding: try Data(contentsOf: bridge.readingURL), as: UTF8.self)
        XCTAssertFalse(saved.contains("cwd") || saved.contains("session_id"), "Only rate_limits are kept")

        let reading = try XCTUnwrap(bridge.reading())
        XCTAssertEqual(reading.weeklyUsed, 40)
        XCTAssertEqual(reading.sessionUsed, 12)
        let snapshot = try XCTUnwrap(reading.snapshot())
        XCTAssertEqual(snapshot.source, "bridge")
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "session"])
    }

    func testRateLimitsWithoutPercentagesKeepTheLastReading() throws {
        let bridge = try makeBridge()
        try bridge.install()
        _ = try runScript(bridge, input: #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":4102444800},"seven_day":{"used_percentage":40,"resets_at":4102444800}}}"#)
        let saved = try Data(contentsOf: bridge.readingURL)

        for input in [#"{"rate_limits":{}}"#, #"{"rate_limits":{"five_hour":{}}}"#, #"{"session_id":"abc"}"#] {
            _ = try runScript(bridge, input: input)
            XCTAssertEqual(try Data(contentsOf: bridge.readingURL), saved, "\(input) leaves the last reading")
        }
        _ = try runScript(bridge, input: #"{"rate_limits":{"seven_day":{"used_percentage":41,"resets_at":4102444800}}}"#)
        XCTAssertEqual(bridge.reading()?.weeklyUsed, 41, "One window with a percentage is a reading")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bridge.bridgeDirectory.path).filter { $0.hasPrefix(".rate-limits") }
        XCTAssertEqual(leftovers, [], "Temporary files are cleaned up")
    }

    func testNewerBridgeReadingWinsAndResetWindowsDrop() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let direct = QuotaSnapshot(
            provider: .claude, usedPercent: 50, resetsAt: now.addingTimeInterval(86_400), fetchedAt: now.addingTimeInterval(-600),
            primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(86_400)),
                QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 10, resetsAt: now.addingTimeInterval(3_600)),
            ]
        )
        let newer = ClaudeBridgeReading(weeklyUsed: 58, weeklyResetsAt: now.addingTimeInterval(86_400), sessionUsed: 22, sessionResetsAt: now.addingTimeInterval(3_600), at: now)
        let merged = try XCTUnwrap(ClaudeClient.merged(direct, with: newer, now: now))
        XCTAssertEqual(merged.usedPercent, 58)
        XCTAssertEqual(merged.windows.map(\.usedPercent), [58, 22])

        let older = ClaudeBridgeReading(weeklyUsed: 30, weeklyResetsAt: nil, sessionUsed: nil, sessionResetsAt: nil, at: now.addingTimeInterval(-3_600))
        XCTAssertNil(ClaudeClient.merged(direct, with: older, now: now), "Nothing newer to add")

        let expiredSession = ClaudeBridgeReading(weeklyUsed: 40, weeklyResetsAt: now.addingTimeInterval(60), sessionUsed: 90, sessionResetsAt: now.addingTimeInterval(-60), at: now)
        XCTAssertEqual(expiredSession.snapshot(now: now)?.windows.map(\.id), ["weekly"], "A window past its reset is dropped")
    }

    func testDirectOnlyWindowsLastOnlyAsLongAsTheDirectRead() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reading = ClaudeBridgeReading(weeklyUsed: 58, weeklyResetsAt: now.addingTimeInterval(3 * 86_400), sessionUsed: 22, sessionResetsAt: now.addingTimeInterval(3_600), at: now.addingTimeInterval(-30))

        let recent = try XCTUnwrap(ClaudeClient.merged(directReading(at: now.addingTimeInterval(-20 * 60), now: now), with: reading, now: now))
        XCTAssertEqual(recent.windows.map(\.id), ["weekly", "session", "seven_day_opus", "limit-0"])
        XCTAssertEqual(recent.windows.map(\.usedPercent), [58, 22, 80, 30])
        XCTAssertNotNil(recent.extra)

        let old = try XCTUnwrap(ClaudeClient.merged(directReading(at: now.addingTimeInterval(-ClaudeClient.directReuse - 60), now: now), with: reading, now: now))
        XCTAssertEqual(old.windows.map(\.id), ["weekly", "session"], "Model caps the status line doesn't carry go with an old direct read")
        XCTAssertEqual(old.windows.map(\.usedPercent), [58, 22])
        XCTAssertNil(old.extra, "Extra usage too")
        XCTAssertEqual(old.fetchedAt, reading.at)
        XCTAssertEqual(old.source, "bridge")
    }

    func testWindowsPastTheirResetAreDropped() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var direct = directReading(at: now.addingTimeInterval(-10 * 60), now: now)
        direct.windows[1].resetsAt = now.addingTimeInterval(-60)
        direct.windows[2].resetsAt = now.addingTimeInterval(-60)
        let reading = ClaudeBridgeReading(weeklyUsed: 52, weeklyResetsAt: now.addingTimeInterval(3 * 86_400), sessionUsed: nil, sessionResetsAt: nil, at: now.addingTimeInterval(-30))
        let merged = try XCTUnwrap(ClaudeClient.merged(direct, with: reading, now: now))
        XCTAssertEqual(merged.windows.map(\.id), ["weekly", "limit-0"], "However recent the direct read, a window whose reset passed goes")
    }

    func testTheStatusLineAloneNeedsACurrentWeeklyWindow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let pastWeek = ClaudeBridgeReading(weeklyUsed: 90, weeklyResetsAt: now.addingTimeInterval(-60), sessionUsed: 30, sessionResetsAt: now.addingTimeInterval(3_600), at: now.addingTimeInterval(-600))
        XCTAssertEqual(pastWeek.windows(now: now).map(\.id), ["session"])
        XCTAssertNil(pastWeek.snapshot(now: now), "Once the week resets, Session doesn't headline in its place")
        XCTAssertNil(ClaudeClient.combined(nil, pastWeek, now: now))
        var sameWeek = directReading(at: now.addingTimeInterval(-15 * 60), now: now)
        sameWeek.windows[0].resetsAt = now.addingTimeInterval(-60)
        XCTAssertNil(ClaudeClient.merged(sameWeek, with: pastWeek, now: now), "Nor next to a direct read of the week that reset")

        // Next to a recent direct read, a status line without the week still updates the session.
        let sessionOnly = ClaudeBridgeReading(weeklyUsed: nil, weeklyResetsAt: nil, sessionUsed: 30, sessionResetsAt: now.addingTimeInterval(3_600), at: now.addingTimeInterval(-60))
        let merged = try XCTUnwrap(ClaudeClient.merged(directReading(at: now.addingTimeInterval(-15 * 60), now: now), with: sessionOnly, now: now))
        XCTAssertEqual(merged.windows.map(\.usedPercent), [50, 30, 80, 30])
        XCTAssertEqual(merged.primaryTitle, "Weekly")
        XCTAssertEqual(merged.usedPercent, 50)

        // Without a weekly value at all (an account without one, or Claude Code leaving it out),
        // the session headlines, alone or once the direct read is too old to keep its week.
        let alone = try XCTUnwrap(sessionOnly.snapshot(now: now))
        XCTAssertEqual(alone.primaryTitle, "Session")
        XCTAssertEqual(alone.usedPercent, 30)
        let afterExpiry = try XCTUnwrap(ClaudeClient.merged(directReading(at: now.addingTimeInterval(-2 * 3_600), now: now), with: sessionOnly, now: now))
        XCTAssertEqual(afterExpiry.windows.map(\.id), ["session"], "The expired token's week isn't kept")
        XCTAssertEqual(afterExpiry.primaryTitle, "Session")
        XCTAssertEqual(afterExpiry.usedPercent, 30)
    }

    func testMergedKeepsDirectWindowsAndAddsTheStatusLinesOwn() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let week = now.addingTimeInterval(86_400)
        let direct = QuotaSnapshot(
            provider: .claude, usedPercent: 50, resetsAt: week, fetchedAt: now.addingTimeInterval(-600),
            primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 50, resetsAt: week),
                QuotaWindow(id: "seven_day_opus", kind: .weekly, title: "Opus weekly", usedPercent: 20, resetsAt: week),
            ],
            extra: ExtraUsage(title: "Extra usage", amount: QuotaAmount(used: 5, limit: 50, remaining: 45, unit: "usd"))
        )
        let reading = ClaudeBridgeReading(weeklyUsed: 58, weeklyResetsAt: nil, sessionUsed: 22, sessionResetsAt: now.addingTimeInterval(3_600), at: now.addingTimeInterval(-30))
        let merged = try XCTUnwrap(ClaudeClient.merged(direct, with: reading, now: now))
        XCTAssertEqual(merged.windows.map(\.id), ["weekly", "seven_day_opus", "session"], "A session the direct read didn't have is added")
        XCTAssertEqual(merged.windows.map(\.usedPercent), [58, 20, 22])
        XCTAssertEqual(merged.windows[0].resetsAt, week, "A missing reset time keeps the direct one")
        XCTAssertEqual(merged.usedPercent, 58)
        XCTAssertEqual(merged.fetchedAt, reading.at, "The reading is as recent as the status line")
        XCTAssertEqual(merged.source, "bridge")
        XCTAssertEqual(merged.extra, direct.extra)
    }

    func testCombinedUsesTheStatusLineAloneWithoutADirectReading() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reading = ClaudeBridgeReading(weeklyUsed: 40, weeklyResetsAt: now.addingTimeInterval(86_400), sessionUsed: nil, sessionResetsAt: nil, at: now)
        XCTAssertNil(ClaudeClient.combined(nil, nil, now: now))
        XCTAssertEqual(ClaudeClient.combined(nil, reading, now: now), reading.snapshot(now: now))
        let direct = try ClaudeParser.snapshot(from: fixture("claude-usage"), fetchedAt: now.addingTimeInterval(-60))
        XCTAssertNil(ClaudeClient.combined(direct, nil, now: now), "Nothing newer to add")
        XCTAssertEqual(ClaudeClient.combined(direct, reading, now: now), ClaudeClient.merged(direct, with: reading, now: now))
        var older = reading
        older.at = direct.fetchedAt.addingTimeInterval(-60)
        XCTAssertNil(ClaudeClient.combined(direct, older, now: now), "An older status line doesn't stand in for a failed direct read")
    }

    func testOldStatusLineReadingsAreIgnored() async throws {
        let bridge = try makeBridge()
        let client = ClaudeClient(bridge: bridge)

        try writeReading(bridge, weekly: 44, session: 12, age: 7 * 3600)
        let stale = await client.fetchBetweenCalls(previous: nil)
        XCTAssertNil(stale, "Claude may have been used elsewhere in six hours")

        try writeReading(bridge, weekly: 44, session: 12, age: 60)
        let fresh = await client.fetchBetweenCalls(previous: nil)
        XCTAssertEqual(fresh?.windows.map(\.usedPercent), [44, 12])
        XCTAssertEqual(fresh?.source, "bridge")

        let newer = QuotaSnapshot(provider: .claude, usedPercent: 50, resetsAt: nil, fetchedAt: Date(), primaryTitle: "Weekly", windows: [])
        let unchanged = await client.fetchBetweenCalls(previous: newer)
        XCTAssertNil(unchanged, "Not newer than what's shown")
    }

    func testAFreshStatusLineAnswersBetweenDirectReads() async throws {
        let bridge = try makeBridge()
        let client = ClaudeClient(bridge: bridge)
        let direct = QuotaSnapshot(
            provider: .claude, usedPercent: 30, resetsAt: nil, fetchedAt: Date().addingTimeInterval(-600), primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 30, resetsAt: nil),
                QuotaWindow(id: "seven_day_opus", kind: .weekly, title: "Opus weekly", usedPercent: 10, resetsAt: nil),
            ]
        )
        client.state.recordDirect(direct)
        // Held off as well, so this test can never reach this Mac's real Claude login.
        client.state.block(until: Date().addingTimeInterval(600))
        try writeReading(bridge, weekly: 44, session: 12, age: 60)

        let answer = try await client.fetch().get()
        XCTAssertEqual(answer.windows.map(\.id), ["weekly", "seven_day_opus", "session"], "The direct read's other windows stay")
        XCTAssertEqual(answer.windows.map(\.usedPercent), [44, 10, 12])
        XCTAssertEqual(answer.source, "bridge")
    }

    func testWhileClaudeAsksToWaitOnlyTheStatusLineAnswers() async throws {
        let bridge = try makeBridge()
        let client = ClaudeClient(bridge: bridge)
        let until = Date().addingTimeInterval(600)
        client.state.block(until: until)
        let blocked = await client.fetch()
        XCTAssertEqual(blocked, .failure(.rateLimited(until: until)), "No reading to show, and no call before Retry-After")

        try writeReading(bridge, weekly: 44, session: 12, age: 10 * 60)
        let answer = try await client.fetch().get()
        XCTAssertEqual(answer.windows.map(\.usedPercent), [44, 12])
        XCTAssertEqual(answer.source, "bridge")
    }

    func testWhileClaudeAsksToWaitAnOldDirectReadsWindowsDrop() async throws {
        let bridge = try makeBridge()
        let client = ClaudeClient(bridge: bridge)
        let now = Date()
        let until = now.addingTimeInterval(600)
        client.state.recordDirect(directReading(at: now.addingTimeInterval(-2 * 3600), now: now))
        // Held off as well, so this test can never reach this Mac's real Claude login.
        client.state.block(until: until)
        try writeReading(bridge, weekly: 44, session: 12, age: 60)

        let answer = try await client.fetch().get()
        XCTAssertEqual(answer.windows.map(\.id), ["weekly", "session"], "Opus and other caps from two hours ago aren't shown as live")
        XCTAssertEqual(answer.windows.map(\.usedPercent), [44, 12])
        XCTAssertNil(answer.extra)

        try writeReading(bridge, weekly: 44, session: 12, age: 3 * 3600)
        let older = await client.fetch()
        XCTAssertEqual(older, .failure(.rateLimited(until: until)), "A status line older than the direct read adds nothing")
    }

    func testBetweenCallsTheDirectWindowsAgeWithTheDirectReadNotWhatIsShown() async throws {
        let bridge = try makeBridge()
        let client = ClaudeClient(bridge: bridge)
        let now = Date()
        // During a 429 wait the store asks between calls; direct calls stay blocked.
        client.state.recordDirect(directReading(at: now.addingTimeInterval(-2 * 3600), now: now))
        client.state.block(until: now.addingTimeInterval(600))
        // What's shown still carries Opus and extra usage, under an earlier status line's time.
        var shown = directReading(at: now.addingTimeInterval(-5 * 60), now: now)
        shown.source = "bridge"
        try writeReading(bridge, weekly: 44, session: 12, age: 60)

        let answer = await client.fetchBetweenCalls(previous: shown)
        XCTAssertEqual(answer?.windows.map(\.id), ["weekly", "session"])
        XCTAssertEqual(answer?.windows.map(\.usedPercent), [44, 12])
        XCTAssertNil(answer?.extra)
        XCTAssertEqual(answer?.source, "bridge")
        XCTAssertEqual(client.state.blockedUntil, now.addingTimeInterval(600), "Direct calls still wait")

        // After a relaunch there's no direct read to go by: the status line alone.
        let relaunched = ClaudeClient(bridge: bridge)
        let alone = await relaunched.fetchBetweenCalls(previous: shown)
        XCTAssertEqual(alone?.windows.map(\.id), ["weekly", "session"])
    }

    func testClientStateSharesTheLastDirectReadingAndARetryAfter() {
        let state = ClaudeClientState()
        let until = Date(timeIntervalSince1970: 1_790_000_600)
        state.block(until: until)
        XCTAssertEqual(state.blockedUntil, until)
        let direct = QuotaSnapshot(provider: .claude, usedPercent: 50, resetsAt: nil, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000), primaryTitle: "Weekly", windows: [])
        state.recordDirect(direct)
        XCTAssertEqual(state.lastDirect, direct)
        XCTAssertNil(state.blockedUntil, "A good answer lifts the wait")
        XCTAssertTrue(state.claimUpgrade())
        XCTAssertFalse(state.claimUpgrade(), "The bridge is brought up to date once per launch")
    }

    // MARK: Editing settings.json

    func testNoCopyOfSettingsIsKeptAndEarlierCopiesGo() throws {
        let bridge = try makeBridge()
        let fileManager = FileManager.default
        // settings.json can hold other tools' keys in env.
        let original = Data(#"{"env": {"ANTHROPIC_AUTH_TOKEN": "placeholder-key"}, "statusLine": {"type": "command", "command": "echo mine"}}"#.utf8)
        try original.write(to: bridge.settingsURL)
        // Copies Tokenroom 2.0.0 kept; for a symlinked settings.json it copied the link.
        try fileManager.createDirectory(at: bridge.bridgeDirectory, withIntermediateDirectories: true)
        try original.write(to: bridge.bridgeDirectory.appendingPathComponent("settings.original.json"))
        try original.write(to: bridge.bridgeDirectory.appendingPathComponent("settings.backup-1790000000000.json"))
        try fileManager.createSymbolicLink(at: bridge.bridgeDirectory.appendingPathComponent("settings.backup-1790000001000.json"), withDestinationURL: bridge.settingsURL)

        try bridge.install()
        XCTAssertEqual(try fullCopies(bridge), ["settings.backup-1790000001000.json"], "Installing removes the earlier copies; one that's a link holds no keys, only where it pointed")
        for name in try fileManager.contentsOfDirectory(atPath: bridge.bridgeDirectory.path) {
            let url = bridge.bridgeDirectory.appendingPathComponent(name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else { continue }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertFalse(text.contains("placeholder-key"), "\(name) holds nothing from env")
        }
        XCTAssertEqual((try settings(bridge)["env"] as? [String: String])?["ANTHROPIC_AUTH_TOKEN"], "placeholder-key", "The file it points at stays")
        XCTAssertEqual(bridge.replacedLink(), bridge.settingsURL.path, "Settings can say where the link went")
        bridge.forgetReplacedLink()
        XCTAssertNil(bridge.replacedLink(), "Until the note is dismissed")
        XCTAssertEqual(try fullCopies(bridge), [])

        try original.write(to: bridge.bridgeDirectory.appendingPathComponent("settings.original.json"))
        try bridge.uninstall()
        XCTAssertEqual(try fullCopies(bridge), [], "Turning the bridge off removes them too")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: bridge.bridgeDirectory.path), [], "Nothing of Tokenroom's is left")
    }

    func testTurningOffRemovesEarlierCopiesEvenAfterTheStatusLineChanged() throws {
        let bridge = try makeBridge()
        try bridge.install()
        try Data("{}".utf8).write(to: bridge.bridgeDirectory.appendingPathComponent("settings.original.json"))
        try Data("{}".utf8).write(to: bridge.bridgeDirectory.appendingPathComponent("settings.backup-1790000000000.json"))
        // The user replaced the status line since; it stays.
        let theirs = Data(#"{"statusLine": {"type": "command", "command": "echo theirs"}}"#.utf8)
        try theirs.write(to: bridge.settingsURL)

        try bridge.uninstall()
        XCTAssertEqual(try fullCopies(bridge), [])
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), theirs)
    }

    func testUpgradeRefreshesTheScriptAndRemovesEarlierCopies() throws {
        let bridge = try makeBridge()
        try Data(#"{"model":"opus"}"#.utf8).write(to: bridge.settingsURL)
        try bridge.install()
        let installed = try Data(contentsOf: bridge.settingsURL)
        try Data("#!/bin/sh\n# An earlier script\n".utf8).write(to: bridge.scriptURL)
        try Data("{}".utf8).write(to: bridge.bridgeDirectory.appendingPathComponent("settings.original.json"))

        bridge.upgrade()
        XCTAssertEqual(try String(contentsOf: bridge.scriptURL, encoding: .utf8), ClaudeStatusLineBridge.script)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.scriptURL.path))
        XCTAssertEqual(try fullCopies(bridge), [])
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), installed, "settings.json isn't touched")

        let off = try makeBridge()
        off.upgrade()
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.scriptURL.path), "A bridge that's off isn't set up")
    }

    /// Dotfiles (stow, home-manager) may be shared with other Macs, where Tokenroom's script
    /// isn't: a linked settings file is left for the user to change.
    func testALinkedSettingsFileIsLeftAlone() throws {
        let bridge = try makeBridge()
        let fileManager = FileManager.default
        let dotfiles = bridge.claudeDirectory.deletingLastPathComponent().appendingPathComponent("dotfiles", isDirectory: true)
        try fileManager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("claude-settings.json")
        let original = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        try original.write(to: target)
        // Relative, the way stow links it.
        try fileManager.createSymbolicLink(atPath: bridge.settingsURL.path, withDestinationPath: "../dotfiles/claude-settings.json")

        XCTAssertThrowsError(try bridge.install()) { error in
            guard case .linked(let shown, let command)? = error as? ClaudeStatusLineBridge.BridgeError else { return XCTFail("\(error)") }
            XCTAssertTrue(shown.hasSuffix("dotfiles/claude-settings.json"), shown)
            XCTAssertEqual(command, bridge.command)
            XCTAssertTrue(error.localizedDescription.contains(bridge.command), "Says what to set")
        }
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: bridge.settingsURL.path), "../dotfiles/claude-settings.json", "Still a link")
        XCTAssertEqual(try Data(contentsOf: target), original, "Untouched")
        XCTAssertFalse(fileManager.fileExists(atPath: bridge.scriptURL.path), "Nothing set up")
        XCTAssertFalse(bridge.isInstalled)

        // Set by hand, it reads as on; turning it off is left to the user too.
        let byHand = Data(#"{"statusLine": {"type": "command", "command": \#(String(decoding: try JSONEncoder().encode(bridge.command), as: UTF8.self))}}"#.utf8)
        try byHand.write(to: target)
        XCTAssertTrue(bridge.isInstalled)
        XCTAssertThrowsError(try bridge.uninstall()) { error in
            guard case .linkedToRemove? = error as? ClaudeStatusLineBridge.BridgeError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), byHand)

        // The same for a linked .claude folder.
        let linkedFolder = try makeBridge()
        let shared = linkedFolder.claudeDirectory.deletingLastPathComponent().appendingPathComponent("shared-claude", isDirectory: true)
        try fileManager.moveItem(at: linkedFolder.claudeDirectory, to: shared)
        try fileManager.createSymbolicLink(at: linkedFolder.claudeDirectory, withDestinationURL: shared)
        try original.write(to: shared.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try linkedFolder.install()) { error in
            guard case .linked? = error as? ClaudeStatusLineBridge.BridgeError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("settings.json")), original)

        // A linked folder with no settings file yet is still a link, not a broken one.
        try fileManager.removeItem(at: shared.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try linkedFolder.install()) { error in
            guard case .linked(let shown, _)? = error as? ClaudeStatusLineBridge.BridgeError else { return XCTFail("\(error)") }
            XCTAssertTrue(shown.hasSuffix("shared-claude/settings.json"), shown)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: shared.appendingPathComponent("settings.json").path))
    }

    func testAFolderThatCantBeWrittenSaysSo() throws {
        let bridge = try makeBridge()
        let original = Data(#"{"model": "opus"}"#.utf8)
        try original.write(to: bridge.settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bridge.claudeDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.claudeDirectory.path) }
        XCTAssertThrowsError(try bridge.install()) { error in
            XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .notWritable)
        }
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), original)
        XCTAssertFalse(bridge.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.scriptURL.path), "Refused before anything is written")
    }

    /// An atomic write would replace a read-only file in a folder that can be written to.
    func testAReadOnlySettingsFileIsRefusedNotReplaced() throws {
        let bridge = try makeBridge()
        let original = Data(#"{"model": "opus"}"#.utf8)
        try original.write(to: bridge.settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bridge.settingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bridge.settingsURL.path) }
        XCTAssertThrowsError(try bridge.install()) { error in
            XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .notWritable)
        }
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: bridge.settingsURL.path)[.posixPermissions] as? Int, 0o444, "Not replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.scriptURL.path))
    }

    func testALinkToNothingIsRefused() throws {
        let bridge = try makeBridge()
        try FileManager.default.createSymbolicLink(atPath: bridge.settingsURL.path, withDestinationPath: "../dotfiles/missing.json")
        XCTAssertThrowsError(try bridge.install()) { error in
            XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .brokenLink)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bridge.settingsURL.path), "../dotfiles/missing.json", "Not replaced by a file")
        XCTAssertFalse(bridge.isInstalled)
    }

    func testDuplicateStatusLinesAreRefused() throws {
        let bridge = try makeBridge()
        let duplicated = Data(#"{"statusLine": {"type": "command", "command": "echo first"}, "model": "opus", "statusLine": {"type": "command", "command": "echo last"}}"#.utf8)
        try duplicated.write(to: bridge.settingsURL)
        XCTAssertThrowsError(try bridge.install()) { error in
            XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .duplicateStatusLine)
        }
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), duplicated)

        // As 2.0.0 could leave it: Tokenroom's status line first, while Claude Code runs the last.
        let ours = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "command", "command": bridge.command], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        try Data(#"{"statusLine": \#(ours), "statusLine": {"type": "command", "command": "echo last"}}"#.utf8).write(to: bridge.settingsURL)
        XCTAssertFalse(bridge.isInstalled, "Claude Code runs the last one")
    }

    func testFilesTheEditCantHandleAreRefusedNotRewritten() throws {
        let bridge = try makeBridge()
        let json = "{\n  \"model\": \"opus\"\n}\n"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try XCTUnwrap(json.data(using: .utf16LittleEndian)))
        for (name, data) in [("UTF-16", utf16), ("UTF-16 without a byte order mark", try XCTUnwrap(json.data(using: .utf16LittleEndian)))] {
            try data.write(to: bridge.settingsURL)
            XCTAssertThrowsError(try bridge.install(), name) { error in
                XCTAssertEqual(error as? ClaudeStatusLineBridge.BridgeError, .unsupportedFormat, name)
            }
            XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), data, "\(name): left as it was")
            XCTAssertFalse(bridge.isInstalled, name)
        }

        // Foundation reads a comma after the last setting; Claude Code and the in-place edit don't.
        let trailingComma = Data("{\n  \"model\": \"opus\",\n}\n".utf8)
        try trailingComma.write(to: bridge.settingsURL)
        XCTAssertThrowsError(try bridge.install())
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), trailingComma, "Refused, not rewritten sorted and reformatted")
    }

    func testAByteOrderMarkAndCRLFLineEndingsStay() throws {
        let bridge = try makeBridge()
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let original = Data(bom + Array("{\r\n    \"model\": \"opus\"\r\n}\r\n".utf8))
        try original.write(to: bridge.settingsURL)

        try bridge.install()
        let installed = Array(try Data(contentsOf: bridge.settingsURL))
        XCTAssertEqual(Array(installed.prefix(3)), bom, "The byte order mark stays")
        XCTAssertTrue(String(decoding: installed.dropFirst(3), as: UTF8.self).hasPrefix("{\r\n    \"model\": \"opus\",\r\n    \"statusLine\": {"))
        XCTAssertTrue(installed.indices.allSatisfy { installed[$0] != 0x0A || ($0 > 0 && installed[$0 - 1] == 0x0D) }, "The added line ends in CRLF like the others")
        XCTAssertTrue(bridge.isInstalled)

        try bridge.uninstall()
        XCTAssertEqual(try Data(contentsOf: bridge.settingsURL), original, "Uninstall leaves the file as it was")
    }

    func testRefusalsSayWhatWentWrong() {
        let errors: [ClaudeStatusLineBridge.BridgeError] = [
            .invalidSettings, .duplicateStatusLine, .unsupportedFormat, .brokenLink,
            .linked(target: "~/dotfiles/claude-settings.json", command: "'/bridge/claude-statusline.sh'"),
            .linkedToRemove(target: "~/dotfiles/claude-settings.json"), .notWritable,
        ]
        for error in errors {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Couldn't change ~/.claude/settings.json"), "\(error)")
        }
    }

    func testInstallEditsOnlyTheStatusLineAndKeepsTheUsersFormatting() throws {
        let bridge = try makeBridge()
        let original = """
        {
            "permissions": { "allow": ["Bash(npm run test:*)"] },
            "model"  :  "opus",
            "env": {"NOTE": "a \\"quoted\\" } brace"}
        }

        """
        try Data(original.utf8).write(to: bridge.settingsURL)
        try bridge.install()
        let installed = try String(contentsOf: bridge.settingsURL, encoding: .utf8)
        XCTAssertTrue(installed.hasPrefix("{\n    \"permissions\": { \"allow\": [\"Bash(npm run test:*)\"] },\n    \"model\"  :  \"opus\",\n    \"env\": {\"NOTE\": \"a \\\"quoted\\\" } brace\"},\n    \"statusLine\": {"), "Everything before the new key is as the user wrote it")
        XCTAssertTrue(installed.hasSuffix("\"type\":\"command\"}\n}\n"), "Added last, at the same indentation")
        XCTAssertEqual(try settings(bridge)["model"] as? String, "opus")
        XCTAssertTrue(bridge.isInstalled)

        try bridge.uninstall()
        XCTAssertEqual(try String(contentsOf: bridge.settingsURL, encoding: .utf8), original, "Uninstall leaves the file as it was")
    }

    func testProjectsWithTheirOwnStatusLineAreFound() throws {
        let bridge = try makeBridge()
        let home = bridge.claudeDirectory.deletingLastPathComponent()
        func project(_ name: String, file: String?, statusLine: Bool) throws -> URL {
            let folder = home.appendingPathComponent("code/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            if let file {
                let settings: [String: Any] = statusLine ? ["statusLine": ["type": "command", "command": "echo project"]] : ["model": "sonnet"]
                try JSONSerialization.data(withJSONObject: settings).write(to: folder.appendingPathComponent(".claude/\(file)"))
            }
            return folder
        }
        let shared = try project("alpha", file: "settings.json", statusLine: true)
        let personal = try project("beta", file: "settings.local.json", statusLine: true)
        let plain = try project("gamma", file: "settings.json", statusLine: false)
        let bare = try project("delta", file: nil, statusLine: false)
        // The user settings folder itself sets a status line; it's the one Tokenroom edits.
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "echo user"]]).write(to: bridge.settingsURL)

        XCTAssertEqual(bridge.projectOverrides(), [], "No ~/.claude.json, no projects")
        let empty = [String: String]()
        let projects: [String: Any] = [
            shared.path: ["allowedTools": [String]()],
            personal.path: empty,
            plain.path: empty,
            bare.path: empty,
            home.path: empty,
            home.appendingPathComponent("code/missing").path: empty,
        ]
        let config: [String: Any] = ["numStartups": 3, "projects": projects]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"))

        XCTAssertEqual(bridge.projectOverrides().map(\.lastPathComponent), ["alpha", "beta"], "Shared or personal project settings; never the user folder itself")
        // Paths are read in order; the home folder sorts first and counts toward the limit.
        XCTAssertEqual(bridge.projectOverrides(limit: 2).map(\.lastPathComponent), ["alpha"])
    }

    func testTheHomeFolderIsKnownThroughALinkOrInAnotherCase() throws {
        let bridge = try makeBridge()
        let home = bridge.claudeDirectory.deletingLastPathComponent()
        // The user settings set a status line; it's the one Tokenroom edits.
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "echo user"]]).write(to: bridge.settingsURL)
        let link = home.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        var paths = [home.path, link.path]
        if (try? home.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false {
            paths.append(home.deletingLastPathComponent().appendingPathComponent(home.lastPathComponent.lowercased()).path)
        }
        let empty = [String: String]()
        let config: [String: Any] = ["projects": Dictionary(uniqueKeysWithValues: paths.map { ($0, empty) })]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(bridge.projectOverrides(), [], "The home folder's settings.json is the user settings file, however its path is spelled")

        // Its settings.local.json does replace the bridge for sessions in the home folder.
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "echo local"]])
            .write(to: bridge.claudeDirectory.appendingPathComponent("settings.local.json"))
        XCTAssertEqual(bridge.projectOverrides().count, paths.count)
    }
}
