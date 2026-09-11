import XCTest
@testable import Headroom

final class ParserTests: XCTestCase {
    func testGrokCreditsPercentAndOnDemand() throws {
        let snapshot = try GrokParser.snapshot(from: fixture("grok-credits"))
        XCTAssertEqual(snapshot.usedPercent, 42.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[1].title, "Extra")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 5, accuracy: 0.01)
        XCTAssertNotNil(snapshot.resetsAt)
    }

    func testGrokMissingPercentIsZeroOnWeeklyPeriod() throws {
        let snapshot = try GrokParser.snapshot(from: fixture("grok-credits-zero"))
        XCTAssertEqual(snapshot.usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testClaudeWeeklyAndSession() throws {
        let snapshot = try ClaudeParser.snapshot(from: fixture("claude-usage"))
        XCTAssertEqual(snapshot.usedPercent, 71, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[1].kind, .session)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 18, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
    }

    func testOpenAIPrimaryWeeklyWhenSecondaryMissing() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-weekly-primary"))
        XCTAssertEqual(snapshot.usedPercent, 91, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testOpenAISecondaryIsWeeklyAndPrimaryIsSession() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-secondary-weekly"))
        XCTAssertEqual(snapshot.usedPercent, 18, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].title, "Weekly")
        XCTAssertEqual(snapshot.windows[1].kind, .session)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 40, accuracy: 0.01)
    }

    func testCursorUsesMaxPoolAndLabelsCycle() throws {
        let snapshot = try CursorParser.snapshot(from: fixture("cursor-usage"))
        XCTAssertEqual(snapshot.usedPercent, 55, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "This cycle")
        XCTAssertEqual(snapshot.windows.map(\.title), ["This cycle", "Cursor Models", "Other Models"])
        XCTAssertNotNil(snapshot.resetsAt)
    }

    func testGrokBotWeeklyPercent() throws {
        let snapshot = try GrokBotParser.snapshot(from: fixture("grok-bot-usage"))
        XCTAssertEqual(snapshot.usedPercent, 8.708505, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.provider, .grokBot)
        XCTAssertNotNil(snapshot.resetsAt)
        XCTAssertEqual(snapshot.windows.last?.title, "SuperGrok Heavy")
    }

    func testMeterFillLengthClipsAndDropsEmpty() {
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 0, total: 200), 0)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 50, total: 200), 100)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 100, total: 200), 200)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: -10, total: 200), 0)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 140, total: 200), 200)
        XCTAssertEqual(MeterLayout.usedFraction(25), 0.25, accuracy: 0.0001)
    }

    func testCursorTokenFromTempDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("state.vscdb")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            db.path,
            "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'tok-test-cursor');",
        ]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        let previous = ProcessInfo.processInfo.environment["HEADROOM_CURSOR_DB"]
        defer {
            if let previous {
                setenv("HEADROOM_CURSOR_DB", previous, 1)
            } else {
                unsetenv("HEADROOM_CURSOR_DB")
            }
            CredentialReaders.invalidateCaches()
        }
        setenv("HEADROOM_CURSOR_DB", db.path, 1)
        CredentialReaders.invalidateCaches()
        XCTAssertEqual(try CredentialReaders.cursorAccessToken(), "tok-test-cursor")
        XCTAssertTrue(CredentialReaders.hasUsableCursorSession())
        XCTAssertNotNil(CredentialReaders.sessionStamp(.cursor))
        XCTAssertNotNil(CredentialReaders.sessionStamp(.grokBot))
    }

    func testMenuBarCollapse() {
        let four = [
            MenuMeter(provider: .grok, valueText: "42", remaining: 58, usedPercent: 42, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .claude, valueText: "71", remaining: 29, usedPercent: 71, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .openai, valueText: "18", remaining: 82, usedPercent: 18, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .cursor, valueText: "55", remaining: 45, usedPercent: 55, isStale: false, isPlaceholder: false),
        ]
        XCTAssertEqual(MenuBarLayout.density(for: four), .compact)
        let five = four + [
            MenuMeter(provider: .grokBot, valueText: "9", remaining: 91, usedPercent: 9, isStale: false, isPlaceholder: false),
        ]
        XCTAssertEqual(MenuBarLayout.density(for: five), .compact)
        XCTAssertEqual(
            MenuBarLayout.tooltip(for: four),
            "Grok Build 42%\nClaude 71%\nOpenAI 18%\nCursor 55%"
        )
        XCTAssertEqual(MenuBarLayout.compactText(for: four), "Build 42%  Claude 71%  GPT 18%  Cursor 55%")
    }

    func testClaudeTokenJSON() throws {
        let json = """
        {"mcpOAuth":{},"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1}}
        """
        XCTAssertEqual(try CredentialReaders.parseClaudeToken(json), "tok-123")
    }

    func testClaudeRefreshPreservesSiblingKeys() throws {
        let json = """
        {"mcpOAuth":{"keep":true},"claudeAiOauth":{"accessToken":"old","refreshToken":"r1","expiresAt":1,"scopes":["user:inference"]}}
        """
        let updated = try CredentialReaders.applyingClaudeRefresh(
            to: json,
            accessToken: "new",
            refreshToken: "r2",
            expiresIn: 100,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let object = try JSONSerialization.jsonObject(with: Data(updated.utf8)) as! [String: Any]
        XCTAssertEqual((object["mcpOAuth"] as? [String: Any])?["keep"] as? Bool, true)
        let oauth = object["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(oauth["accessToken"] as? String, "new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "r2")
        XCTAssertEqual((oauth["expiresAt"] as? NSNumber)?.intValue, 1_100_000)
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"])
    }

    func testPercentTextKeepsTenthWhenItMatters() {
        XCTAssertEqual(HeadroomFormat.percentText(42), "42")
        XCTAssertEqual(HeadroomFormat.percentText(42.04), "42")
        XCTAssertEqual(HeadroomFormat.percentText(13.649571), "13.6")
        XCTAssertEqual(HeadroomFormat.percentText(8.708505), "8.7")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(3 * 86_400 + 4 * 3600)
        XCTAssertEqual(RelativeTime.resets(later, now: now), "resets in 3d 4h")
        XCTAssertEqual(RelativeTime.ago(now.addingTimeInterval(-120), now: now), "2m ago")
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: ParserTests.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle(for: ParserTests.self).url(forResource: name, withExtension: "json")
        if let url, let data = try? Data(contentsOf: url) {
            return data
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try! Data(contentsOf: fallback)
    }
}
