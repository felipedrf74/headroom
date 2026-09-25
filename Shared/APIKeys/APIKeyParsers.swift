import Foundation

/// OpenRouter's `GET /api/v1/key`: the pasted key's own limit and spend. The key's masked
/// label is never read.
enum OpenRouterParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now, calendar: Calendar = .gregorianUTC) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let key = JSONFlex.dictionary(root["data"]) ?? root
        let window: QuotaWindow
        if let limit = JSONFlex.number(key["limit"]), limit > 0 {
            // A key with a spending limit is a real meter.
            let remaining = min(max(JSONFlex.number(key["limit_remaining"]) ?? limit, 0), limit)
            let used = limit - remaining
            let period = Self.period(JSONFlex.string(key["limit_reset"]), now: fetchedAt, calendar: calendar)
            window = QuotaWindow(
                id: "key-limit",
                kind: period.kind,
                title: period.title,
                usedPercent: JSONFlex.clampPercent(used / limit * 100),
                resetsAt: period.end,
                startsAt: period.start,
                amount: QuotaAmount(used: used, limit: limit, remaining: remaining, unit: "usd")
            )
        } else {
            let month = Self.period("monthly", now: fetchedAt, calendar: calendar)
            window = QuotaWindow(
                id: "usage-month",
                kind: .monthly,
                title: "This month",
                usedPercent: 0,
                resetsAt: month.end,
                startsAt: month.start,
                amount: QuotaAmount(used: JSONFlex.number(key["usage_monthly"]) ?? JSONFlex.number(key["usage"]) ?? 0, unit: "usd"),
                metered: false
            )
        }
        return QuotaSnapshot(
            provider: .openrouter,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: window.title,
            windows: [window],
            planLabel: (key["is_free_tier"] as? Bool) == true ? "Free tier" : nil
        )
    }

    /// OpenRouter limits reset at midnight UTC: daily, weekly (Monday), or monthly (the 1st).
    static func period(_ reset: String?, now: Date, calendar: Calendar) -> (kind: WindowKind, title: String, start: Date?, end: Date?) {
        switch reset?.lowercased() {
        case "daily":
            let start = calendar.startOfDay(for: now)
            return (.daily, "Today", start, calendar.date(byAdding: .day, value: 1, to: start))
        case "weekly":
            var iso = calendar
            iso.firstWeekday = 2
            let start = iso.dateInterval(of: .weekOfYear, for: now)?.start
            return (.weekly, "This week", start, start.flatMap { iso.date(byAdding: .day, value: 7, to: $0) })
        case "monthly":
            let start = calendar.dateInterval(of: .month, for: now)?.start
            return (.monthly, "This month", start, start.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) })
        default:
            return (.pool, "Key limit", nil, nil)
        }
    }
}

/// DeepSeek's `GET /user/balance`: one balance per currency.
enum DeepSeekParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let infos = JSONFlex.array(root["balance_infos"]) else { throw ProviderError.parse }
        let windows = infos.compactMap { item -> QuotaWindow? in
            guard let info = JSONFlex.dictionary(item),
                  let currency = JSONFlex.string(info["currency"])?.lowercased(),
                  let total = JSONFlex.number(info["total_balance"])
            else { return nil }
            return QuotaWindow(
                id: "balance-\(currency)",
                kind: .pool,
                title: "Balance",
                usedPercent: 0,
                resetsAt: nil,
                amount: QuotaAmount(remaining: total, unit: currency),
                metered: false
            )
        }
        guard let primary = windows.first else { throw ProviderError.parse }
        return QuotaSnapshot(
            provider: .deepseek,
            usedPercent: 0,
            resetsAt: nil,
            fetchedAt: fetchedAt,
            primaryTitle: primary.title,
            windows: windows,
            planLabel: (root["is_available"] as? Bool) == false ? "Balance used up" : nil
        )
    }
}

/// Moonshot's `GET /v1/users/me/balance`. Global accounts are billed in dollars, China in yuan.
enum MoonshotParser {
    static func snapshot(from data: Data, region: String?, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let balance = JSONFlex.dictionary(root["data"]),
              let available = JSONFlex.number(balance["available_balance"])
        else { throw ProviderError.parse }
        let window = QuotaWindow(
            id: "balance",
            kind: .pool,
            title: "Balance",
            usedPercent: 0,
            resetsAt: nil,
            amount: QuotaAmount(remaining: available, unit: MoonshotEndpoint.isChina(region) ? "cny" : "usd"),
            metered: false
        )
        return QuotaSnapshot(provider: .moonshot, usedPercent: 0, resetsAt: nil, fetchedAt: fetchedAt, primaryTitle: window.title, windows: [window])
    }
}

enum MoonshotEndpoint {
    static func isChina(_ region: String?) -> Bool {
        region?.lowercased() == "china"
    }

    static func balanceURL(region: String?) -> URL {
        URL(string: isChina(region) ? "https://api.moonshot.cn/v1/users/me/balance" : "https://api.moonshot.ai/v1/users/me/balance")!
    }
}

/// Vercel AI Gateway's `GET /v1/credits`: prepaid credits left and used, in dollars.
enum VercelGatewayParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let balance = JSONFlex.number(root["balance"]) else { throw ProviderError.parse }
        let window = QuotaWindow(
            id: "credits",
            kind: .pool,
            title: "Credits",
            usedPercent: 0,
            resetsAt: nil,
            amount: QuotaAmount(used: JSONFlex.number(root["total_used"]), remaining: balance, unit: "usd"),
            metered: false
        )
        return QuotaSnapshot(provider: .vercelGateway, usedPercent: 0, resetsAt: nil, fetchedAt: fetchedAt, primaryTitle: window.title, windows: [window])
    }
}
