import Foundation
import LocalAuthentication
import os
import Security

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
        case .copilot:
            return CopilotCredentials.sessionStamp()
        case .antigravity:
            return AntigravityClient.sessionStamp()
        case .devin:
            return DevinCredentials.sessionStamp()
        case .zai, .kimiCode, .minimax, .opencodeGo:
            return pastedKeyStamp(provider) ?? LocalKeys.sourceFile(for: provider).flatMap(fileStamp)
        case .openrouter, .deepseek, .moonshot, .vercelGateway, .openaiOrg, .anthropicOrg, .xaiOrg:
            return pastedKeyStamp(provider)
        }
    }

    private static func pastedKeyStamp(_ provider: Provider) -> String? {
        apiKeys.metadata(for: provider).map { "\($0.last4)-\(Int($0.addedAt.timeIntervalSince1970))" }
    }

    /// Forgets cached tokens so the next read sees what the CLIs wrote since.
    /// The Keychain service list is cached separately (`invalidateKeychainServices`).
    static func invalidateCaches() {
        claudeCache.withLock { $0 = nil }
        cursorCache.withLock { $0 = nil }
        CopilotCredentials.invalidate()
    }

    static func invalidateKeychainServices() {
        claudeServicesCache.withLock { $0 = nil }
    }

    private static func fileStamp(_ url: URL) -> String? {
        LocalSources.fileStamp(url)
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

    /// A generic password through `/usr/bin/security`, for items another CLI created with it (gh
    /// through go-keyring, Claude Code): their access lists trust that tool, so no prompt.
    static func securityGenericPassword(service: String, account: String?) -> String? {
        securityPassword(service: service, account: account)
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

    /// A token Cursor already refused isn't a session to finish signing in with.
    static func hasUsableCursorSession() -> Bool {
        guard let token = try? cursorAccessToken() else { return false }
        return refusedCursorToken.withLock { $0 != fingerprint(token) }
    }

    /// Cursor's token: the Keychain first (Cursor 3.9 and later keep it there), then the older
    /// `state.vscdb`, which may still hold a token from before the move that no longer works. A
    /// Keychain token past its expiry gives way to a current one in the database, which an older
    /// Cursor still keeps up to date, and so does one Cursor refused before its expiry (revoked),
    /// until the Keychain holds another.
    static func cursorAccessToken(
        keychain: (String) -> String? = { keychainPassword(service: $0, promptAllowed: false) },
        database: URL = cursorDatabaseURL,
        usesCache: Bool = true,
        now: Date = .now
    ) throws -> String {
        if usesCache, let cached = cursorCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < 20 {
            return cached.token
        }
        let stored = keychain(cursorKeychainService).flatMap { $0.isEmpty ? nil : $0 }
        lastKeychainCursorToken.withLock { $0 = stored.map(fingerprint) }
        let refused = stored.map { stored in refusedCursorToken.withLock { $0 == fingerprint(stored) } } ?? false
        var token = stored
        if refused || stored.map({ tokenHasExpired($0, now: now) }) ?? true,
           let saved = LocalSources.vscodeState("cursorAuth/accessToken", database: database),
           stored == nil || !tokenHasExpired(saved, now: now) {
            token = saved
        }
        guard let token else { throw ProviderError.signedOut(Provider.cursor.signInHint) }
        if usesCache { cursorCache.withLock { $0 = (token, Date()) } }
        return token
    }

    /// After Cursor refused `refused`: the token in `state.vscdb` when it's a different one, which
    /// an older Cursor may keep working after the Keychain's was revoked. It's then the one
    /// reused for the usual 20 seconds, so Grok Bot's check right after doesn't try the refused
    /// one first.
    static func cursorTokenAfterRefusal(of refused: String, database: URL = cursorDatabaseURL, now: Date = .now) -> String? {
        // Only the Keychain's is remembered: it's the one that would otherwise go first again.
        if lastKeychainCursorToken.withLock({ $0 == fingerprint(refused) }) {
            refusedCursorToken.withLock { $0 = fingerprint(refused) }
        }
        guard let saved = LocalSources.vscodeState("cursorAuth/accessToken", database: database),
              saved != refused, !tokenHasExpired(saved, now: now)
        else { return nil }
        cursorCache.withLock { $0 = (saved, Date()) }
        return saved
    }

    /// The Keychain token Cursor last refused, as a fingerprint kept in memory only, so a revoked
    /// token doesn't cost a failing call before the database's on every check. Forgotten when
    /// the Keychain holds another token, or Tokenroom restarts.
    private static let refusedCursorToken = OSAllocatedUnfairLock<Int?>(initialState: nil)
    /// The Keychain token last read, likewise as a fingerprint.
    private static let lastKeychainCursorToken = OSAllocatedUnfairLock<Int?>(initialState: nil)

    private static func fingerprint(_ token: String) -> Int {
        var hasher = Hasher()
        hasher.combine(token)
        return hasher.finalize()
    }

    /// Whether a JWT's `exp` has passed. Nothing else in it is used; a token that isn't a JWT,
    /// or has no expiry, counts as current and is left to the server to judge.
    static func tokenHasExpired(_ token: String, now: Date = .now) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONFlex.object(from: data),
              let expiry = JSONFlex.number(claims["exp"])
        else { return false }
        return Date(timeIntervalSince1970: expiry) <= now
    }

    static let cursorKeychainService = "cursor-access-token"

    private static func cursorSessionStamp() -> String? {
        let db = fileStamp(cursorDatabaseURL)
        let wal = fileStamp(URL(fileURLWithPath: cursorDatabaseURL.path + "-wal"))
        if db == nil, wal == nil { return nil }
        return [db, wal].compactMap { $0 }.joined(separator: ":")
    }

    /// - Parameter promptAllowed: false fails quietly instead of asking for Keychain access,
    ///   for items another app owns that are polled every refresh.
    static func keychainPassword(service: String, account: String? = nil, promptAllowed: Bool = true) -> String? {
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
