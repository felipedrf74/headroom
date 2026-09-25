import Foundation

/// Opt-in hook in Claude Code's status line. Claude Code already passes its rate limits to a
/// custom status line command; this saves only `rate_limits` so Tokenroom can read Claude usage
/// without Claude's login, including after the Keychain token expires.
///
/// Install changes only `statusLine` in `~/.claude/settings.json`, after a backup, and chains any
/// status line that was there. Uninstall restores it. Project settings are never edited.
struct ClaudeStatusLineBridge: Sendable {
    enum BridgeError: Error, Equatable {
        /// `settings.json` exists but isn't a JSON object; it is left untouched.
        case invalidSettings
    }

    let claudeDirectory: URL
    let bridgeDirectory: URL

    static let standard = ClaudeStatusLineBridge(
        claudeDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        bridgeDirectory: SnapshotCache.defaultDirectory.appendingPathComponent("bridge", isDirectory: true)
    )

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var scriptURL: URL { bridgeDirectory.appendingPathComponent("claude-statusline.sh") }
    var readingURL: URL { bridgeDirectory.appendingPathComponent("claude-rate-limits.json") }
    var previousCommandURL: URL { bridgeDirectory.appendingPathComponent("previous-command") }
    var previousStatusLineURL: URL { bridgeDirectory.appendingPathComponent("previous-statusline.json") }
    /// `settings.json` as it was the first time the bridge changed it. Never pruned.
    var originalBackupURL: URL { bridgeDirectory.appendingPathComponent("settings.original.json") }

    /// The command Claude Code runs; quoted because the path has spaces.
    var command: String {
        "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var isInstalled: Bool {
        guard let settings = try? readSettings() else { return false }
        return isOurs(settings["statusLine"])
    }

    func install(now: Date = .now) throws {
        var settings = try readSettings()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: settingsURL.path) {
            // The file as it was before Tokenroom first changed it, kept for good; later
            // backups rotate.
            if !fileManager.fileExists(atPath: originalBackupURL.path) {
                try fileManager.copyItem(at: settingsURL, to: originalBackupURL)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalBackupURL.path)
            }
            let backup = bridgeDirectory.appendingPathComponent("settings.backup-\(Int(now.timeIntervalSince1970 * 1000)).json")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: settingsURL, to: backup)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            pruneBackups()
        }

        let current = settings["statusLine"] as? [String: Any]
        var statusLine: [String: Any] = [:]
        if isOurs(current) {
            // Reinstalling: keep what was saved the first time.
            statusLine = current ?? [:]
        } else if let current {
            try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: previousStatusLineURL, options: .atomic)
            try Data(((current["command"] as? String) ?? "").utf8).write(to: previousCommandURL, options: .atomic)
            statusLine = current
        } else {
            try? fileManager.removeItem(at: previousStatusLineURL)
            try? fileManager.removeItem(at: previousCommandURL)
        }

        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        statusLine["type"] = "command"
        statusLine["command"] = command
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    func uninstall() throws {
        var settings = try readSettings()
        if isOurs(settings["statusLine"]) {
            if let data = try? Data(contentsOf: previousStatusLineURL),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings["statusLine"] = previous
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            try writeSettings(settings)
        }
        // If the user changed the status line since, it stays; only Tokenroom's files go.
        for url in [scriptURL, readingURL, previousCommandURL, previousStatusLineURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The latest rate limits Claude Code handed to the status line, or nil.
    func reading() -> ClaudeBridgeReading? {
        guard let data = try? Data(contentsOf: readingURL),
              let root = try? JSONFlex.object(from: data),
              let modified = (try? readingURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        let weekly = JSONFlex.dictionary(root["seven_day"])
        let session = JSONFlex.dictionary(root["five_hour"])
        let reading = ClaudeBridgeReading(
            weeklyUsed: JSONFlex.number(weekly?["used_percentage"]),
            weeklyResetsAt: JSONFlex.date(weekly?["resets_at"]),
            sessionUsed: JSONFlex.number(session?["used_percentage"]),
            sessionResetsAt: JSONFlex.date(session?["resets_at"]),
            at: modified
        )
        return reading.weeklyUsed == nil && reading.sessionUsed == nil ? nil : reading
    }

    private func isOurs(_ statusLine: Any?) -> Bool {
        guard let command = (statusLine as? [String: Any])?["command"] as? String else { return false }
        return command.contains(scriptURL.path)
    }

    /// Missing settings read as empty; anything that isn't a JSON object is refused.
    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL) else { throw BridgeError.invalidSettings }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalidSettings
        }
        return object
    }

    /// Changes only `statusLine` in the file as the user wrote it; rewrites the whole file only
    /// when that edit can't be made and checked.
    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        if let original = try? String(contentsOf: settingsURL, encoding: .utf8) {
            let edited: String?
            if let statusLine = settings["statusLine"] {
                edited = JSONTextEdit.setting("statusLine", to: statusLine, in: original)
            } else {
                edited = JSONTextEdit.removing("statusLine", in: original)
            }
            if let edited, let data = edited.data(using: .utf8),
               let check = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               NSDictionary(dictionary: check).isEqual(to: settings) {
                try data.write(to: settingsURL, options: .atomic)
                return
            }
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Keeps the five newest backups of `settings.json`.
    static let backupsKept = 5

    private func pruneBackups() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: bridgeDirectory.path) else { return }
        let backups = names.filter { $0.hasPrefix("settings.backup-") && $0.hasSuffix(".json") }
            .sorted { lhs, rhs in Self.backupTime(lhs) > Self.backupTime(rhs) }
        for name in backups.dropFirst(Self.backupsKept) {
            try? fileManager.removeItem(at: bridgeDirectory.appendingPathComponent(name))
        }
    }

    private static func backupTime(_ name: String) -> Int {
        Int(name.dropFirst("settings.backup-".count).dropLast(".json".count)) ?? 0
    }

    /// Projects whose own Claude Code settings set a status line, which wins over the one in
    /// `~/.claude/settings.json`. Read from Claude Code's project list; never edited.
    func projectOverrides(limit: Int = 300) -> [URL] {
        let configURL = claudeDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [] }
        var found: [URL] = []
        for path in projects.keys.sorted().prefix(limit) {
            let project = URL(fileURLWithPath: path, isDirectory: true)
            let folder = project.appendingPathComponent(".claude", isDirectory: true)
            // A project at the home folder shares the user settings file; that's ours.
            guard folder.standardizedFileURL != claudeDirectory.standardizedFileURL else { continue }
            for name in ["settings.json", "settings.local.json"] {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["statusLine"] != nil
                else { continue }
                found.append(project)
                break
            }
        }
        return found
    }

    /// Saves only `rate_limits` (never session, folder, or transcript data), then runs the
    /// previous status line so its output is still what Claude Code shows.
    static let script = """
    #!/bin/sh
    # Written by Tokenroom. Saves only the rate limits Claude Code passes to its status line,
    # then runs the status line you had before. Turn it off in Tokenroom Settings.
    dir="$(dirname "$0")"
    input="$(cat)"
    tmp="$dir/.rate-limits.$$"
    if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$tmp" - >/dev/null 2>&1; then
      mv -f "$tmp" "$dir/claude-rate-limits.json"
    else
      rm -f "$tmp"
    fi
    if [ -s "$dir/previous-command" ]; then
      printf '%s' "$input" | /bin/sh -c "$(cat "$dir/previous-command")"
    fi

    """
}

/// Rate limits from Claude Code's status line.
struct ClaudeBridgeReading: Equatable, Sendable {
    var weeklyUsed: Double?
    var weeklyResetsAt: Date?
    var sessionUsed: Double?
    var sessionResetsAt: Date?
    /// When Claude Code last wrote it.
    var at: Date

    /// Windows whose reset hasn't passed yet; nil when nothing current remains.
    func snapshot(now: Date = .now) -> QuotaSnapshot? {
        var windows: [QuotaWindow] = []
        if let weeklyUsed, (weeklyResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: JSONFlex.clampPercent(weeklyUsed), resetsAt: weeklyResetsAt, windowSeconds: 7 * 86_400))
        }
        if let sessionUsed, (sessionResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: JSONFlex.clampPercent(sessionUsed), resetsAt: sessionResetsAt, windowSeconds: 5 * 3_600))
        }
        guard let primary = windows.first else { return nil }
        return QuotaSnapshot(
            provider: .claude,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt,
            fetchedAt: at,
            primaryTitle: primary.title,
            windows: windows,
            source: "bridge"
        )
    }
}
