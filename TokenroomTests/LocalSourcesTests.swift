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
        XCTAssertNil(LocalSources.semanticVersion(in: "build 2026.09.25"), "A date isn't a version")
        XCTAssertEqual(LocalSources.semanticVersion(in: "2026.09.25 agy 1.2.0"), [1, 2, 0])
        XCTAssertEqual(LocalSources.semanticVersion(in: "agy 1.1.12."), [1, 1, 12], "A sentence's closing period isn't part of it")
        XCTAssertEqual(LocalSources.semanticVersion(in: "agy 1.1.12.3"), [1, 1, 12, 3], "A fourth part is kept")
        XCTAssertNil(LocalSources.semanticVersion(in: "build 2026.09.25.1"), "A dated build stamp still isn't one")
        XCTAssertTrue(LocalSources.version([1, 1, 11], isAtLeast: [1, 1, 11]))
        XCTAssertTrue(LocalSources.version([1, 2], isAtLeast: [1, 1, 11]))
        XCTAssertFalse(LocalSources.version([1, 1, 10], isAtLeast: [1, 1, 11]))
    }

    /// agy before 1.1.11 sends `/usage` to the model as a prompt, which spends quota. The read
    /// path runs it only when `--version` parses and is at least `AntigravityClient.minimumVersion`.
    /// (Finding and running agy itself isn't reachable without a real binary.)
    func testAgyIsOnlyRunWhenItsVersionIsKnownAndNewEnough() {
        func allowed(_ output: String) -> Bool {
            guard let version = LocalSources.semanticVersion(in: output) else { return false }
            return LocalSources.version(version, isAtLeast: AntigravityClient.minimumVersion)
        }
        XCTAssertEqual(AntigravityClient.minimumVersion, [1, 1, 11])
        XCTAssertTrue(allowed("agy 1.1.11"))
        XCTAssertTrue(allowed("agy version 1.1.12 (build 4f2c1a)\n"))
        XCTAssertTrue(allowed("1.2"), "A missing patch counts as zero")
        XCTAssertTrue(allowed("agy 2.0.0-beta.3"))
        XCTAssertTrue(allowed("agy 1.1.12."))
        XCTAssertTrue(allowed("agy 1.1.11.4"))
        XCTAssertFalse(allowed("agy 1.1.10.9"), "A fourth part doesn't lift an older version")
        XCTAssertFalse(allowed("agy 1.1.10"))
        XCTAssertFalse(allowed("agy 1.0.99"))
        XCTAssertFalse(allowed("agy 0.9"))
        XCTAssertFalse(allowed("agy dev build"), "An unknown version is never run")
        XCTAssertFalse(allowed(""))
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

    /// A missing row is just signed out: the database is copied only when it can't be read in
    /// place, never on every check.
    func testVSCodeStateCopiesOnlyADatabaseItCantRead() throws {
        let folder = try makeFolder()
        let database = folder.appendingPathComponent("state.vscdb")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'placeholder'), ('blank', '');"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(LocalSources.sqliteRead("cursorAuth/accessToken", path: database.path), .value("placeholder"))
        XCTAssertEqual(LocalSources.sqliteRead("missing", path: database.path), .missing)
        XCTAssertEqual(LocalSources.sqliteRead("blank", path: database.path), .missing)

        var copies = 0
        let countCopies: (URL) -> URL? = { _ in
            copies += 1
            return nil
        }
        XCTAssertNil(LocalSources.vscodeState("missing", database: database, copy: countCopies))
        XCTAssertEqual(copies, 0, "Signed out isn't a reason to copy the database")

        let unreadable = folder.appendingPathComponent("unreadable.vscdb")
        try Data(repeating: 0x2A, count: 4096).write(to: unreadable)
        XCTAssertEqual(LocalSources.sqliteRead("missing", path: unreadable.path), .unreadable)
        XCTAssertNil(LocalSources.vscodeState("missing", database: unreadable, copy: countCopies))
        XCTAssertEqual(copies, 1, "One that can't be read in place is")
    }
}
