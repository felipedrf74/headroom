import Foundation

/// Devin Desktop's (formerly Windsurf) weekly and daily quotas from `GetUserStatus`, read with the
/// API key the Devin CLI or app already keeps. Mac only: the endpoint is private.
struct DevinClient: ProviderClient {
    let provider = Provider.devin
    static let defaultServer = URL(string: "https://server.codeium.com")!
    static let statusPath = "exa.seat_management_pb.SeatManagementService/GetUserStatus"

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let credentials = await BlockingIO.run { DevinCredentials.all() }
        guard !credentials.isEmpty else {
            return .failure(.signedOut(provider.signInHint))
        }
        var failure = ProviderError.expired(provider.expiredHint)
        for credential in credentials {
            do {
                let data = try await TokenroomHTTP.post(
                    credential.server.appendingPathComponent(Self.statusPath),
                    token: nil,
                    headers: ["Connect-Protocol-Version": "1"],
                    body: DevinParser.requestBody(apiKey: credential.apiKey),
                    provider: provider
                )
                return .success(try DevinParser.snapshot(from: data))
            } catch ProviderError.expired(let hint) {
                // The CLI and the app can hold different keys; one may still be current.
                failure = .expired(hint)
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(.unreachable)
            }
        }
        return .failure(failure)
    }
}

enum DevinParser {
    /// The metadata Devin's own client sends with its key. Tokenroom's User-Agent stays its own.
    static func requestBody(apiKey: String) -> Data {
        let metadata: [String: String] = [
            "apiKey": apiKey,
            "ideName": "devin",
            "ideVersion": "1.108.2",
            "extensionName": "devin",
            "extensionVersion": "1.108.2",
            "locale": "en",
        ]
        return (try? JSONSerialization.data(withJSONObject: ["metadata": metadata], options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let plan = JSONFlex.dictionary(JSONFlex.dictionary(root["userStatus"])?["planStatus"]) else {
            throw ProviderError.parse
        }
        let info = JSONFlex.dictionary(plan["planInfo"])
        let hidesDaily = (info?["hideDailyQuota"] as? Bool) == true
        let weekly = try reading(plan, percent: "weeklyQuotaRemainingPercent", reset: "weeklyQuotaResetAtUnix")
        let daily = try reading(plan, percent: "dailyQuotaRemainingPercent", reset: "dailyQuotaResetAtUnix")

        var windows: [QuotaWindow] = []
        if let weekly {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: weekly.used, resetsAt: weekly.reset, windowSeconds: 7 * 86_400))
        }
        if let daily {
            if weekly == nil, hidesDaily {
                // Plans that hide the daily quota report their only quota there.
                windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: daily.used, resetsAt: daily.reset))
            } else if !hidesDaily {
                windows.append(QuotaWindow(id: "daily", kind: .daily, title: "Today", usedPercent: daily.used, resetsAt: daily.reset, windowSeconds: 86_400))
            }
        }
        guard !windows.isEmpty else {
            throw ProviderError.notEntitled("Devin didn't report usage limits for this plan.")
        }
        let overage = JSONFlex.number(plan["overageBalanceMicros"]).map { $0 / 1_000_000 }
        return try .headlined(
            by: windows,
            provider: .devin,
            fetchedAt: fetchedAt,
            planLabel: JSONFlex.string(info?["planName"]).flatMap { $0.isEmpty ? nil : $0 },
            extra: overage.flatMap { $0 > 0 ? ExtraUsage(title: "Overage balance", amount: QuotaAmount(remaining: $0, unit: "usd")) : nil }
        )
    }

    /// Remaining percent, as used. Proto3 JSON leaves out zeros, so a reset time without a percent
    /// means nothing is left. A percent that isn't a number is a changed schema, not "exhausted".
    static func reading(_ plan: [String: Any], percent: String, reset: String) throws -> (used: Double, reset: Date?)? {
        let resetsAt = JSONFlex.date(plan[reset])
        if let raw = plan[percent] {
            guard let remaining = JSONFlex.number(raw) else { throw ProviderError.parse }
            return (JSONFlex.clampPercent(100 - remaining), resetsAt)
        }
        return resetsAt.map { (100, $0) }
    }
}

/// Where Devin keeps its key: the CLI's `credentials.toml`, then the Devin app's state database,
/// then older Windsurf installs. Read-only; nothing is refreshed.
enum DevinCredentials {
    struct Credential: Equatable {
        var apiKey: String
        var server: URL
    }

    static var cliCredentials: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/credentials.toml")
    }

    static var appDatabases: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ["Devin", "Windsurf", "Windsurf - Next"].map {
            support.appendingPathComponent("\($0)/User/globalStorage/state.vscdb")
        }
    }

    /// Every distinct key, CLI first.
    static func all(cliCredentials: URL = DevinCredentials.cliCredentials, appDatabases: [URL] = DevinCredentials.appDatabases) -> [Credential] {
        var found: [Credential] = []
        if let text = try? String(contentsOf: cliCredentials, encoding: .utf8) {
            let values = tomlStrings(text)
            if let key = values["windsurf_api_key"], !key.isEmpty {
                // A custom server only over https.
                let server = values["api_server_url"].flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                found.append(Credential(apiKey: key, server: server ?? DevinClient.defaultServer))
            }
        }
        for database in appDatabases {
            guard let raw = LocalSources.vscodeState("windsurfAuthStatus", database: database),
                  let object = try? JSONFlex.object(from: Data(raw.utf8)),
                  let key = JSONFlex.string(object["apiKey"]), !key.isEmpty,
                  !found.contains(where: { $0.apiKey == key })
            else { continue }
            found.append(Credential(apiKey: key, server: DevinClient.defaultServer))
        }
        return found
    }

    /// Changes when a key is added or replaced. File dates and sizes only.
    static func sessionStamp() -> String? {
        guard !all().isEmpty else { return nil }
        let stamps = ([cliCredentials] + appDatabases.flatMap { [$0, URL(fileURLWithPath: $0.path + "-wal")] })
            .compactMap(LocalSources.fileStamp)
        return stamps.isEmpty ? nil : stamps.joined(separator: "|")
    }

    /// Top-level `key = "value"` pairs; enough for the CLI's flat credentials file.
    static func tomlStrings(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
