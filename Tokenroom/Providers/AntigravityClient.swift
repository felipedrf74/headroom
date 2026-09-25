import Foundation
import LocalAuthentication
import Security

/// Antigravity's Gemini and other-model windows, from `agy -p /usage --output-format json`.
/// agy 1.1.11 added `/usage` as a local command; older versions send it to the model as a prompt,
/// which spends quota, so they're never run with it. Mac only.
struct AntigravityClient: ProviderClient {
    let provider = Provider.antigravity
    static let minimumVersion = [1, 1, 11]

    /// agy starts its own services before answering, so it gets longer than an HTTP call.
    var fetchBudget: TimeInterval { 35 }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        await BlockingIO.run { Self.read() }
    }

    static func read(now: Date = .now) -> Result<QuotaSnapshot, ProviderError> {
        guard let agy = Tooling.resolve("agy") else {
            return .failure(hasLogin()
                ? .notEntitled("Install the agy CLI, 1.1.11 or later, to see Antigravity usage.")
                : .signedOut(Provider.antigravity.signInHint))
        }
        let versionOutput = BlockingIO.runProcess(agy, arguments: ["--version"], timeout: 5)
        guard versionOutput.succeeded,
              let version = LocalSources.semanticVersion(in: String(decoding: versionOutput.stdout, as: UTF8.self)),
              LocalSources.version(version, isAtLeast: minimumVersion)
        else {
            return .failure(.notEntitled("Update agy to 1.1.11 or later to see Antigravity usage."))
        }
        guard let data = LocalSources.runJSONCommand(
            agy,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "25s"],
            timeout: 30,
            maxOutput: 1 << 20
        ) else {
            return .failure(hasLogin() ? .unreachable : .signedOut(Provider.antigravity.signInHint))
        }
        do {
            return .success(try AntigravityParser.snapshot(from: data, fetchedAt: now))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.parse)
        }
    }

    /// The login Antigravity and agy share. Only its attributes are read, never the token.
    static func loginAttributes() -> [String: Any]? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? [String: Any]
    }

    static func hasLogin() -> Bool {
        loginAttributes() != nil
    }

    /// Changes when Antigravity signs in again: the item's modification date.
    static func sessionStamp() -> String? {
        guard let attributes = loginAttributes() else { return nil }
        let modified = (attributes[kSecAttrModificationDate as String] as? Date)?.timeIntervalSince1970 ?? 0
        return "antigravity-\(Int(modified))"
    }
}

/// Reads agy's `/usage` JSON, and the same groups as Antigravity's own servers spell them.
enum AntigravityParser {
    static let known: [String: (kind: WindowKind, title: String, seconds: Double)] = [
        "gemini-weekly": (.weekly, "Gemini weekly", 7 * 86_400),
        "gemini-5h": (.session, "Gemini session", 5 * 3600),
        "3p-weekly": (.weekly, "Other models weekly", 7 * 86_400),
        "3p-5h": (.session, "Other models session", 5 * 3600),
    ]
    static let order = ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"]

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        if let status = JSONFlex.string(root["status"]), status != "SUCCESS" {
            throw failure(root)
        }
        // agy wraps the groups in `command.data`; the local server in `response`.
        let body = JSONFlex.dictionary(JSONFlex.dictionary(root["command"])?["data"])
            ?? JSONFlex.dictionary(root["response"])
            ?? root
        guard let groups = JSONFlex.array(body["groups"]) else { throw ProviderError.parse }

        var byID: [String: QuotaWindow] = [:]
        var others: [QuotaWindow] = []
        for group in groups.compactMap(JSONFlex.dictionary) {
            let groupName = JSONFlex.string(group["name"]) ?? JSONFlex.string(group["displayName"])
            for bucket in (JSONFlex.array(group["buckets"]) ?? []).compactMap(JSONFlex.dictionary) {
                guard (bucket["disabled"] as? Bool) != true,
                      let fraction = remainingFraction(bucket)  // Unknown stays unknown: never 0% or 100%.
                else { continue }
                let id = JSONFlex.string(bucket["id"]) ?? JSONFlex.string(bucket["bucketId"]) ?? ""
                let used = JSONFlex.clampPercent((1 - fraction) * 100)
                let reset = JSONFlex.date(bucket["reset_time"]) ?? JSONFlex.date(bucket["resetTime"])
                if let spec = known[id] {
                    byID[id] = QuotaWindow(id: id, kind: spec.kind, title: spec.title, usedPercent: used, resetsAt: reset, windowSeconds: spec.seconds)
                } else {
                    let window = JSONFlex.string(bucket["window"])
                    let kind: WindowKind = window == "5h" ? .session : window == "weekly" ? .weekly : .pool
                    let name = JSONFlex.string(bucket["name"]) ?? JSONFlex.string(bucket["displayName"]) ?? id
                    others.append(QuotaWindow(
                        id: id.isEmpty ? "bucket-\(others.count)" : id,
                        kind: kind,
                        title: [groupName, window].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? name,
                        usedPercent: used,
                        resetsAt: reset
                    ))
                }
            }
        }
        // Accounts that report per-model buckets instead of the known groups still show something.
        let windows = order.compactMap { byID[$0] }.nilIfEmpty ?? others
        guard !windows.isEmpty else { throw ProviderError.parse }
        return try .headlined(by: windows, provider: .antigravity, fetchedAt: fetchedAt)
    }

    /// `remaining_fraction` (agy), `remainingFraction` (servers), or nested under `remaining`.
    static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        if let value = JSONFlex.number(bucket["remaining_fraction"]) ?? JSONFlex.number(bucket["remainingFraction"]) {
            return value
        }
        guard let nested = JSONFlex.dictionary(bucket["remaining"]) else { return nil }
        if let value = JSONFlex.number(nested["remainingFraction"]) {
            return value
        }
        return JSONFlex.string(nested["case"]) == "remainingFraction" ? JSONFlex.number(nested["value"]) : nil
    }

    static func failure(_ root: [String: Any]) -> ProviderError {
        let message = [root["error"], root["message"], JSONFlex.dictionary(root["error"])?["message"]]
            .compactMap(JSONFlex.string)
            .joined(separator: " ")
            .lowercased()
        if message.contains("not logged in") || message.contains("not signed in") || message.contains("sign in") {
            return .signedOut(Provider.antigravity.signInHint)
        }
        if message.contains("not eligible") || message.contains("unsupported country") {
            return .notEntitled("Antigravity isn't available for this account.")
        }
        return .parse
    }
}

private extension Collection {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
