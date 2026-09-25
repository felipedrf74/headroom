import Foundation
import os
import Security
import SQLite3

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

    struct GrokAuth {
        var mapKey: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var clientID: String?
        var userID: String?
        var root: [String: Any]
    }

    struct CodexAuth {
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
        var newest: (key: String, entry: [String: Any], created: Date)?
        for (key, value) in root {
            guard let entry = JSONFlex.dictionary(value),
                  let access = JSONFlex.string(entry["key"]), !access.isEmpty
            else { continue }
            let created = JSONFlex.parseISO(JSONFlex.string(entry["create_time"]) ?? "") ?? .distantPast
            if newest == nil || created >= newest!.created {
                newest = (key, entry, created)
            }
        }
        guard let newest else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        return GrokAuth(
            mapKey: newest.key,
            accessToken: JSONFlex.string(newest.entry["key"]) ?? "",
            refreshToken: JSONFlex.string(newest.entry["refresh_token"]),
            expiresAt: JSONFlex.parseISO(JSONFlex.string(newest.entry["expires_at"]) ?? ""),
            clientID: JSONFlex.string(newest.entry["oidc_client_id"]),
            userID: JSONFlex.string(newest.entry["user_id"]),
            root: root
        )
    }

    static func writeGrokAccessToken(_ token: String, expiresAt: Date?, into auth: GrokAuth) throws {
        var root = auth.root
        guard var entry = JSONFlex.dictionary(root[auth.mapKey]) else { return }
        entry["key"] = token
        if let expiresAt {
            entry["expires_at"] = JSONFlex.isoString(from: expiresAt)
        }
        root[auth.mapKey] = entry
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: grokAuthURL, options: .atomic)
    }

    static func hasSession(_ provider: Provider) -> Bool {
        sessionStamp(provider) != nil
    }

    static func hasUsableSession(_ provider: Provider) -> Bool {
        switch provider {
        case .claude:
            if claudeRefreshRejected.withLock({ $0 }) { return false }
            guard let auth = try? claudeAuth() else { return false }
            return !auth.accessToken.isEmpty && (!auth.isExpired || auth.canRefresh)
        case .cursor, .grokBot:
            return hasUsableCursorSession()
        default:
            return hasSession(provider)
        }
    }

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
        }
    }

    static func invalidateCaches() {
        claudeCache.withLock { $0 = nil }
        claudeServicesCache.withLock { $0 = nil }
        cursorCache.withLock { $0 = nil }
    }

    private static func fileStamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate
        else { return nil }
        let size = values.fileSize ?? 0
        return "\(Int(modified.timeIntervalSince1970))-\(size)"
    }

    static func refreshGrokIfNeeded(_ auth: GrokAuth) async throws -> String {
        if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSinceNow > 120 {
            return auth.accessToken
        }
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty,
              let clientID = auth.clientID, !clientID.isEmpty
        else {
            if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSinceNow <= 0 {
                throw ProviderError.expired(Provider.grok.expiredHint)
            }
            return auth.accessToken
        }

        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TokenroomHTTP.timeout
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        .map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await TokenroomHTTP.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.expired(Provider.grok.expiredHint)
            }
            if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSinceNow > 0 {
                return auth.accessToken
            }
            throw ProviderError.expired(Provider.grok.expiredHint)
        }
        let object = try JSONFlex.object(from: data)
        guard let access = JSONFlex.string(object["access_token"]), !access.isEmpty else {
            throw ProviderError.expired(Provider.grok.expiredHint)
        }
        let expiresAt: Date?
        if let seconds = JSONFlex.number(object["expires_in"]) {
            expiresAt = Date().addingTimeInterval(seconds)
        } else {
            expiresAt = nil
        }
        try writeGrokAccessToken(access, expiresAt: expiresAt, into: auth)
        return access
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

        var canRefresh: Bool {
            guard let refreshToken, !refreshToken.isEmpty else { return false }
            if let refreshExpiresAtMs {
                return Date().timeIntervalSince1970 * 1000 < refreshExpiresAtMs - 60_000
            }
            return true
        }
    }

    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let claudeKeychainService = "Claude Code-credentials"

    static func claudeUserAgent() -> String {
        "claude-cli/2.1.259 (external, cli)"
    }

    private static let claudeCache = OSAllocatedUnfairLock<ClaudeAuth?>(initialState: nil)
    private static let claudeServicesCache = OSAllocatedUnfairLock<[String]?>(initialState: nil)
    private static let claudeRefreshRejected = OSAllocatedUnfairLock(initialState: false)
    private static let cursorCache = OSAllocatedUnfairLock<(token: String, readAt: Date)?>(initialState: nil)

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

    private static func claudeCredentialServices() -> [String] {
        if let cached = claudeServicesCache.withLock({ $0 }) {
            return cached
        }
        var names = Set<String>([claudeKeychainService])
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let service = item[kSecAttrService as String] as? String else { continue }
                if service == claudeKeychainService || service.hasPrefix("Claude Code-credentials-") {
                    names.insert(service)
                }
            }
        }
        if names.count == 1, let dump = securityRun(["dump-keychain"]) {
            for line in dump.split(separator: "\n") where line.contains("Claude Code-credentials") {
                guard let range = line.range(of: "Claude Code-credentials") else { continue }
                let tail = line[range.lowerBound...]
                let name = tail.prefix { $0 != "\"" }
                if !name.isEmpty {
                    names.insert(String(name))
                }
            }
        }
        let list = names.sorted()
        claudeServicesCache.withLock { $0 = list }
        return list
    }

    static func claudeAccessToken() throws -> String {
        try claudeAuth().accessToken
    }

    static func refreshClaudeIfNeeded(_ auth: ClaudeAuth) async throws -> String {
        if !auth.isExpired, !auth.accessToken.isEmpty {
            return auth.accessToken
        }
        guard auth.canRefresh, let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            throw ProviderError.expired(Provider.claude.expiredHint)
        }

        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeClientID,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let urls = [
            URL(string: "https://platform.claude.com/v1/oauth/token")!,
            URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        ]
        var refreshed: [String: Any]?
        var sawNetworkFailure = false
        var sawRejectedGrant = false
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(claudeUserAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.timeoutInterval = TokenroomHTTP.timeout
            do {
                let (data, response) = try await TokenroomHTTP.data(for: request)
                if (200..<300).contains(response.statusCode) {
                    refreshed = try JSONFlex.object(from: data)
                    break
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    sawRejectedGrant = true
                    continue
                }
                if response.statusCode == 400,
                   let object = try? JSONFlex.object(from: data),
                   (JSONFlex.string(object["error"]) ?? "").contains("invalid_grant") {
                    sawRejectedGrant = true
                    claudeRefreshRejected.withLock { $0 = true }
                    continue
                }
                sawNetworkFailure = true
            } catch {
                sawNetworkFailure = true
            }
        }
        guard let object = refreshed,
              let access = JSONFlex.string(object["access_token"]), !access.isEmpty
        else {
            if sawRejectedGrant {
                throw ProviderError.expired(Provider.claude.expiredHint)
            }
            throw ProviderError.unreachable
        }
        let newRefresh = JSONFlex.string(object["refresh_token"])
        let expiresIn = JSONFlex.number(object["expires_in"]) ?? 28_800
        let updated = try applyingClaudeRefresh(
            to: auth.rawJSON,
            accessToken: access,
            refreshToken: newRefresh,
            expiresIn: expiresIn
        )
        writeClaudeKeychain(updated, account: auth.account, service: auth.service)
        if let refreshed = try? parseClaudeAuth(updated, account: auth.account, service: auth.service) {
            claudeCache.withLock { $0 = refreshed }
        }
        return access
    }

    static func applyingClaudeRefresh(
        to rawJSON: String,
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval,
        now: Date = .now
    ) throws -> String {
        guard let data = rawJSON.data(using: .utf8) else {
            throw ProviderError.parse
        }
        var object = try JSONFlex.object(from: data)
        var oauth = JSONFlex.dictionary(object["claudeAiOauth"]) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        object["claudeAiOauth"] = oauth
        let updated = try JSONSerialization.data(withJSONObject: object)
        return String(data: updated, encoding: .utf8) ?? rawJSON
    }

    private static func writeClaudeKeychain(_ json: String, account: String, service: String) {
        _ = securityRun([
            "add-generic-password",
            "-a", account,
            "-s", service,
            "-w", json,
            "-U",
        ])
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func hasUsableCursorSession() -> Bool {
        (try? cursorAccessToken()) != nil
    }

    static func cursorAccessToken() throws -> String {
        if let cached = cursorCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < 20 {
            return cached.token
        }
        let path = cursorDatabaseURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError.signedOut(Provider.cursor.signInHint)
        }
        if let token = sqliteCursorToken(at: path) {
            cursorCache.withLock { $0 = (token, Date()) }
            return token
        }
        if let copy = copyCursorDatabase() {
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            if let token = sqliteCursorToken(at: copy.path) {
                cursorCache.withLock { $0 = (token, Date()) }
                return token
            }
        }
        throw ProviderError.signedOut(Provider.cursor.signInHint)
    }

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

    private static func keychainPassword(service: String, account: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
