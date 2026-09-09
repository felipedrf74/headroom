import Foundation

enum ClaudeParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let weekly = JSONFlex.dictionary(root["seven_day"]) else {
            throw ProviderError.parse
        }
        let used = JSONFlex.clampPercent(JSONFlex.number(weekly["utilization"]) ?? 0)
        let resetsAt = JSONFlex.date(weekly["resets_at"])

        var windows = [
            QuotaWindow(
                id: "weekly",
                kind: .weekly,
                title: "Weekly",
                usedPercent: used,
                resetsAt: resetsAt
            ),
        ]

        if let session = JSONFlex.dictionary(root["five_hour"]),
           let sessionUsed = JSONFlex.number(session["utilization"]) {
            windows.append(
                QuotaWindow(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usedPercent: JSONFlex.clampPercent(sessionUsed),
                    resetsAt: JSONFlex.date(session["resets_at"])
                )
            )
        }

        return QuotaSnapshot(
            provider: .claude,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: windows
        )
    }
}

struct ClaudeClient: ProviderClient {
    var provider: Provider { .claude }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try CredentialReaders.claudeAuth()
            let token = try await CredentialReaders.refreshClaudeIfNeeded(auth)
            let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
            let data = try await HeadroomHTTP.get(
                url,
                token: token,
                headers: [
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": CredentialReaders.claudeUserAgent(),
                    "x-app": "cli",
                ]
            )
            return .success(try ClaudeParser.snapshot(from: data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}
