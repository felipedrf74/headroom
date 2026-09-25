import Foundation

/// A key for one provider: pasted on this device, or on the Mac found where a coding tool keeps it.
struct APIKeyCredential: Sendable, Equatable {
    var key: String
    var region: String?
    /// Where a key that wasn't pasted came from, e.g. `claude-settings`. Shown on the card.
    var source: String?
}

/// Reads a provider with the API key the user pasted on this device. Same code on Mac and iPhone.
struct APIKeyClient: ProviderClient {
    let provider: Provider
    var keys = APIKeyStore()
    /// Finds a key a coding tool already keeps on this device, for when none was pasted (Mac only).
    /// Throws when it found one that can't be used, such as an expired CLI login.
    var localCredential: (@Sendable (Provider) throws -> APIKeyCredential?)? = nil

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let keys = self.keys
        let provider = self.provider
        let local = localCredential
        do {
            let credential = try await BlockingIO.run { () throws -> APIKeyCredential? in
                // A key pasted in Settings wins over one found in another tool's config.
                if let key = keys.key(for: provider) {
                    return APIKeyCredential(key: key, region: keys.metadata(for: provider)?.region)
                }
                return try local?(provider)
            }
            guard let credential else {
                return .failure(.signedOut(provider.signInHint))
            }
            var snapshot = try await Self.snapshot(for: provider, key: credential.key, region: credential.region)
            snapshot.source = credential.source
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// One call with a key, without saving it. "Test & Save" uses this before storing a key.
    static func snapshot(for provider: Provider, key: String, region: String?) async throws -> QuotaSnapshot {
        switch provider {
        case .openrouter:
            let data = try await TokenroomHTTP.get(URL(string: "https://openrouter.ai/api/v1/key")!, token: key, provider: provider)
            return try OpenRouterParser.snapshot(from: data)
        case .deepseek:
            let data = try await TokenroomHTTP.get(URL(string: "https://api.deepseek.com/user/balance")!, token: key, provider: provider)
            return try DeepSeekParser.snapshot(from: data)
        case .moonshot:
            let data = try await TokenroomHTTP.get(MoonshotEndpoint.balanceURL(region: region), token: key, provider: provider)
            return try MoonshotParser.snapshot(from: data, region: region)
        case .vercelGateway:
            let data = try await TokenroomHTTP.get(URL(string: "https://ai-gateway.vercel.sh/v1/credits")!, token: key, provider: provider)
            return try VercelGatewayParser.snapshot(from: data)
        case .openaiOrg, .anthropicOrg, .xaiOrg:
            return try await orgSnapshot(for: provider, key: key)
        case .zai:
            let data = try await TokenroomHTTP.get(CodingPlanEndpoint.zaiQuota(region: region), token: key, provider: provider)
            return try ZaiParser.snapshot(from: data)
        case .kimiCode:
            let data = try await TokenroomHTTP.get(CodingPlanEndpoint.kimiUsages(region: region), token: key, provider: provider)
            return try KimiCodeParser.snapshot(from: data)
        case .minimax:
            return try await minimaxSnapshot(key: key, region: region)
        case .copilot:
            return try await copilotSnapshot(key: key, planName: region)
        case .opencodeGo:
            let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(CodingPlanEndpoint.opencodeGoUsage, token: key))
            if let error = OpenCodeGoParser.error(status: response.statusCode, body: data) {
                throw error
            }
            try TokenroomHTTP.check(response, provider: provider)
            return try OpenCodeGoParser.snapshot(from: data)
        default:
            throw ProviderError.parse
        }
    }

    /// What "Test & Save" learns about a key besides its reading.
    struct KeyCheck: Sendable {
        var snapshot: QuotaSnapshot
        /// Shown next to the key, e.g. an xAI key that can also change billing or keys.
        var warning: String?
    }

    /// `snapshot(for:key:region:)`, plus what's worth warning about before the key is saved.
    static func check(for provider: Provider, key: String, region: String?) async throws -> KeyCheck {
        let snapshot = try await snapshot(for: provider, key: key, region: region)
        var warning: String?
        if provider == .xaiOrg,
           let validation = try? await TokenroomHTTP.get(URL(string: "https://management-api.x.ai/auth/management-keys/validation")!, token: key, provider: provider),
           XAIBillingParser.canWrite(fromValidation: validation) {
            warning = "This key can also change your team's keys or billing. Tokenroom only reads with it, but a key limited to reading billing is safer."
        }
        return KeyCheck(snapshot: snapshot, warning: warning)
    }

    /// The Token Plan endpoint first, then the older Coding Plan one for accounts still on it.
    private static func minimaxSnapshot(key: String, region: String?) async throws -> QuotaSnapshot {
        let request = TokenroomHTTP.request(CodingPlanEndpoint.minimaxRemains(region: region, legacy: false), token: key)
        let (data, response) = try await TokenroomHTTP.data(for: request)
        if ![404, 405].contains(response.statusCode) {
            try TokenroomHTTP.check(response, provider: .minimax)
            do {
                return try MiniMaxParser.snapshot(from: data)
            } catch ProviderError.parse {
                // An unknown answer from the Token Plan endpoint: the account may be on the Coding Plan.
            }
        }
        let legacy = try await TokenroomHTTP.get(CodingPlanEndpoint.minimaxRemains(region: region, legacy: true), token: key, provider: .minimax)
        return try MiniMaxParser.snapshot(from: legacy, legacy: true)
    }
}
