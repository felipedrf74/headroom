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
        try JSONSerialization.data(withJSONObject: original).write(to: bridge.settingsURL)

        try bridge.install()
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
}
