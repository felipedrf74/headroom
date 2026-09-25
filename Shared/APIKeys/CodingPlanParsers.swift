import Foundation

/// Coding-plan hosts. A key only works in the region that issued it, so it's only ever sent to
/// the host of the region the user picked (or the host their coding tool is configured with).
enum CodingPlanEndpoint {
    static func isChina(_ region: String?) -> Bool {
        region == "China"
    }

    static func zaiQuota(region: String?) -> URL {
        URL(string: isChina(region)
            ? "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            : "https://api.z.ai/api/monitor/usage/quota/limit")!
    }

    /// The Kimi Code CLI signs in on kimi.com and keeps using that host.
    static func kimiUsages(region: String?) -> URL {
        URL(string: isChina(region)
            ? "https://api.kimi.com/coding/v1/usages"
            : "https://api.kimi.ai/coding/v1/usages")!
    }

    /// Token Plan first; accounts still on the older Coding Plan answer 404 there.
    static func minimaxRemains(region: String?, legacy: Bool) -> URL {
        let host = isChina(region) ? "https://api.minimaxi.com" : "https://api.minimax.io"
        return URL(string: host + (legacy ? "/v1/api/openplatform/coding_plan/remains" : "/v1/token_plan/remains"))!
    }

    static let opencodeGoUsage = URL(string: "https://opencode.ai/zen/go/v1/usage")!
}

// MARK: Z.ai

/// Z.ai's GLM Coding Plan quota (`/api/monitor/usage/quota/limit`). Errors arrive as HTTP 200
/// with `success: false`.
enum ZaiParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard (root["success"] as? Bool) == true else {
            throw error(code: JSONFlex.number(root["code"]).map { Int($0) }, message: JSONFlex.string(root["msg"]) ?? "")
        }
        let body = JSONFlex.dictionary(root["data"]) ?? [:]
        guard let limits = JSONFlex.array(body["limits"]) else { throw ProviderError.parse }

        var session: QuotaWindow?
        var weekly: QuotaWindow?
        var others: [QuotaWindow] = []
        for item in limits {
            guard let limit = JSONFlex.dictionary(item), let type = JSONFlex.string(limit["type"]) else { continue }
            let unit = JSONFlex.number(limit["unit"]).map { Int($0) }
            let number = JSONFlex.number(limit["number"]).map { Int($0) }
            guard let used = usedPercent(limit) else { continue }
            let reset = JSONFlex.date(limit["nextResetTime"])
            switch (type, unit, number) {
            case ("CREDIT_LIMIT", 3, 5), ("TOKENS_LIMIT", 3, 5):
                // An idle 5-hour window can report a reset far ahead; it hasn't started yet.
                let plausible = reset.flatMap { $0.timeIntervalSince(fetchedAt) <= 5 * 3600 + 60 ? $0 : nil }
                session = QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: used, resetsAt: plausible, windowSeconds: 5 * 3600)
            case ("CREDIT_LIMIT", 6, 1), ("TOKENS_LIMIT", 6, 1):
                weekly = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: reset, windowSeconds: 7 * 86_400)
            case ("TIME_LIMIT", 5, 1):
                others.append(QuotaWindow(id: "tools-monthly", kind: .monthly, title: "Web search & tools", usedPercent: used, resetsAt: reset))
            default:
                continue
            }
        }
        let windows = [weekly, session].compactMap { $0 } + others
        guard !windows.isEmpty else {
            throw ProviderError.notEntitled("This Z.ai key has no GLM Coding Plan limits.")
        }
        return try .headlined(by: windows, provider: .zai, fetchedAt: fetchedAt, planLabel: planLabel(body))
    }

    /// `usage` is the limit and `remaining` what's left; `percentage` is a rounded fallback.
    static func usedPercent(_ limit: [String: Any]) -> Double? {
        if let total = JSONFlex.number(limit["usage"]), total > 0, let remaining = JSONFlex.number(limit["remaining"]) {
            return JSONFlex.clampPercent((total - remaining) / total * 100)
        }
        return JSONFlex.number(limit["percentage"]).map(JSONFlex.clampPercent)
    }

    static func planLabel(_ body: [String: Any]) -> String? {
        if let level = JSONFlex.string(body["level"]), !level.isEmpty {
            return "GLM Coding \(level.capitalized)"
        }
        for key in ["planName", "plan", "plan_type", "packageName"] {
            if let name = JSONFlex.string(body[key]), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Z.ai's error codes: 1000–1004 are authentication, 1302/1303 rate limits.
    static func error(code: Int?, message: String) -> ProviderError {
        if message.localizedCaseInsensitiveContains("coding plan") {
            return .notEntitled("This Z.ai key isn't on a GLM Coding Plan.")
        }
        switch code {
        case .some(401), .some(1000...1004):
            return .expired(Provider.zai.expiredHint)
        case .some(429), .some(1302), .some(1303):
            return .rateLimited(until: nil)
        default:
            return .parse
        }
    }
}

// MARK: Kimi Code

/// Kimi Code's `/coding/v1/usages`: ratio pools (`usages.limit_5h`, `limit_7d`,
/// `limit_month_total`), the older count windows, and the booster wallet.
enum KimiCodeParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let pools = JSONFlex.dictionary(root["usages"]) ?? [:]
        let legacyWeekly = count(JSONFlex.dictionary(root["usage"]))
        let legacySession = JSONFlex.array(root["limits"])?.lazy
            .compactMap(JSONFlex.dictionary)
            .first { sessionLength($0) != nil }

        var windows: [QuotaWindow] = []
        if let weekly = pick(ratio(pools["limit_7d"]), legacy: legacyWeekly) {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: weekly.used, resetsAt: weekly.reset, windowSeconds: 7 * 86_400))
        }
        let legacySessionCount = legacySession.flatMap { count(JSONFlex.dictionary($0["detail"])) }
        if let session = pick(ratio(pools["limit_5h"]), legacy: legacySessionCount) {
            let length = legacySession.flatMap(sessionLength) ?? 5 * 3600
            windows.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: session.used, resetsAt: session.reset, windowSeconds: length))
        }
        if let month = ratio(pools["limit_month_total"]) ?? ratio(pools["limit_month_code"]) {
            windows.append(QuotaWindow(id: "monthly", kind: .monthly, title: "Monthly", usedPercent: month.used, resetsAt: month.reset))
        }
        guard !windows.isEmpty else { throw ProviderError.parse }
        return try .headlined(by: windows, provider: .kimiCode, fetchedAt: fetchedAt, planLabel: planLabel(root), extra: booster(root["boosterWallet"]))
    }

    typealias Reading = (used: Double, reset: Date?)

    /// A ratio pool: `used_ratio` 0…1 (above 1 once over the limit) and an ISO `reset_time`.
    static func ratio(_ value: Any?) -> Reading? {
        guard let pool = JSONFlex.dictionary(value), let ratio = JSONFlex.number(pool["used_ratio"]) else { return nil }
        return (JSONFlex.clampPercent(ratio * 100), JSONFlex.date(pool["reset_time"]))
    }

    /// An older count window: int64 strings, and one of several reset spellings.
    static func count(_ window: [String: Any]?) -> Reading? {
        guard let window, let limit = JSONFlex.number(window["limit"]), limit > 0 else { return nil }
        let used = JSONFlex.number(window["used"])
            ?? JSONFlex.number(window["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        let reset = ["resetTime", "resetAt", "reset_time", "reset_at"].lazy.compactMap { JSONFlex.date(window[$0]) }.first
        return (JSONFlex.clampPercent(used / limit * 100), reset)
    }

    /// Ratios win, except a zero ratio beside a count that shows use: the ratio lagged behind.
    static func pick(_ ratio: Reading?, legacy: Reading?) -> Reading? {
        if let ratio, !(ratio.used == 0 && (legacy?.used ?? 0) > 0) {
            return ratio
        }
        return legacy ?? ratio
    }

    static func sessionLength(_ limit: [String: Any]) -> Double? {
        guard let window = JSONFlex.dictionary(limit["window"]), let duration = JSONFlex.number(window["duration"]) else { return nil }
        let seconds: Double
        switch JSONFlex.string(window["timeUnit"]) {
        case "TIME_UNIT_MINUTE": seconds = duration * 60
        case "TIME_UNIT_HOUR": seconds = duration * 3600
        default: return nil
        }
        // Day-long and longer windows aren't the session window.
        return seconds < 86_400 ? seconds : nil
    }

    static let levelNames = [
        "LEVEL_FREE": "Adagio",
        "LEVEL_TRIAL": "Andante",
        "LEVEL_BASIC": "Moderato",
        "LEVEL_INTERMEDIATE": "Allegretto",
        "LEVEL_ADVANCED": "Allegro",
    ]

    static func planLabel(_ root: [String: Any]) -> String? {
        let membership = JSONFlex.dictionary(JSONFlex.dictionary(root["user"])?["membership"])
        guard let level = JSONFlex.string(membership?["level"]), !level.isEmpty else { return nil }
        let version = JSONFlex.string(root["version"])
        if version == nil || version == "GOODS_VERSION_V1", let name = levelNames[level] {
            return name
        }
        return level.replacingOccurrences(of: "LEVEL_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The booster wallet: prepaid usage beyond the plan. Amounts are fixed point, 1e6 per cent.
    static func booster(_ value: Any?) -> ExtraUsage? {
        guard let wallet = JSONFlex.dictionary(value),
              let balance = JSONFlex.dictionary(wallet["balance"]),
              JSONFlex.string(balance["type"]) == "BOOSTER",
              let total = JSONFlex.number(balance["amount"]), total > 0
        else { return nil }
        let left = JSONFlex.number(balance["amountLeft"]) ?? 0
        let limit = JSONFlex.dictionary(wallet["monthlyChargeLimit"])
        let used = JSONFlex.dictionary(wallet["monthlyUsed"])
        let currency = [limit, used].lazy.compactMap { JSONFlex.string($0?["currency"]) }.first { !$0.isEmpty } ?? "USD"
        return ExtraUsage(
            title: "Booster",
            amount: QuotaAmount(
                used: JSONFlex.number(used?["priceInCents"]).map { $0 / 100 },
                limit: (wallet["monthlyChargeLimitEnabled"] as? Bool) == true ? JSONFlex.number(limit?["priceInCents"]).map { $0 / 100 } : nil,
                remaining: left / 1e8,
                unit: currency.lowercased()
            )
        )
    }
}

// MARK: MiniMax

/// MiniMax's plan remains: `model_remains[]` lanes (`general`, `video`, or model names), each with
/// an interval window and a weekly one.
enum MiniMaxParser {
    /// - Parameter legacy: the older Coding Plan endpoint, whose `*_usage_count` is what's *left*.
    static func snapshot(from data: Data, legacy: Bool = false, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        try check(root)
        let body = JSONFlex.dictionary(root["data"]) ?? root
        guard let lanes = JSONFlex.array(body["model_remains"]) ?? JSONFlex.array(root["model_remains"]) else {
            throw ProviderError.parse
        }
        var primary: [QuotaWindow] = []
        var others: [QuotaWindow] = []
        for item in lanes {
            guard let lane = JSONFlex.dictionary(item) else { continue }
            let name = JSONFlex.string(lane["model_name"]) ?? "general"
            let isGeneral = name == "general"
            let interval = window(lane, prefix: "current_interval", start: "start_time", end: "end_time", legacy: legacy, now: fetchedAt)
            let weekly = window(lane, prefix: "current_weekly", start: "weekly_start_time", end: "weekly_end_time", legacy: legacy, now: fetchedAt)
            if isGeneral {
                if let weekly {
                    primary.insert(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: weekly.used, resetsAt: weekly.reset, windowSeconds: weekly.length), at: 0)
                }
                if let interval {
                    primary.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: interval.used, resetsAt: interval.reset, windowSeconds: interval.length))
                }
            } else {
                let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
                let title = name == "video" ? "Video" : name
                if let interval {
                    let isDay = (interval.length ?? 0) >= 86_400
                    others.append(QuotaWindow(id: "\(slug)-interval", kind: isDay ? .daily : .session, title: isDay ? "\(title) today" : title, usedPercent: interval.used, resetsAt: interval.reset, windowSeconds: interval.length))
                }
                if let weekly {
                    others.append(QuotaWindow(id: "\(slug)-weekly", kind: .weekly, title: "\(title) weekly", usedPercent: weekly.used, resetsAt: weekly.reset, windowSeconds: weekly.length))
                }
            }
        }
        let windows = primary + others
        guard !windows.isEmpty else {
            throw ProviderError.notEntitled("This MiniMax key has no Coding or Token Plan limits.")
        }
        return try .headlined(by: windows, provider: .minimax, fetchedAt: fetchedAt, planLabel: planLabel(body, root: root))
    }

    /// `base_resp.status_code`: 0 is success; 1004 and 2049 mean the key (or its region) was refused.
    static func check(_ root: [String: Any]) throws {
        let base = JSONFlex.dictionary(root["base_resp"])
        let code = JSONFlex.number(base?["status_code"]).map { Int($0) } ?? 0
        switch code {
        case 0:
            return
        case 1004, 2049:
            throw ProviderError.expired(Provider.minimax.expiredHint)
        case 1002, 1039:
            throw ProviderError.rateLimited(until: nil)
        default:
            throw ProviderError.parse
        }
    }

    typealias Lane = (used: Double, reset: Date?, length: Double?)

    /// One lane window, or nil when the plan doesn't include it (status 3 with nothing to count)
    /// or it's unlimited.
    static func window(_ lane: [String: Any], prefix: String, start: String, end: String, legacy: Bool, now: Date) -> Lane? {
        let total = JSONFlex.number(lane["\(prefix)_total_count"]) ?? 0
        let count = JSONFlex.number(lane["\(prefix)_usage_count"]) ?? 0
        let remainingPercent = JSONFlex.number(lane["\(prefix)_remaining_percent"])
        let status = JSONFlex.number(lane["\(prefix)_status"]).map { Int($0) }
        if status == 3, total == 0, count == 0, (remainingPercent ?? 100) >= 100 {
            return nil
        }
        let used: Double
        if let remainingPercent {
            used = 100 - remainingPercent
        } else if total > 0 {
            // The Coding Plan endpoint's "usage" count is what's left, despite its name.
            used = (legacy ? total - count : count) / total * 100
        } else {
            return nil
        }
        let startsAt = JSONFlex.date(lane[start])
        let endsAt = JSONFlex.date(lane[end])
        var reset = endsAt.flatMap { $0 > now ? $0 : nil }
        if reset == nil, prefix == "current_interval", let millis = JSONFlex.number(lane["remains_time"]), millis > 0 {
            reset = now.addingTimeInterval(millis / 1000)
        }
        let length = startsAt.flatMap { start in endsAt.map { $0.timeIntervalSince(start) } }.flatMap { $0 > 0 ? $0 : nil }
        return (JSONFlex.clampPercent(used), reset, length)
    }

    static func planLabel(_ body: [String: Any], root: [String: Any]) -> String? {
        for source in [body, root] {
            for key in ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title"] {
                if let title = JSONFlex.string(source[key]), !title.isEmpty {
                    return title
                }
            }
            if let title = JSONFlex.string(JSONFlex.dictionary(source["current_combo_card"])?["title"]), !title.isEmpty {
                return title
            }
        }
        return nil
    }
}

// MARK: OpenCode Go

/// OpenCode Go's `/zen/go/v1/usage`: a rolling 5-hour window, and weekly and monthly ones.
/// `percent` is used, 0–100.
enum OpenCodeGoParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let usage = JSONFlex.dictionary(root["usage"]),
              let rolling = window(usage["rolling"], now: fetchedAt)
        else { throw ProviderError.parse }
        var windows: [QuotaWindow] = []
        if let weekly = window(usage["weekly"], now: fetchedAt) {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: weekly.used, resetsAt: weekly.reset, windowSeconds: 7 * 86_400))
        }
        windows.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: rolling.used, resetsAt: rolling.reset, windowSeconds: 5 * 3600))
        if let monthly = window(usage["monthly"], now: fetchedAt) {
            windows.append(QuotaWindow(id: "monthly", kind: .monthly, title: "Monthly", usedPercent: monthly.used, resetsAt: monthly.reset))
        }
        return try .headlined(by: windows, provider: .opencodeGo, fetchedAt: fetchedAt, planLabel: "Go")
    }

    static func window(_ value: Any?, now: Date) -> (used: Double, reset: Date?)? {
        guard let window = JSONFlex.dictionary(value), let percent = JSONFlex.number(window["percent"]) else { return nil }
        // A rate-limited window is spent, whatever the rounded percent says.
        let used = JSONFlex.string(window["status"]) == "rate-limited" ? max(percent, 100) : percent
        let reset = JSONFlex.date(window["resetsAt"])
            ?? JSONFlex.number(window["resetInSec"]).map { now.addingTimeInterval($0) }
        return (JSONFlex.clampPercent(used), reset)
    }

    /// A 403 with `EntitlementError` is a valid key without a Go subscription.
    static func error(status: Int, body: Data) -> ProviderError? {
        guard status == 403,
              let root = try? JSONFlex.object(from: body),
              JSONFlex.string(JSONFlex.dictionary(root["error"])?["type"]) == "EntitlementError"
        else { return nil }
        return .notEntitled("This OpenCode key has no Go subscription.")
    }
}
