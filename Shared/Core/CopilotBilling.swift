import Foundation

/// GitHub Copilot through GitHub's documented billing API: a fine-grained personal access token
/// with the "Plan" (read) account permission reads this month's AI credits. GitHub doesn't report
/// a personal plan's allowance, so the user picks the plan and the allowance comes from here.
///
/// Only Copilot the user pays for personally shows up; seats from an organization don't.
enum CopilotBilling {
    /// The ID of the month's bucket, whether read with the Mac's login or a token.
    static let windowID = "premium_interactions"
    /// The ID Tokenroom 2.0.0 gave the same bucket when read with a token; Macs not updated yet
    /// still send it, and history recorded under it moves over (`HistoryStore`).
    static let legacyWindowID = "ai_credits"

    /// A window's ID the way this version names it.
    static func currentWindowID(provider: String, window: String) -> String {
        provider == Provider.copilot.rawValue && window == legacyWindowID ? windowID : window
    }

    struct Plan: Equatable, Sendable {
        var name: String
        /// Monthly allowance, when GitHub publishes one (Free and Student have none on record).
        var allowance: Double?
        /// Yearly Pro and Pro+ subscriptions from before June 2026 still count premium requests.
        var isLegacy = false
    }

    /// Base plus flex credits per month, from GitHub's plans page (June 2026). The flex part can
    /// change: keep this table the only place that knows the numbers.
    static let plans: [Plan] = [
        Plan(name: "Pro", allowance: 1_500),
        Plan(name: "Pro+", allowance: 7_000),
        Plan(name: "Max", allowance: 20_000),
        Plan(name: "Free", allowance: nil),
        Plan(name: "Student", allowance: nil),
        Plan(name: "Pro, yearly", allowance: 300, isLegacy: true),
        Plan(name: "Pro+, yearly", allowance: 1_500, isLegacy: true),
    ]

    static func plan(named name: String?) -> Plan {
        plans.first { $0.name == name } ?? plans[0]
    }

    static let headers = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
    ]

    /// A token GitHub refused. `Provider.copilot.expiredHint` is about the gh login instead.
    static let tokenExpiredHint = "Couldn't use this fine-grained token. Add a new one in Settings."

    /// `login` from `GET /user`, which needs no permissions.
    static func login(from data: Data) throws -> String {
        let root = try JSONFlex.object(from: data)
        guard let login = JSONFlex.string(root["login"]), !login.isEmpty else { throw ProviderError.parse }
        return login
    }

    /// Everything used this month: the sum of `grossQuantity`, across every SKU and model. Gross
    /// includes what the plan covers; `netQuantity` is only what's billed beyond it.
    static func used(from data: Data) throws -> Double {
        let root = try JSONFlex.object(from: data)
        guard let items = JSONFlex.array(root["usageItems"]) else { throw ProviderError.parse }
        return items.compactMap { $0 as? [String: Any] }.reduce(0) { total, item in
            total + (JSONFlex.number(item["grossQuantity"]) ?? 0)
        }
    }

    /// The calendar month in UTC, which is when GitHub resets the allowance.
    static func month(containing date: Date) -> (start: Date, end: Date, year: Int, month: Int) {
        let calendar = Calendar.gregorianUTC
        let parts = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: parts) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (start, end, parts.year ?? 1970, parts.month ?? 1)
    }

    static func snapshot(used: Double, plan: Plan, now: Date = .now) throws -> QuotaSnapshot {
        let month = month(containing: now)
        let unit = plan.isLegacy ? "requests" : "credits"
        let window = QuotaWindow(
            // The ID the Mac's login read gives the same bucket, so history and alerts carry on
            // when the reading switches between the login and the token.
            id: windowID,
            kind: .monthly,
            title: plan.isLegacy ? "Premium requests" : "AI credits",
            usedPercent: plan.allowance.map { JSONFlex.clampPercent(used / $0 * 100) } ?? 0,
            resetsAt: month.end,
            startsAt: month.start,
            amount: QuotaAmount(used: used, limit: plan.allowance, remaining: plan.allowance.map { max($0 - used, 0) }, unit: unit),
            metered: plan.allowance != nil
        )
        return try .headlined(by: [window], provider: .copilot, fetchedAt: now, planLabel: "Copilot \(plan.name)")
    }
}
