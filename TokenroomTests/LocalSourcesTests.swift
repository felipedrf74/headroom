import XCTest
@testable import Tokenroom

final class LocalSourcesTests: XCTestCase {
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

    func testClaudeSettingsKeyOnlyForMatchingHosts() throws {
        let claude = try makeFolder()
        let settings: [String: Any] = ["env": [
            "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
            "ANTHROPIC_AUTH_TOKEN": "placeholder-coding-key",
        ]]
        try JSONSerialization.data(withJSONObject: settings).write(to: claude.appendingPathComponent("settings.json"))
        XCTAssertEqual(LocalSources.claudeSettingsKey(forHosts: ["api.z.ai", "open.bigmodel.cn"], claudeDirectory: claude), "placeholder-coding-key")
        XCTAssertNil(LocalSources.claudeSettingsKey(forHosts: ["api.minimax.io"], claudeDirectory: claude), "Another provider's key is never used")
        XCTAssertNil(LocalSources.claudeSettingsKey(forHosts: ["api.z.ai"], claudeDirectory: try makeFolder()), "No settings, no key")
    }

    func testVersionGuard() {
        XCTAssertEqual(LocalSources.semanticVersion(in: "agy 1.1.12 (build abc)"), [1, 1, 12])
        XCTAssertEqual(LocalSources.semanticVersion(in: "v2.0"), [2, 0])
        XCTAssertNil(LocalSources.semanticVersion(in: "unknown"))
        XCTAssertTrue(LocalSources.version([1, 1, 11], isAtLeast: [1, 1, 11]))
        XCTAssertTrue(LocalSources.version([1, 2], isAtLeast: [1, 1, 11]))
        XCTAssertFalse(LocalSources.version([1, 1, 10], isAtLeast: [1, 1, 11]))
    }

    func testJSONStringAtKeyPath() throws {
        let file = try makeFolder().appendingPathComponent("auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"placeholder-go-key"}}"#.utf8).write(to: file)
        XCTAssertEqual(LocalSources.jsonString(at: ["opencode-go", "key"], in: file), "placeholder-go-key")
        XCTAssertNil(LocalSources.jsonString(at: ["opencode-go", "missing"], in: file))
    }

    func testVSCodeStateReadsAnyKey() throws {
        let database = try makeFolder().appendingPathComponent("state.vscdb")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            database.path,
            #"CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{"apiKey":"placeholder"}');"#,
        ]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(LocalSources.vscodeState("windsurfAuthStatus", database: database), #"{"apiKey":"placeholder"}"#)
        XCTAssertNil(LocalSources.vscodeState("missing", database: database))
        XCTAssertNil(LocalSources.vscodeState("windsurfAuthStatus", database: database.deletingLastPathComponent().appendingPathComponent("none.vscdb")))
    }
}
