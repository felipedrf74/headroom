import Foundation
import SQLite3

/// Read-only access to the places other tools keep their logins. Nothing here writes, refreshes,
/// or copies a credential into Tokenroom's storage. All of it blocks: call through `BlockingIO`.
enum LocalSources {
    // MARK: VS Code-style state databases (Cursor, Devin/Windsurf)

    /// A value from a VS Code-style `state.vscdb` (`ItemTable`), read-only. Falls back to a
    /// temporary copy when the live database refuses a read-only open.
    static func vscodeState(_ key: String, database: URL) -> String? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        if let value = sqliteValue(key, path: database.path) {
            return value
        }
        guard let copy = copyDatabase(database) else { return nil }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return sqliteValue(key, path: copy.path)
    }

    static func sqliteValue(_ key: String, path: String) -> String? {
        var database: OpaquePointer?
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?"))) ?? path
        if sqlite3_open_v2("file://\(encoded)?mode=ro", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            if let database { sqlite3_close(database) }
            database = nil
            if sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                if let database { sqlite3_close(database) }
                return nil
            }
        }
        guard let database else { return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        _ = sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }

    private static func copyDatabase(_ source: URL) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomState-\(UUID().uuidString)", isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let extra = URL(fileURLWithPath: source.path + suffix)
                if FileManager.default.fileExists(atPath: extra.path) {
                    try FileManager.default.copyItem(at: extra, to: URL(fileURLWithPath: destination.path + suffix))
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    // MARK: Claude Code settings (z.ai, MiniMax)

    /// A coding-plan key that Claude Code is configured to use, found in `~/.claude/settings.json`
    /// (`env.ANTHROPIC_AUTH_TOKEN` or `env.ANTHROPIC_API_KEY`) when `env.ANTHROPIC_BASE_URL` points
    /// at one of `hosts`. Read in place on every refresh; never copied.
    static func claudeSettingsKey(forHosts hosts: [String], claudeDirectory: URL = defaultClaudeDirectory) -> String? {
        let url = claudeDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONFlex.object(from: data),
              let env = JSONFlex.dictionary(root["env"]),
              let base = JSONFlex.string(env["ANTHROPIC_BASE_URL"]),
              let host = URL(string: base)?.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        let key = JSONFlex.string(env["ANTHROPIC_AUTH_TOKEN"]) ?? JSONFlex.string(env["ANTHROPIC_API_KEY"])
        return key?.isEmpty == false ? key : nil
    }

    static var defaultClaudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// A string at a key path in a JSON file, e.g. `["opencode-go", "key"]`.
    static func jsonString(at path: [String], in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), var current = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else { return nil }
            current = next
        }
        guard let value = current as? String, !value.isEmpty else { return nil }
        return value
    }

    // MARK: CLI JSON (Antigravity's agy)

    /// `major.minor.patch` from `--version` output, e.g. "agy 1.1.12 (abc)" → [1, 1, 12].
    static func semanticVersion(in text: String) -> [Int]? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }

    static func version(_ version: [Int], isAtLeast minimum: [Int]) -> Bool {
        for index in 0..<max(version.count, minimum.count) {
            let left = index < version.count ? version[index] : 0
            let right = index < minimum.count ? minimum[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    /// Runs a CLI that prints JSON, in an empty temporary folder with no input, and returns its
    /// output. Nil when it fails or times out.
    static func runJSONCommand(_ executable: URL, arguments: [String], timeout: TimeInterval = 20) -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomCLI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Tooling.searchPATH
        environment["NO_COLOR"] = "1"
        let output = BlockingIO.runProcess(executable, arguments: arguments, timeout: timeout, currentDirectory: folder, environment: environment)
        guard output.succeeded, !output.stdout.isEmpty else { return nil }
        return output.stdout
    }
}
