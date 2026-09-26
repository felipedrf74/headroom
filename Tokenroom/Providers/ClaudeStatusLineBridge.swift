import Foundation

/// Opt-in hook in Claude Code's status line. Claude Code already passes its rate limits to a
/// custom status line command; this saves only `rate_limits` so Tokenroom can read Claude usage
/// without Claude's login, including after the Keychain token expires.
///
/// Install changes only `statusLine` in `~/.claude/settings.json` and chains any status line that
/// was there. Uninstall restores it. Only that status line is kept to restore, never a copy of the
/// file, which can hold keys in `env`. Project settings are never edited, and neither is a
/// settings file kept elsewhere through a link (dotfiles other Macs may share).
struct ClaudeStatusLineBridge: Sendable {
    enum BridgeError: Error, Equatable, LocalizedError {
        /// `settings.json` exists but isn't a JSON object; it is left untouched.
        case invalidSettings
        /// It sets `statusLine` more than once: Claude Code runs the last and Foundation reads the
        /// first, so editing either might not count.
        case duplicateStatusLine
        /// Changing only `statusLine` would mean rewriting the whole file: it isn't UTF-8 (UTF-16,
        /// say), or its JSON is lenient in a way the in-place edit doesn't follow, like a comma
        /// after the last setting.
        case unsupportedFormat
        /// It's a link to a file that isn't there.
        case brokenLink
        /// It (or `~/.claude`) links elsewhere, to dotfiles other Macs may share, where Tokenroom's
        /// script isn't: left for the user to change.
        case linked(target: String, command: String)
        /// The same, when turning the bridge off: its status line is for the user to remove.
        case linkedToRemove(target: String)
        /// The file or its folder can't be written.
        case notWritable

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                "Couldn't change ~/.claude/settings.json: it isn't valid JSON. Fix it, then try again."
            case .duplicateStatusLine:
                "Couldn't change ~/.claude/settings.json: it sets statusLine more than once. Keep one, then try again."
            case .unsupportedFormat:
                "Couldn't change ~/.claude/settings.json without rewriting it. Save it as UTF-8 with no comma after its last setting, then try again."
            case .brokenLink:
                "Couldn't change ~/.claude/settings.json: it links to a file that isn't there."
            case .linked(let target, let command):
                "Couldn't change ~/.claude/settings.json: it links to \(target), which other Macs may share, so Tokenroom leaves it alone. To use the bridge here, set its statusLine command to \(command) yourself."
            case .linkedToRemove(let target):
                "Couldn't change ~/.claude/settings.json: it links to \(target), which other Macs may share, so Tokenroom leaves it alone. Remove the statusLine that runs Tokenroom's script from it yourself."
            case .notWritable:
                "Couldn't change ~/.claude/settings.json: it's read-only. Check its permissions, then try again."
            }
        }
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

    /// The command Claude Code runs; quoted because the path has spaces.
    var command: String {
        "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Whether Claude Code runs the bridge: the status line is Tokenroom's and set only once
    /// (Claude Code runs the last of duplicates; Foundation reads the first).
    var isInstalled: Bool {
        guard let file = try? loadSettings(), isOurs(file.settings["statusLine"]) else { return false }
        let count = file.original.flatMap { Self.utf8Text($0) }.flatMap { JSONTextEdit.count(of: "statusLine", in: $0.text) }
        return (count ?? 1) == 1
    }

    func install() throws {
        let fileManager = FileManager.default
        try refuseLinks(turningOff: false)
        try refuseUnwritable()
        try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        removeFullBackups()
        var file = try loadSettings()
        let current = file.settings["statusLine"] as? [String: Any]
        // Other keys of a status line that was there (padding, say) stay.
        var statusLine = current ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        file.settings["statusLine"] = statusLine
        // Made and checked before anything is written, so a refused file stays as it was.
        let data = try Self.encoded(file)

        do {
            if !isOurs(current) {
                // What to chain now and restore later. Reinstalling keeps what was saved the first time.
                if let current {
                    try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: previousStatusLineURL, options: .atomic)
                    try Data(((current["command"] as? String) ?? "").utf8).write(to: previousCommandURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: previousStatusLineURL)
                    try? fileManager.removeItem(at: previousCommandURL)
                }
            }
            try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try fileManager.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.write(data, to: file.url)
        } catch {
            // Turned on only halfway: nothing refers to what was written, so it goes.
            if !isOurs(current) {
                for url in [scriptURL, previousCommandURL, previousStatusLineURL] {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }

    func uninstall() throws {
        removeFullBackups()
        var file = try loadSettings()
        if isOurs(file.settings["statusLine"]) {
            try refuseLinks(turningOff: true)
            try refuseUnwritable()
            if let data = try? Data(contentsOf: previousStatusLineURL),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                file.settings["statusLine"] = previous
            } else {
                file.settings.removeValue(forKey: "statusLine")
            }
            try Self.write(try Self.encoded(file), to: file.url)
        }
        // If the user changed the status line since, it stays; only Tokenroom's files go, the
        // copy of a link 2.0.0 kept included.
        for url in [scriptURL, readingURL, previousCommandURL, previousStatusLineURL] + backupURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Refuses a settings file kept elsewhere through a link (stow, home-manager, a Nix store),
    /// for `settings.json` or the `.claude` folder: other Macs may share it, and there
    /// Tokenroom's script isn't, so Claude Code's status line would break.
    private func refuseLinks(turningOff: Bool) throws {
        let fileManager = FileManager.default
        let target: URL
        if (try? fileManager.destinationOfSymbolicLink(atPath: settingsURL.path)) != nil {
            target = settingsURL.resolvingSymlinksInPath()
            // A link that doesn't resolve points at nothing (or loops).
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil || !fileManager.fileExists(atPath: target.path) {
                throw BridgeError.brokenLink
            }
        } else if (try? fileManager.destinationOfSymbolicLink(atPath: claudeDirectory.path)) != nil {
            let folder = claudeDirectory.resolvingSymlinksInPath()
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw BridgeError.brokenLink
            }
            target = folder.appendingPathComponent(settingsURL.lastPathComponent)
        } else {
            return
        }
        let shown = (target.path as NSString).abbreviatingWithTildeInPath
        throw turningOff ? BridgeError.linkedToRemove(target: shown) : BridgeError.linked(target: shown, command: command)
    }

    /// Refuses a settings file or folder this Mac can't write, before anything is written: an
    /// atomic write would otherwise replace a read-only file in a folder it can write to.
    private func refuseUnwritable() throws {
        let fileManager = FileManager.default
        for path in [settingsURL.path, claudeDirectory.path] where fileManager.fileExists(atPath: path) {
            guard fileManager.isWritableFile(atPath: path) else { throw BridgeError.notWritable }
        }
    }

    /// Writes `settings.json` in place, atomically, so it keeps its permissions; a read-only
    /// file or folder gets its own message.
    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as CocoaError where [.fileWriteNoPermission, .fileWriteVolumeReadOnly].contains(error.code) {
            throw BridgeError.notWritable
        } catch let error as CocoaError {
            if let posix = error.underlying as? POSIXError, [.EACCES, .EPERM, .EROFS].contains(posix.code) {
                throw BridgeError.notWritable
            }
            throw error
        }
    }

    /// Brings an installed bridge up to date after Tokenroom updates: the current script, and
    /// none of the full copies of `settings.json` that 2.0.0 kept. `settings.json` isn't touched.
    func upgrade() {
        removeFullBackups()
        let script = Data(Self.script.utf8)
        guard let installed = try? Data(contentsOf: scriptURL), installed != script else { return }
        try? script.write(to: scriptURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Tokenroom 2.0.0 kept full copies of `settings.json` here, keys in its `env` included:
    /// `settings.original.json` and up to five `settings.backup-….json`. They go, at launch and
    /// whenever the bridge changes. A copy that is a link holds no keys, only where a linked
    /// `settings.json` pointed before 2.0.0 replaced it with a file: it stays until the bridge
    /// is turned off, so Settings can say so (`replacedLink`).
    func removeFullBackups() {
        let fileManager = FileManager.default
        for url in backupURLs() where (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Where `settings.json` linked before Tokenroom 2.0.0 replaced the link with a file, when
    /// it did; nil once it's a link again.
    func replacedLink() -> String? {
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: settingsURL.path)) == nil,
              let destination = backupURLs().lazy.compactMap({ try? fileManager.destinationOfSymbolicLink(atPath: $0.path) }).first
        else { return nil }
        // A relative link was relative to ~/.claude, where it was.
        let path = destination.hasPrefix("/") ? destination : claudeDirectory.appendingPathComponent(destination).standardizedFileURL.path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// The note about a link 2.0.0 replaced was read: the copy of the link goes.
    func forgetReplacedLink() {
        let fileManager = FileManager.default
        for url in backupURLs() where (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try? fileManager.removeItem(at: url)
        }
    }

    private func backupURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bridgeDirectory.path)) ?? []
        return names
            .filter { $0 == "settings.original.json" || ($0.hasPrefix("settings.backup-") && $0.hasSuffix(".json")) }
            .sorted()
            .map { bridgeDirectory.appendingPathComponent($0) }
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

    /// `settings.json` as read, to be edited and written back to the same file.
    private struct SettingsFile {
        /// Where the file is; for a link, read to show whether the bridge is on, the file it
        /// points at (links are never edited).
        var url: URL
        /// The bytes an edit keeps; nil when the file is missing or blank.
        var original: Data?
        var settings: [String: Any]
    }

    /// Missing or blank settings read as empty; anything that isn't a JSON object is refused.
    private func loadSettings() throws -> SettingsFile {
        let url = settingsURL.resolvingSymlinksInPath()
        // A link that doesn't resolve points at nothing (or loops): refused, not replaced by a file.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw BridgeError.brokenLink
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsFile(url: url, original: nil, settings: [:]) }
        guard let data = try? Data(contentsOf: url) else { throw BridgeError.invalidSettings }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return SettingsFile(url: url, original: nil, settings: [:])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalidSettings
        }
        return SettingsFile(url: url, original: data, settings: object)
    }

    /// The bytes to write for `file.settings`: the file as the user wrote it with only
    /// `statusLine` changed, checked by reading it back. Every other byte stays, a UTF-8 BOM and
    /// CRLF line endings included. A missing or blank file is written fresh; one the edit can't
    /// handle is refused rather than rewritten. Written atomically, the file keeps its permissions.
    private static func encoded(_ file: SettingsFile) throws -> Data {
        guard let original = file.original else {
            return try JSONSerialization.data(withJSONObject: file.settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        guard let decoded = utf8Text(original), let count = JSONTextEdit.count(of: "statusLine", in: decoded.text) else {
            throw BridgeError.unsupportedFormat
        }
        guard count <= 1 else { throw BridgeError.duplicateStatusLine }
        let edited: String?
        if let statusLine = file.settings["statusLine"] {
            edited = JSONTextEdit.setting("statusLine", to: statusLine, in: decoded.text)
        } else {
            edited = JSONTextEdit.removing("statusLine", in: decoded.text)
        }
        guard let edited else { throw BridgeError.unsupportedFormat }
        let data = Data((decoded.hasBOM ? utf8BOM : []) + Array(edited.utf8))
        guard let check = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NSDictionary(dictionary: check).isEqual(to: file.settings)
        else { throw BridgeError.unsupportedFormat }
        return data
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The text an edit works on, without a UTF-8 BOM; nil when it isn't UTF-8. JSON in UTF-8
    /// never holds a raw NUL byte, and UTF-16 or UTF-32 text does.
    private static func utf8Text(_ data: Data) -> (text: String, hasBOM: Bool)? {
        let hasBOM = data.starts(with: utf8BOM)
        let body = data.dropFirst(hasBOM ? utf8BOM.count : 0)
        let text = String(decoding: body, as: UTF8.self)
        guard !body.contains(0), text.utf8.elementsEqual(body) else { return nil }
        return (text, hasBOM)
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
            // A project at the home folder shares the user settings file, which is ours; only its
            // settings.local.json can replace the bridge there. The path may reach the home
            // folder through a link or in another letter case.
            let names = Self.isSameFolder(folder, claudeDirectory) ? ["settings.local.json"] : ["settings.json", "settings.local.json"]
            for name in names {
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

    /// Whether two paths reach the same folder on disk, however they're spelled.
    private static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhs = lhs.resolvingSymlinksInPath()
        let rhs = rhs.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return lhs.standardizedFileURL == rhs.standardizedFileURL }
        return left.isEqual(right)
    }

    /// Saves only `rate_limits` (never session, folder, or transcript data), then runs the
    /// previous status line so its output is still what Claude Code shows. Rate limits without
    /// a used percentage (`{}`) leave the last reading in place.
    static let script = """
    #!/bin/sh
    # Written by Tokenroom. Saves only the rate limits Claude Code passes to its status line,
    # then runs the status line you had before. Turn it off in Tokenroom Settings.
    dir="$(dirname "$0")"
    input="$(cat)"
    tmp="$dir/.rate-limits.$$"
    if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$tmp" - >/dev/null 2>&1 &&
      { /usr/bin/plutil -extract seven_day.used_percentage raw -o - "$tmp" >/dev/null 2>&1 ||
        /usr/bin/plutil -extract five_hour.used_percentage raw -o - "$tmp" >/dev/null 2>&1; }; then
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

    /// Windows whose reset hasn't passed yet.
    func windows(now: Date = .now) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        if let weeklyUsed, (weeklyResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: JSONFlex.clampPercent(weeklyUsed), resetsAt: weeklyResetsAt, windowSeconds: 7 * 86_400))
        }
        if let sessionUsed, (sessionResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: JSONFlex.clampPercent(sessionUsed), resetsAt: sessionResetsAt, windowSeconds: 5 * 3_600))
        }
        return windows
    }

    /// Whether the reading has a weekly value whose reset has passed. The new week's use isn't
    /// known until Claude Code reports it, and the session shouldn't stand in for it meanwhile.
    func weeklyHasReset(now: Date = .now) -> Bool {
        guard weeklyUsed != nil, let weeklyResetsAt else { return false }
        return weeklyResetsAt <= now
    }

    /// The status line on its own, headlined by the weekly window like the direct read. Nil once
    /// that window has reset. A reading without a weekly value at all (Claude Code leaves out a
    /// window an account doesn't have) headlines its session.
    func snapshot(now: Date = .now) -> QuotaSnapshot? {
        guard !weeklyHasReset(now: now) else { return nil }
        let current = windows(now: now)
        guard let primary = current.first else { return nil }
        return QuotaSnapshot(
            provider: .claude,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt,
            fetchedAt: at,
            primaryTitle: primary.title,
            windows: current,
            source: "bridge"
        )
    }
}
