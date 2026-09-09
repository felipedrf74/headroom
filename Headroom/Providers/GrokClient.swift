import Foundation

enum GrokParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let config = JSONFlex.dictionary(root["config"]) ?? root
        let period = JSONFlex.dictionary(config["currentPeriod"])
        let periodType = JSONFlex.string(period?["type"]) ?? ""
        let isWeekly = periodType.contains("WEEKLY")

        let usedPercent: Double
        if let percent = JSONFlex.number(config["creditUsagePercent"]) {
            usedPercent = JSONFlex.clampPercent(percent)
        } else if let used = JSONFlex.cent(config["used"]),
                  let limit = JSONFlex.cent(config["monthlyLimit"]), limit > 0 {
            usedPercent = JSONFlex.clampPercent(used / limit * 100)
        } else if period != nil || (config["isUnifiedBillingUser"] as? Bool) == true {
            usedPercent = 0
        } else {
            throw ProviderError.parse
        }

        let resetsAt = JSONFlex.date(period?["end"])
            ?? JSONFlex.date(config["billingPeriodEnd"])
        let title = isWeekly ? "Weekly" : "This cycle"
        let kind: WindowKind = isWeekly ? .weekly : .billingCycle

        var windows = [
            QuotaWindow(
                id: "primary",
                kind: kind,
                title: title,
                usedPercent: usedPercent,
                resetsAt: resetsAt
            ),
        ]

        if let cap = JSONFlex.cent(config["onDemandCap"]), cap > 0 {
            let used = JSONFlex.cent(config["onDemandUsed"]) ?? 0
            let extraPercent = JSONFlex.clampPercent(used / cap * 100)
            windows.append(
                QuotaWindow(
                    id: "on-demand",
                    kind: .pool,
                    title: "Extra",
                    usedPercent: extraPercent,
                    resetsAt: resetsAt
                )
            )
        }

        return QuotaSnapshot(
            provider: .grok,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: title,
            windows: windows
        )
    }
}

struct GrokClient: ProviderClient {
    var provider: Provider { .grok }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try CredentialReaders.grokAuth()
            let token = try await CredentialReaders.refreshGrokIfNeeded(auth)
            let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
            var headers: [String: String] = [:]
            if let userID = auth.userID {
                headers["x-userid"] = userID
            }
            let data = try await HeadroomHTTP.get(url, token: token, headers: headers)
            return .success(try GrokParser.snapshot(from: data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}
