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
    /// The last direct reading and any Retry-After, shared by copies of this client.
    let state = ClaudeClientState()

    /// A status-line reading this recent answers without calling Claude's endpoint.
    static let bridgeFreshness: TimeInterval = 5 * 60
    /// Older status-line readings are ignored: Claude may have been used elsewhere since.
    static let bridgeMaxAge: TimeInterval = 6 * 3600
    /// How long a direct reading's other windows (Opus, Sonnet, extra usage) keep being shown
    /// next to newer status-line readings, which don't carry them.
    static let directReuse: TimeInterval = 30 * 60

    /// Claude Code's status line when it's fresh, else the direct usage read merged with it. When
    /// the direct read can't happen (expired, rate limited, offline), a newer status line answers,
    /// with the other windows from the last direct read while that read is recent.
    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let now = Date()
        let reading = await currentReading(now: now)
        let last = state.lastDirect
        if let reading, now.timeIntervalSince(reading.at) < Self.bridgeFreshness,
           let last, now.timeIntervalSince(last.fetchedAt) < Self.directReuse,
           let answer = Self.merged(last, with: reading, now: now) {
            return .success(answer)
        }
        if let blocked = state.blockedUntil, blocked > now, blocked.timeIntervalSince(now) <= ProviderStatus.longestRetry {
            // Claude asked to wait; the status line still counts meanwhile.
            if let answer = Self.combined(last, reading, now: now) {
                return .success(answer)
            }
            return .failure(.rateLimited(until: blocked))
        }
        do {
            let direct = try await directUsage()
            state.recordDirect(direct)
            return .success(Self.merged(direct, with: reading, now: now) ?? direct)
        } catch {
            let failure = error as? ProviderError ?? .unreachable
            if case .rateLimited(let until) = failure {
                state.block(until: ProviderStatus.clampedRetry(until, now: now))
            }
            if let answer = Self.combined(last, reading, now: now) {
                return .success(answer)
            }
            return .failure(failure)
        }
    }

    /// Between direct reads (at most every 5 minutes, or while Claude asks to wait), a newer
    /// status-line reading still updates the weekly and session windows. It's merged with the
    /// last direct read, not with what's shown: that carries the direct windows under the status
    /// line's time, so they could never age out.
    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        let now = Date()
        guard let reading = await currentReading(now: now), reading.at > (previous?.fetchedAt ?? .distantPast) else { return nil }
        return Self.combined(state.lastDirect, reading, now: now)
    }

    /// After a sign-in, the old login's Retry-After and last direct read no longer apply.
    func credentialsChanged() {
        state.forgetDirect()
    }

    private func currentReading(now: Date) async -> ClaudeBridgeReading? {
        let bridge = self.bridge
        // Once per launch: the current script, and no copies of settings.json from 2.0.0.
        let firstRead = state.claimUpgrade()
        let reading = await BlockingIO.run { () -> ClaudeBridgeReading? in
            if firstRead {
                bridge.upgrade()
            }
            return bridge.reading()
        }
        guard let reading, now.timeIntervalSince(reading.at) < Self.bridgeMaxAge else { return nil }
        return reading
    }

    /// The last direct reading with newer status-line values, or the status line alone. Nil when
    /// the status line has nothing newer, so a failed direct read isn't answered with its own
    /// last reading.
    static func combined(_ direct: QuotaSnapshot?, _ reading: ClaudeBridgeReading?, now: Date = .now) -> QuotaSnapshot? {
        guard let reading else { return nil }
        guard let direct else { return reading.snapshot(now: now) }
        return merged(direct, with: reading, now: now)
    }

    /// Weekly and session readings from the status line replace older direct ones. The status
    /// line carries nothing else, so the direct read's other windows and extra usage stay only
    /// while that read is under `directReuse` old, and never past their reset. Nil when the
    /// reading isn't newer, has no current window, or its weekly window has reset (the new
    /// week isn't known yet, and the session doesn't stand in for it).
    static func merged(_ direct: QuotaSnapshot, with reading: ClaudeBridgeReading?, now: Date = .now) -> QuotaSnapshot? {
        guard let reading, reading.at > direct.fetchedAt, !reading.weeklyHasReset(now: now) else { return nil }
        let fresh = reading.windows(now: now)
        guard !fresh.isEmpty else { return nil }
        let recent = now.timeIntervalSince(direct.fetchedAt) < directReuse
        var merged = direct
        merged.windows = direct.windows.compactMap { (window: QuotaWindow) -> QuotaWindow? in
            guard let update = fresh.first(where: { $0.id == window.id }) else {
                return recent && (window.resetsAt ?? .distantFuture) > now ? window : nil
            }
            var updated = window
            updated.usedPercent = update.usedPercent
            updated.resetsAt = update.resetsAt ?? window.resetsAt
            return updated
        }
        merged.windows += fresh.filter { update in !direct.windows.contains { $0.id == update.id } }
        if !recent {
            merged.extra = nil
        }
        // The weekly window headlines when there is one; without it (an old direct read's
        // dropped, Claude Code reporting only the session), what's left does.
        if let weekly = merged.windows.firstIndex(where: { $0.id == "weekly" }), weekly > 0 {
            merged.windows.insert(merged.windows.remove(at: weekly), at: 0)
        }
        guard let primary = merged.windows.first else { return nil }
        merged.usedPercent = primary.usedPercent
        merged.resetsAt = primary.resetsAt
        merged.primaryTitle = primary.title
        merged.fetchedAt = reading.at
        merged.source = "bridge"
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

/// What `ClaudeClient` remembers between checks. Copies of the client share one.
final class ClaudeClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastDirect: QuotaSnapshot?
    private var _blockedUntil: Date?
    private var _upgraded = false

    var lastDirect: QuotaSnapshot? {
        lock.withLock { _lastDirect }
    }

    var blockedUntil: Date? {
        lock.withLock { _blockedUntil }
    }

    func recordDirect(_ snapshot: QuotaSnapshot) {
        lock.withLock {
            _lastDirect = snapshot
            _blockedUntil = nil
        }
    }

    func block(until date: Date) {
        lock.withLock { _blockedUntil = date }
    }

    func forgetDirect() {
        lock.withLock {
            _lastDirect = nil
            _blockedUntil = nil
        }
    }

    /// True only the first time: the bridge is brought up to date once per launch.
    func claimUpgrade() -> Bool {
        lock.withLock {
            defer { _upgraded = true }
            return !_upgraded
        }
    }
}
