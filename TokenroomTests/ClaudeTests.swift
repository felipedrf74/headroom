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

    /// Backup file names in the bridge folder, oldest first.
    private func backupFiles(_ bridge: ClaudeStatusLineBridge) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bridge.bridgeDirectory.path)
            .filter { $0.hasPrefix("settings.backup-") }
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
        let backups = try backupFiles(bridge)
        XCTAssertEqual(backups.count, 1, "settings.json is backed up before it's changed")
        XCTAssertEqual(try Data(contentsOf: bridge.bridgeDirectory.appendingPathComponent(backups[0])), originalData)
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
        let printed = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

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
        let merged = ClaudeClient.merged(direct, with: newer, now: now)
        XCTAssertEqual(merged.usedPercent, 58)
        XCTAssertEqual(merged.windows.map(\.usedPercent), [58, 22])

        let older = ClaudeBridgeReading(weeklyUsed: 30, weeklyResetsAt: nil, sessionUsed: nil, sessionResetsAt: nil, at: now.addingTimeInterval(-3_600))
        XCTAssertEqual(ClaudeClient.merged(direct, with: older, now: now), direct)

        let expiredSession = ClaudeBridgeReading(weeklyUsed: 40, weeklyResetsAt: now.addingTimeInterval(60), sessionUsed: 90, sessionResetsAt: now.addingTimeInterval(-60), at: now)
        XCTAssertEqual(expiredSession.snapshot(now: now)?.windows.map(\.id), ["weekly"], "A window past its reset is dropped")
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
        let merged = ClaudeClient.merged(direct, with: reading, now: now)
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

    func testClientStateSharesTheLastDirectReadingAndARetryAfter() {
        let state = ClaudeClientState()
        let until = Date(timeIntervalSince1970: 1_790_000_600)
        state.block(until: until)
        XCTAssertEqual(state.blockedUntil, until)
        let direct = QuotaSnapshot(provider: .claude, usedPercent: 50, resetsAt: nil, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000), primaryTitle: "Weekly", windows: [])
        state.recordDirect(direct)
        XCTAssertEqual(state.lastDirect, direct)
        XCTAssertNil(state.blockedUntil, "A good answer lifts the wait")
    }

    // MARK: Editing settings.json

    func testInstallKeepsTheOriginalAndTheFiveNewestBackups() throws {
        let bridge = try makeBridge()
        let first = Data(#"{"model":"opus"}"#.utf8)
        try first.write(to: bridge.settingsURL)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for step in 0..<7 {
            try bridge.install(now: start.addingTimeInterval(Double(step)))
        }
        XCTAssertEqual(try backupFiles(bridge), (2..<7).map { "settings.backup-\((1_790_000_000 + $0) * 1000).json" })
        let permissions = try FileManager.default.attributesOfItem(atPath: bridge.bridgeDirectory.appendingPathComponent("settings.backup-1790000006000.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "Backups are private")
        XCTAssertEqual(try Data(contentsOf: bridge.originalBackupURL), first, "The settings from before the first install are never pruned")
    }

    func testBackupsWithinOneSecondDontOverwriteEachOther() throws {
        let bridge = try makeBridge()
        try Data(#"{"model":"opus"}"#.utf8).write(to: bridge.settingsURL)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try bridge.install(now: start)
        try bridge.install(now: start.addingTimeInterval(0.4))
        XCTAssertEqual(try backupFiles(bridge).count, 2)
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
}
