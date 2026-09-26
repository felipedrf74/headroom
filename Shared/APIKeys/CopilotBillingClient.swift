import Foundation

extension APIKeyClient {
    /// This month's Copilot usage with a fine-grained token; `planName` is the plan picked with it.
    static func copilotSnapshot(key: String, planName: String?, now: Date = .now) async throws -> QuotaSnapshot {
        let plan = CopilotBilling.plan(named: planName)
        let user = try await copilotGet(URL(string: "https://api.github.com/user")!, key: key)
        let login = try CopilotBilling.login(from: user)
        let month = CopilotBilling.month(containing: now)
        let path = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login
        var components = URLComponents(string: "https://api.github.com/users/\(path)/settings/billing/\(plan.isLegacy ? "premium_request" : "ai_credit")/usage")!
        components.queryItems = [
            URLQueryItem(name: "year", value: String(month.year)),
            URLQueryItem(name: "month", value: String(month.month)),
        ]
        let usage = try await copilotGet(components.url!, key: key)
        return try CopilotBilling.snapshot(used: try CopilotBilling.used(from: usage), plan: plan, now: now)
    }

    private static func copilotGet(_ url: URL, key: String) async throws -> Data {
        let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(url, token: key, headers: CopilotBilling.headers))
        switch response.statusCode {
        case 401:
            throw ProviderError.expired(CopilotBilling.tokenExpiredHint)
        case 403:
            throw ProviderError.notEntitled("This token can't read Copilot usage. Create a fine-grained token with the Plan (read) account permission.")
        case 404:
            throw ProviderError.notEntitled("GitHub has no Copilot usage for this account. Copilot through an organization isn't included.")
        default:
            try TokenroomHTTP.check(response, provider: .copilot)
            return data
        }
    }
}
