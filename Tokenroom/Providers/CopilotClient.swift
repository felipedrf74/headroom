import Foundation
import Synchronization

/// GitHub Copilot's monthly quotas from `copilot_internal/user`, read with the GitHub login that
/// Copilot's editor extensions or the gh CLI already keep. Mac only: the endpoint is private.
struct CopilotClient: ProviderClient {
    let provider = Provider.copilot
    static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        guard let token = await BlockingIO.run({ CopilotCredentials.token() }) else {
            return .failure(.signedOut(provider.signInHint))
        }
        do {
            let data = try await TokenroomHTTP.get(Self.userURL, token: nil, headers: ["Authorization": "token \(token)"], provider: provider)
            return .success(try CopilotParser.snapshot(from: data))
        } catch let error as ProviderError {
            if case .expired = error {
                CopilotCredentials.invalidate()
            }
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}

/// Reads `copilot_internal/user`. The response also names the account and its organizations;
/// only the quota fields and the plan are read.
enum CopilotParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now, calendar: Calendar = .gregorianUTC) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let resetsAt = JSONFlex.date(root["quota_reset_date_utc"])
            ?? JSONFlex.date(root["quota_reset_date"])
            ?? JSONFlex.date(root["limited_user_reset_date"])
        let startsAt = resetsAt.flatMap { calendar.date(byAdding: .month, value: -1, to: $0) }

        var windows: [QuotaWindow] = []
        if let snapshots = JSONFlex.dictionary(root["quota_snapshots"]) {
            for (id, title, unit) in buckets {
                guard let bucket = JSONFlex.dictionary(snapshots[id]),
                      let window = window(bucket, id: id, title: title, unit: unit, resetsAt: resetsAt, startsAt: startsAt)
                else { continue }
                windows.append(window)
            }
        } else if let left = JSONFlex.dictionary(root["limited_user_quotas"]),
                  let limits = JSONFlex.dictionary(root["monthly_quotas"]) {
            // The older Free plan shape: what's left, and the monthly limits.
            for (id, title, unit) in buckets {
                guard let limit = JSONFlex.number(limits[id]), limit > 0, let remaining = JSONFlex.number(left[id]) else { continue }
                windows.append(QuotaWindow(
                    id: id, kind: .monthly, title: title,
                    usedPercent: JSONFlex.clampPercent((limit - remaining) / limit * 100),
                    resetsAt: resetsAt, startsAt: startsAt,
                    amount: QuotaAmount(used: limit - remaining, limit: limit, remaining: remaining, unit: unit)
                ))
            }
        }
        guard !windows.isEmpty else {
            throw ProviderError.notEntitled("Copilot didn't report a monthly quota for this account.")
        }
        return try .headlined(by: windows, provider: .copilot, fetchedAt: fetchedAt, planLabel: planLabel(root))
    }

    /// Premium requests lead when the plan has them.
    static let buckets: [(id: String, title: String, unit: String)] = [
        ("premium_interactions", "Premium requests", "requests"),
        ("chat", "Chat", "messages"),
        ("completions", "Completions", "completions"),
    ]

    /// Nil for unlimited buckets and for the zero placeholders org-managed seats report.
    static func window(_ bucket: [String: Any], id: String, title: String, unit: String, resetsAt: Date?, startsAt: Date?) -> QuotaWindow? {
        let entitlement = JSONFlex.number(bucket["entitlement"])
        let remaining = JSONFlex.number(bucket["remaining"]) ?? JSONFlex.number(bucket["quota_remaining"])
        if (bucket["unlimited"] as? Bool) == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        guard let entitlement, entitlement > 0 else { return nil }
        // Below zero once the plan allows overage and it's in use.
        let percentLeft = JSONFlex.number(bucket["percent_remaining"]) ?? remaining.map { $0 / entitlement * 100 }
        guard let percentLeft else { return nil }
        return QuotaWindow(
            id: id, kind: .monthly, title: title,
            usedPercent: JSONFlex.clampPercent(100 - percentLeft),
            resetsAt: resetsAt, startsAt: startsAt,
            amount: remaining.map { QuotaAmount(used: entitlement - $0, limit: entitlement, remaining: max($0, 0), unit: unit) }
        )
    }

    /// `access_type_sku` tells the plans apart; `copilot_plan` says "individual" even on Free.
    static func planLabel(_ root: [String: Any]) -> String? {
        let sku = JSONFlex.string(root["access_type_sku"])?.lowercased() ?? ""
        let plan = JSONFlex.string(root["copilot_plan"])?.lowercased() ?? ""
        let name: String? = if sku.contains("free") {
            "Free"
        } else if sku.contains("educat") {
            "Pro (Education)"
        } else if sku.contains("plus") || plan.contains("pro_plus") {
            "Pro+"
        } else if sku.contains("enterprise") || plan == "enterprise" {
            "Enterprise"
        } else if sku.contains("business") || plan == "business" {
            "Business"
        } else if sku.contains("subscriber") {
            "Pro"
        } else if !plan.isEmpty {
            plan.replacingOccurrences(of: "_", with: " ").capitalized
        } else {
            nil
        }
        return name.map { "Copilot \($0)" }
    }
}

/// The GitHub login Copilot can use, read in place: Copilot's own `apps.json`/`hosts.json`, then
/// the gh CLI's `hosts.yml`, then the gh token in the Keychain. github.com only, never refreshed.
enum CopilotCredentials {
    private static let cache = Mutex<(token: String, readAt: Date)?>(nil)
    static let cacheTTL: TimeInterval = 5 * 60

    static var configDirectory: URL {
        if let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !config.isEmpty {
            return URL(fileURLWithPath: config, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }

    static func token(configDirectory: URL = CopilotCredentials.configDirectory) -> String? {
        if let cached = cache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < cacheTTL {
            return cached.token
        }
        let token = copilotToken(configDirectory: configDirectory) ?? ghToken(configDirectory: configDirectory)
        if let token {
            cache.withLock { $0 = (token, Date()) }
        }
        return token
    }

    static func invalidate() {
        cache.withLock { $0 = nil }
    }

    /// Changes when a login is added or replaced. Only file dates and sizes, never the token.
    static func sessionStamp(configDirectory: URL = CopilotCredentials.configDirectory) -> String? {
        for file in ["github-copilot/apps.json", "github-copilot/hosts.json"] {
            let url = configDirectory.appendingPathComponent(file)
            if copilotToken(in: url) != nil, let stamp = LocalSources.fileStamp(url) {
                return stamp
            }
        }
        let hosts = configDirectory.appendingPathComponent("gh/hosts.yml")
        guard let text = try? String(contentsOf: hosts, encoding: .utf8), ghHost(text) != nil else { return nil }
        return LocalSources.fileStamp(hosts)
    }

    /// Copilot's editor extensions: `apps.json` keys look like `github.com:<app id>`, the older
    /// `hosts.json` uses `github.com`.
    static func copilotToken(configDirectory: URL) -> String? {
        ["github-copilot/apps.json", "github-copilot/hosts.json"].lazy
            .compactMap { copilotToken(in: configDirectory.appendingPathComponent($0)) }
            .first
    }

    static func copilotToken(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), let root = try? JSONFlex.object(from: data) else { return nil }
        for key in root.keys.sorted() where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = JSONFlex.string(JSONFlex.dictionary(root[key])?["oauth_token"]), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// gh keeps the token in `hosts.yml` (plain-text storage) or in the Keychain under
    /// `gh:github.com`, with the active user as the account.
    static func ghToken(configDirectory: URL) -> String? {
        let hosts = configDirectory.appendingPathComponent("gh/hosts.yml")
        guard let text = try? String(contentsOf: hosts, encoding: .utf8), let host = ghHost(text) else { return nil }
        if let token = host.token {
            return token
        }
        guard let stored = CredentialReaders.securityGenericPassword(service: "gh:github.com", account: host.user) else { return nil }
        return decodeKeyring(stored)
    }

    /// The `github.com:` block of gh's `hosts.yml`: the active `user`, and its `oauth_token` when
    /// gh stores tokens in the file. Tokens for other hosts (GitHub Enterprise) are ignored.
    static func ghHost(_ yaml: String) -> (user: String?, token: String?)? {
        var inHost = false
        var childIndent: Int?
        var user: String?
        var token: String?
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inHost = trimmed == "github.com:"
                childIndent = nil
                continue
            }
            guard inHost, let colon = trimmed.firstIndex(of: ":") else { continue }
            if childIndent == nil {
                childIndent = indent
            }
            // Only the host's own keys; entries under `users:` sit deeper.
            guard indent == childIndent else { continue }
            let key = trimmed[..<colon]
            let value = unquote(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if key == "user", !value.isEmpty {
                user = value
            } else if key == "oauth_token", !value.isEmpty {
                token = value
            }
        }
        guard user != nil || token != nil else { return nil }
        return (user, token)
    }

    /// go-keyring (gh's Keychain library) can wrap values as `go-keyring-base64:<base64>` or
    /// `go-keyring-encoded:<hex>`.
    static func decodeKeyring(_ value: String) -> String? {
        if value.hasPrefix("go-keyring-base64:") {
            return Data(base64Encoded: String(value.dropFirst("go-keyring-base64:".count))).flatMap { String(data: $0, encoding: .utf8) }
        }
        if value.hasPrefix("go-keyring-encoded:") {
            let hex = Array(value.dropFirst("go-keyring-encoded:".count).utf8)
            guard hex.count.isMultiple(of: 2) else { return nil }
            var bytes: [UInt8] = []
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(byte)
            }
            return String(bytes: bytes, encoding: .utf8)
        }
        return value.isEmpty ? nil : value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
