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
                resetsAt: resetsAt,
                windowSeconds: 7 * 86_400
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
                    resetsAt: JSONFlex.date(session["resets_at"]),
                    windowSeconds: 5 * 3_600
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
            let auth = try await BlockingIO.run { try CredentialReaders.claudeAuth() }
            do {
                return .success(try await usage(with: auth))
            } catch ProviderError.expired {
                // Claude Code may have replaced the token since it was cached. Read the
                // Keychain again once; never refresh the session ourselves.
                CredentialReaders.invalidateCaches()
                let fresh = try await BlockingIO.run { try CredentialReaders.claudeAuth() }
                guard fresh.accessToken != auth.accessToken else {
                    throw ProviderError.expired(Provider.claude.expiredHint)
                }
                return .success(try await usage(with: fresh))
            }
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    private func usage(with auth: CredentialReaders.ClaudeAuth) async throws -> QuotaSnapshot {
        guard !auth.accessToken.isEmpty, !auth.isExpired else {
            throw ProviderError.expired(Provider.claude.expiredHint)
        }
        let userAgent = await BlockingIO.run { CredentialReaders.claudeUserAgent() }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let data = try await TokenroomHTTP.get(
            url,
            token: auth.accessToken,
            headers: [
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": userAgent,
                "x-app": "cli",
            ],
            provider: .claude
        )
        return try ClaudeParser.snapshot(from: data)
    }
}
