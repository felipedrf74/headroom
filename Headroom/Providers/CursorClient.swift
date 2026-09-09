import Foundation

enum CursorParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let plan = JSONFlex.dictionary(root["planUsage"]) ?? [:]
        let auto = JSONFlex.number(plan["autoPercentUsed"])
        let api = JSONFlex.number(plan["apiPercentUsed"])
        let total = JSONFlex.number(plan["totalPercentUsed"])

        let autoPercent = JSONFlex.clampPercent(auto ?? 0)
        let apiPercent = JSONFlex.clampPercent(api ?? 0)
        var used = max(autoPercent, apiPercent)
        if used == 0, let total {
            used = JSONFlex.clampPercent(total)
        }
        if used == 0,
           let limit = JSONFlex.number(plan["limit"]), limit > 0,
           let spend = JSONFlex.number(plan["includedSpend"]) ?? JSONFlex.number(plan["totalSpend"]) {
            used = JSONFlex.clampPercent(spend / limit * 100)
        }

        let resetsAt = JSONFlex.date(root["billingCycleEnd"])
        var windows = [
            QuotaWindow(
                id: "cycle",
                kind: .billingCycle,
                title: "This cycle",
                usedPercent: used,
                resetsAt: resetsAt
            ),
        ]
        if auto != nil {
            windows.append(
                QuotaWindow(
                    id: "cursor-models",
                    kind: .pool,
                    title: "Cursor Models",
                    usedPercent: autoPercent,
                    resetsAt: resetsAt
                )
            )
        }
        if api != nil {
            windows.append(
                QuotaWindow(
                    id: "other-models",
                    kind: .pool,
                    title: "Other Models",
                    usedPercent: apiPercent,
                    resetsAt: resetsAt
                )
            )
        }

        return QuotaSnapshot(
            provider: .cursor,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "This cycle",
            windows: windows
        )
    }
}

struct CursorClient: ProviderClient {
    var provider: Provider { .cursor }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let token = try CredentialReaders.cursorAccessToken()
            let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
            let data = try await HeadroomHTTP.post(
                url,
                token: token,
                headers: ["Connect-Protocol-Version": "1"]
            )
            return .success(try CursorParser.snapshot(from: data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}
