import Foundation

enum OpenAIParser {
    private static let weekSeconds: Double = 6 * 24 * 60 * 60

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let rateLimit = JSONFlex.dictionary(root["rate_limit"]) ?? [:]
        let primary = window(from: JSONFlex.dictionary(rateLimit["primary_window"]))
        let secondary = window(from: JSONFlex.dictionary(rateLimit["secondary_window"]))

        let weekly: ParsedWindow?
        let session: ParsedWindow?
        if let secondary {
            weekly = secondary
            session = primary
        } else if let primary, primary.limitSeconds >= weekSeconds {
            weekly = primary
            session = nil
        } else {
            weekly = primary
            session = nil
        }

        guard let weekly else { throw ProviderError.parse }

        var windows = [
            QuotaWindow(
                id: "weekly",
                kind: weekly.limitSeconds >= weekSeconds ? .weekly : .session,
                title: weekly.limitSeconds >= weekSeconds ? "Weekly" : "Session",
                usedPercent: weekly.used,
                resetsAt: weekly.resetsAt
            ),
        ]

        if let session {
            windows.append(
                QuotaWindow(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usedPercent: session.used,
                    resetsAt: session.resetsAt
                )
            )
        }

        if let extras = JSONFlex.array(root["additional_rate_limits"]) {
            for (index, extra) in extras.enumerated() {
                guard let object = JSONFlex.dictionary(extra) else { continue }
                let name = JSONFlex.string(object["limit_name"]) ?? "Extra"
                let nested = JSONFlex.dictionary(object["rate_limit"]) ?? [:]
                if let extraWeekly = window(from: JSONFlex.dictionary(nested["secondary_window"])),
                   extraWeekly.used >= 1 {
                    windows.append(
                        QuotaWindow(
                            id: "extra-weekly-\(index)",
                            kind: .weekly,
                            title: name,
                            usedPercent: extraWeekly.used,
                            resetsAt: extraWeekly.resetsAt
                        )
                    )
                } else if let extraSession = window(from: JSONFlex.dictionary(nested["primary_window"])),
                          extraSession.used >= 1 {
                    windows.append(
                        QuotaWindow(
                            id: "extra-session-\(index)",
                            kind: .session,
                            title: name,
                            usedPercent: extraSession.used,
                            resetsAt: extraSession.resetsAt
                        )
                    )
                }
            }
        }

        let title = windows[0].title
        return QuotaSnapshot(
            provider: .openai,
            usedPercent: weekly.used,
            resetsAt: weekly.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: title,
            windows: windows
        )
    }

    private struct ParsedWindow {
        var used: Double
        var resetsAt: Date?
        var limitSeconds: Double
    }

    private static func window(from object: [String: Any]?) -> ParsedWindow? {
        guard let object else { return nil }
        guard let used = JSONFlex.number(object["used_percent"]) else { return nil }
        let remaining = JSONFlex.number(object["remaining_percent"])
        let percent = remaining.map { JSONFlex.clampPercent(100 - $0) } ?? JSONFlex.clampPercent(used)
        return ParsedWindow(
            used: percent,
            resetsAt: JSONFlex.date(object["reset_at"]),
            limitSeconds: JSONFlex.number(object["limit_window_seconds"]) ?? 0
        )
    }
}

struct OpenAIClient: ProviderClient {
    var provider: Provider { .openai }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try CredentialReaders.codexAuth()
            let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
            var headers = [
                "OpenAI-Beta": "codex-1",
                "originator": "Headroom",
            ]
            if let accountID = auth.accountID {
                headers["ChatGPT-Account-ID"] = accountID
            }
            let data = try await HeadroomHTTP.get(url, token: auth.accessToken, headers: headers)
            return .success(try OpenAIParser.snapshot(from: data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }
}
