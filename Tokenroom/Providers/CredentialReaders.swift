import Foundation
import LocalAuthentication
import os
import Security
import SQLite3

/// Reads sessions that the official CLIs and apps already keep on this Mac.
/// Everything here is read-only: Tokenroom never refreshes or rewrites another tool's tokens.
/// These calls block (files, SQLite, `/usr/bin/security`); call them through `BlockingIO`.
enum CredentialReaders {
    static var grokHome: URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    static var grokAuthURL: URL {
        grokHome.appendingPathComponent("auth.json")
    }

    static var codexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var cursorDatabaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENROOM_CURSOR_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static var grokBotSupportURL: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENROOM_GROK_BOT_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot")
    }

    static var grokBotSecretsURL: URL {
        grokBotSupportURL.appendingPathComponent("sand-secrets.json")
    }

    static var grokBotStatusURL: URL {
        grokBotSupportURL.appendingPathComponent("desktop-status.json")
    }

    struct GrokAuth: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var userID: String?
    }

    struct CodexAuth: Sendable {
        var accessToken: String
        var accountID: String?
    }

    static func grokAuth() throws -> GrokAuth {
        let url = grokAuthURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        let data = try Data(contentsOf: url)
        let root = try JSONFlex.object(from: data)
        var newest: (entry: [String: Any], created: Date)?
        for value in root.values {
            guard let entry = JSONFlex.dictionary(value),
                  let access = JSONFlex.string(entry["key"]), !access.isEmpty
            else { continue }
            let created = JSONFlex.parseISO(JSONFlex.string(entry["create_time"]) ?? "") ?? .distantPast
            if newest == nil || created >= newest!.created {
                newest = (entry, created)
            }
        }
        guard let newest else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        return GrokAuth(
            accessToken: JSONFlex.string(newest.entry["key"]) ?? "",
            expiresAt: JSONFlex.parseISO(JSONFlex.string(newest.entry["expires_at"]) ?? ""),
            userID: JSONFlex.string(newest.entry["user_id"])
        )
    }

    /// The Grok CLI owns its refresh token (and may rotate it), so an expired token stays expired
    /// until `grok` itself refreshes it.
    static func usableGrokToken(_ auth: GrokAuth, now: Date = .now) throws -> String {
        guard !auth.accessToken.isEmpty else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSince(now) <= 60 {
            throw ProviderError.expired(Provider.grok.expiredHint)
        }
        return auth.accessToken
    }

    static func hasSession(_ provider: Provider) -> Bool {
        sessionStamp(provider) != nil
    }

    static func hasUsableSession(_ provider: Provider) -> Bool {
        switch provider {
        case .claude:
            guard let auth = try? claudeAuth() else { return false }
            return !auth.accessToken.isEmpty && !auth.isExpired
        case .grok:
            guard let auth = try? grokAuth() else { return false }
            return (try? usableGrokToken(auth)) != nil
        case .cursor, .grokBot:
            return hasUsableCursorSession()
        default:
            return hasSession(provider)
        }
    }

    /// Keys pasted in Settings on this Mac.
    static let apiKeys = APIKeyStore()

    static func sessionStamp(_ provider: Provider) -> String? {
        switch provider {
        case .grok:
            return fileStamp(grokAuthURL)
        case .openai:
            return fileStamp(codexHome.appendingPathComponent("auth.json"))
        case .cursor:
            return cursorSessionStamp()
        case .grokBot:
            let parts = [
                cursorSessionStamp(),
                fileStamp(grokBotSecretsURL),
                fileStamp(grokBotStatusURL),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "|")
        case .claude:
            guard let raw = readClaudeRawFromKeychain() else { return nil }
            let checksum = raw.utf8.reduce(into: 0) { sum, byte in sum = sum &+ Int(byte) }
            return "\(raw.count)-\(checksum)"
        case .openrouter, .deepseek, .moonshot, .vercelGateway:
            return apiKeys.metadata(for: provider).map { "\($0.last4)-\(Int($0.addedAt.timeIntervalSince1970))" }
        }
    }

    /// Forgets cached tokens so the next read sees what the CLIs wrote since.
    /// The Keychain service list is cached separately (`invalidateKeychainServices`).
    static func invalidateCaches() {
        claudeCache.withLock { $0 = nil }
        cursorCache.withLock { $0 = nil }
    }

    static func invalidateKeychainServices() {
        claudeServicesCache.withLock { $0 = nil }
    }

    private static func fileStamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate
        else { return nil }
        let size = values.fileSize ?? 0
        return "\(Int(modified.timeIntervalSince1970))-\(size)"
    }

    static func codexAuth() throws -> CodexAuth {
        let url = codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.signedOut(Provider.openai.signInHint)
        }
        let object = try JSONFlex.object(from: Data(contentsOf: url))
        let tokens = JSONFlex.dictionary(object["tokens"]) ?? [:]
        guard let access = JSONFlex.string(tokens["access_token"]), !access.isEmpty else {
            throw ProviderError.signedOut(Provider.openai.signInHint)
        }
        return CodexAuth(
            accessToken: access,
            accountID: JSONFlex.string(tokens["account_id"])
        )
    }

    struct ClaudeAuth: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMs: Double?
        var refreshExpiresAtMs: Double?
        var rawJSON: String
        var account: String
        var service: String

        var isExpired: Bool {
            guard let expiresAtMs else { return false }
            return Date().timeIntervalSince1970 * 1000 >= expiresAtMs - 60_000
        }

        /// Whether Claude Code can still refresh this session by itself. When it can't,
        /// Sign In starts a fresh `claude auth login`.
        var canRefresh: Bool {
            guard let refreshToken, !refreshToken.isEmpty else { return false }
            if let refreshExpiresAtMs {
                return Date().timeIntervalSince1970 * 1000 < refreshExpiresAtMs - 60_000
            }
            return true
        }
    }

    static let claudeKeychainService = "Claude Code-credentials"
    private static let keychainServicesTTL: TimeInterval = 600
    private static let claudeAgentTTL: TimeInterval = 3600

    private static let claudeCache = OSAllocatedUnfairLock<ClaudeAuth?>(initialState: nil)
    private static let claudeServicesCache = OSAllocatedUnfairLock<(names: [String], readAt: Date)?>(initialState: nil)
    private static let claudeAgentCache = OSAllocatedUnfairLock<(value: String, readAt: Date)?>(initialState: nil)
    private static let cursorCache = OSAllocatedUnfairLock<(token: String, readAt: Date)?>(initialState: nil)

    /// Claude's usage endpoint expects Claude Code's User-Agent. It is built from the installed
    /// CLI so the version doesn't go stale.
    static func claudeUserAgent() -> String {
        if let cached = claudeAgentCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < claudeAgentTTL {
            return cached.value
        }
        let value = claudeUserAgent(forCLI: Tooling.resolveClaude())
        claudeAgentCache.withLock { $0 = (value, Date()) }
        return value
    }

    static func claudeUserAgent(forCLI cli: URL?) -> String {
        if let version = cli.flatMap(claudeVersion(of:)) {
            return "claude-cli/\(version) (external, cli)"
        }
        return "claude-cli (external, cli)"
    }

    /// Version from the CLI's install path (`…/versions/2.1.280` or `…/claude-code/2.1.280/…`).
    static func claudeVersion(of cli: URL) -> String? {
        cli.resolvingSymlinksInPath().pathComponents.reversed().first(where: isVersionString)
    }

    private static func isVersionString(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    static func claudeAuth() throws -> ClaudeAuth {
        if let cached = claudeCache.withLock({ $0 }), !cached.isExpired {
            return cached
        }
        let account = NSUserName()
        if let found = readBestClaudeCredential(account: account) {
            claudeCache.withLock { $0 = found.auth }
            return found.auth
        }
        claudeCache.withLock { $0 = nil }
        throw ProviderError.signedOut(Provider.claude.signInHint)
    }

    private static func readClaudeRawFromKeychain() -> String? {
        readBestClaudeCredential(account: NSUserName())?.auth.rawJSON
    }

    private static func readBestClaudeCredential(account: String) -> (raw: String, auth: ClaudeAuth)? {
        var best: (raw: String, auth: ClaudeAuth)?
        for service in claudeCredentialServices() {
            guard let raw = securityPassword(service: service, account: account)
                ?? securityPassword(service: service, account: nil)
                ?? keychainPassword(service: service, account: account)
                ?? keychainPassword(service: service)
            else { continue }
            guard let auth = try? parseClaudeAuth(raw, account: account, service: service) else { continue }
            if best == nil || claudeAuthIsBetter(auth, than: best!.auth) {
                best = (raw, auth)
            }
        }
        return best
    }

    private static func claudeAuthIsBetter(_ candidate: ClaudeAuth, than current: ClaudeAuth) -> Bool {
        func rank(_ auth: ClaudeAuth) -> Int {
            if !auth.accessToken.isEmpty, !auth.isExpired { return 3 }
            if auth.canRefresh { return 2 }
            if !auth.accessToken.isEmpty { return 1 }
            return 0
        }
        let candidateRank = rank(candidate)
        let currentRank = rank(current)
        if candidateRank != currentRank { return candidateRank > currentRank }
        return (candidate.expiresAtMs ?? 0) > (current.expiresAtMs ?? 0)
    }

    /// Keychain services Claude Code uses: `Claude Code-credentials` and `Claude Code-credentials-…`.
    /// Listing attributes never prompts and never reads secrets.
    private static func claudeCredentialServices() -> [String] {
        if let cached = claudeServicesCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < keychainServicesTTL {
            return cached.names
        }
        var names = Set<String>([claudeKeychainService])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let service = item[kSecAttrService as String] as? String else { continue }
                if service == claudeKeychainService || service.hasPrefix("\(claudeKeychainService)-") {
                    names.insert(service)
                }
            }
        }
        let list = names.sorted()
        claudeServicesCache.withLock { $0 = (list, Date()) }
        return list
    }

    private static func securityPassword(service: String, account: String?) -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account {
            args.insert(contentsOf: ["-a", account], at: 3)
        }
        guard let output = securityRun(args) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func securityRun(_ args: [String]) -> String? {
        let output = BlockingIO.runProcess(URL(fileURLWithPath: "/usr/bin/security"), arguments: args)
        guard output.succeeded else { return nil }
        return String(data: output.stdout, encoding: .utf8)
    }

    static func hasUsableCursorSession() -> Bool {
        (try? cursorAccessToken()) != nil
    }

    static func cursorAccessToken() throws -> String {
        if let cached = cursorCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < 20 {
            return cached.token
        }
        let path = cursorDatabaseURL.path
        if FileManager.default.fileExists(atPath: path) {
            if let token = sqliteCursorToken(at: path) {
                cursorCache.withLock { $0 = (token, Date()) }
                return token
            }
            // A busy database can refuse a read-only open; a copy can still be read.
            if let copy = copyCursorDatabase() {
                defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                if let token = sqliteCursorToken(at: copy.path) {
                    cursorCache.withLock { $0 = (token, Date()) }
                    return token
                }
            }
        }
        // Cursor 3.9 and later keep the token in the Keychain instead.
        if let token = keychainPassword(service: cursorKeychainService, promptAllowed: false), !token.isEmpty {
            cursorCache.withLock { $0 = (token, Date()) }
            return token
        }
        throw ProviderError.signedOut(Provider.cursor.signInHint)
    }

    static let cursorKeychainService = "cursor-access-token"

    private static func cursorSessionStamp() -> String? {
        let db = fileStamp(cursorDatabaseURL)
        let wal = fileStamp(URL(fileURLWithPath: cursorDatabaseURL.path + "-wal"))
        if db == nil, wal == nil { return nil }
        return [db, wal].compactMap { $0 }.joined(separator: ":")
    }

    private static func sqliteCursorToken(at path: String) -> String? {
        var database: OpaquePointer?
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?"))) ?? path
        let uri = "file://\(encoded)?mode=ro"
        let uriFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(uri, &database, uriFlags, nil) != SQLITE_OK {
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

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let token = String(cString: bytes)
        return token.isEmpty ? nil : token
    }

    private static func copyCursorDatabase() -> URL? {
        let src = cursorDatabaseURL
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenroomCursor-\(UUID().uuidString)", isDirectory: true)
        let dest = folder.appendingPathComponent("state.vscdb")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dest)
            for suffix in ["-wal", "-shm"] {
                let extra = URL(fileURLWithPath: src.path + suffix)
                if FileManager.default.fileExists(atPath: extra.path) {
                    try FileManager.default.copyItem(at: extra, to: URL(fileURLWithPath: dest.path + suffix))
                }
            }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// - Parameter promptAllowed: false fails quietly instead of asking for Keychain access,
    ///   for items another app owns that are polled every refresh.
    private static func keychainPassword(service: String, account: String? = nil, promptAllowed: Bool = true) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !promptAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseClaudeAuth(_ raw: String, account: String, service: String) throws -> ClaudeAuth {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            let object = try JSONFlex.object(from: data)
            let nested = JSONFlex.dictionary(object["claudeAiOauth"]) ?? object
            guard let token = JSONFlex.string(nested["accessToken"]) ?? JSONFlex.string(nested["access_token"]),
                  !token.isEmpty
            else {
                throw ProviderError.signedOut(Provider.claude.signInHint)
            }
            return ClaudeAuth(
                accessToken: token,
                refreshToken: JSONFlex.string(nested["refreshToken"]) ?? JSONFlex.string(nested["refresh_token"]),
                expiresAtMs: JSONFlex.number(nested["expiresAt"]) ?? JSONFlex.number(nested["expires_at"]),
                refreshExpiresAtMs: JSONFlex.number(nested["refreshTokenExpiresAt"])
                    ?? JSONFlex.number(nested["refresh_token_expires_at"]),
                rawJSON: trimmed,
                account: account,
                service: service
            )
        }
        if !trimmed.isEmpty {
            return ClaudeAuth(
                accessToken: trimmed,
                refreshToken: nil,
                expiresAtMs: nil,
                refreshExpiresAtMs: nil,
                rawJSON: trimmed,
                account: account,
                service: service
            )
        }
        throw ProviderError.signedOut(Provider.claude.signInHint)
    }

    static func parseClaudeToken(_ raw: String) throws -> String {
        try parseClaudeAuth(raw, account: NSUserName(), service: claudeKeychainService).accessToken
    }
}
