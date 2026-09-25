import Foundation

/// Reads a provider with the API key the user pasted on this device. Same code on Mac and iPhone.
struct APIKeyClient: ProviderClient {
    let provider: Provider
    var keys = APIKeyStore()

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let keys = self.keys
        let provider = self.provider
        let stored = await BlockingIO.run { (key: keys.key(for: provider), region: keys.metadata(for: provider)?.region) }
        guard let key = stored.key else {
            return .failure(.signedOut(provider.signInHint))
        }
        do {
            return .success(try await Self.snapshot(for: provider, key: key, region: stored.region))
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
        default:
            throw ProviderError.parse
        }
    }
}
