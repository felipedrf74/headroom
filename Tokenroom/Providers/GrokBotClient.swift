import Foundation

enum GrokBotParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        if let included = root["hasNonZeroIncludedLimit"] as? Bool, included == false {
            throw ProviderError.notEntitled("Grok Bot isn't on this Cursor plan.")
        }
        guard let usedRaw = JSONFlex.number(root["usagePercent"]) else {
            throw ProviderError.parse
        }
        let used = JSONFlex.clampPercent(usedRaw)
        let resetsAt = JSONFlex.date(root["nextResetTimestampUtc"])
        let plan = JSONFlex.string(root["grokPlanLabel"]).flatMap { $0.isEmpty ? nil : $0 }
        return QuotaSnapshot(
            provider: .grokBot,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: [
                QuotaWindow(
                    id: "weekly",
                    kind: .weekly,
                    title: "Weekly",
                    usedPercent: used,
                    resetsAt: resetsAt
                ),
            ],
            planLabel: plan
        )
    }
}

struct GrokBotClient: ProviderClient {
    var provider: Provider { .grokBot }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let token = try await BlockingIO.run { try CredentialReaders.cursorAccessToken() }
            let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
            let data = try await TokenroomHTTP.post(
                url,
                token: token,
                headers: ["Connect-Protocol-Version": "1"],
                provider: .grokBot
            )
            return .success(try GrokBotParser.snapshot(from: data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}
