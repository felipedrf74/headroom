import Foundation

/// Claude usage from `api.anthropic.com/api/oauth/usage`. Keys with codenames are ignored.
enum ClaudeParser {
    private static let week: Double = 7 * 86_400

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let weekly = JSONFlex.dictionary(root["seven_day"]) else {
            throw ProviderError.parse
        }
        let used = JSONFlex.clampPercent(JSONFlex.number(weekly["utilization"]) ?? 0)
        let resetsAt = JSONFlex.date(weekly["resets_at"])
        let weekStart = JSONFlex.date(JSONFlex.dictionary(root["seven_day_breakdown"])?["window_started_at"])

        var windows = [
            QuotaWindow(
                id: "weekly",
                kind: .weekly,
                title: "Weekly",
                usedPercent: used,
                resetsAt: resetsAt,
                windowSeconds: week,
                startsAt: weekStart
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

        // Model weekly caps, when the plan has them.
        for (key, title) in [("seven_day_opus", "Opus weekly"), ("seven_day_sonnet", "Sonnet weekly")] {
            if let object = JSONFlex.dictionary(root[key]), let percent = JSONFlex.number(object["utilization"]) {
                windows.append(
                    QuotaWindow(
                        id: key,
                        kind: .weekly,
                        title: title,
                        usedPercent: JSONFlex.clampPercent(percent),
                        resetsAt: JSONFlex.date(object["resets_at"]),
                        windowSeconds: week
                    )
                )
            }
        }

        // Other model-scoped weekly caps. Unscoped entries repeat the weekly and session windows.
        for (index, item) in (JSONFlex.array(root["limits"]) ?? []).enumerated() {
            guard let limit = JSONFlex.dictionary(item),
                  (limit["is_active"] as? Bool) != false,
                  let model = JSONFlex.dictionary(JSONFlex.dictionary(limit["scope"])?["model"]),
                  let name = JSONFlex.string(model["display_name"]), !name.isEmpty,
                  let percent = JSONFlex.number(limit["percent"])
            else { continue }
            let title = "\(name) weekly"
            guard !windows.contains(where: { $0.title == title }) else { continue }
            windows.append(
                QuotaWindow(
                    id: "limit-\(index)",
                    kind: .weekly,
                    title: title,
                    usedPercent: JSONFlex.clampPercent(percent),
                    resetsAt: JSONFlex.date(limit["resets_at"]),
                    windowSeconds: week
                )
            )
        }

        return QuotaSnapshot(
            provider: .claude,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: windows,
            extra: extraUsage(from: JSONFlex.dictionary(root["extra_usage"]))
        )
    }

    /// Paid usage past the plan. Amounts arrive in minor units (`decimal_places`).
    private static func extraUsage(from object: [String: Any]?) -> ExtraUsage? {
        guard let object, (object["is_enabled"] as? Bool) == true,
              let rawLimit = JSONFlex.number(object["monthly_limit"]), rawLimit > 0
        else { return nil }
        let scale = pow(10, JSONFlex.number(object["decimal_places"]) ?? 0)
        let used = (JSONFlex.number(object["used_credits"]) ?? 0) / scale
        let limit = rawLimit / scale
        return ExtraUsage(
            title: "Extra usage",
            amount: QuotaAmount(used: used, limit: limit, remaining: max(limit - used, 0), unit: (JSONFlex.string(object["currency"]) ?? "usd").lowercased())
        )
    }
}

struct ClaudeClient: ProviderClient {
    var provider: Provider { .claude }
    var bridge: ClaudeStatusLineBridge = .standard

    /// The direct usage read, merged with Claude Code's status line when that is newer. When the
    /// direct read can't happen (expired, rate limited, offline), the status line alone answers.
    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let bridge = self.bridge
        let reading = await BlockingIO.run { bridge.reading() }
        do {
            let direct = try await directUsage()
            return .success(Self.merged(direct, with: reading))
        } catch {
            if let fallback = reading?.snapshot() {
                return .success(fallback)
            }
            return .failure(error as? ProviderError ?? .unreachable)
        }
    }

    /// Weekly and session readings from the status line replace older direct ones.
    static func merged(_ direct: QuotaSnapshot, with reading: ClaudeBridgeReading?, now: Date = .now) -> QuotaSnapshot {
        guard let reading, reading.at > direct.fetchedAt, let fresh = reading.snapshot(now: now) else { return direct }
        var merged = direct
        for window in fresh.windows {
            if let index = merged.windows.firstIndex(where: { $0.id == window.id }) {
                merged.windows[index].usedPercent = window.usedPercent
                merged.windows[index].resetsAt = window.resetsAt ?? merged.windows[index].resetsAt
            }
        }
        if let weekly = merged.windows.first(where: { $0.id == "weekly" }) {
            merged.usedPercent = weekly.usedPercent
            merged.resetsAt = weekly.resetsAt
        }
        return merged
    }

    private func directUsage() async throws -> QuotaSnapshot {
        let auth = try await BlockingIO.run { try CredentialReaders.claudeAuth() }
        do {
            return try await usage(with: auth)
        } catch ProviderError.expired {
            // Claude Code may have replaced the token since it was cached. Read the
            // Keychain again once; never refresh the session ourselves.
            CredentialReaders.invalidateCaches()
            let fresh = try await BlockingIO.run { try CredentialReaders.claudeAuth() }
            guard fresh.accessToken != auth.accessToken else {
                throw ProviderError.expired(Provider.claude.expiredHint)
            }
            return try await usage(with: fresh)
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
