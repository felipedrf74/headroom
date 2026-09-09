import Foundation

enum HeadroomHTTP {
    static let timeout: TimeInterval = 8
    static let fetchBudget: TimeInterval = 12

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 5
        return URLSession(configuration: configuration)
    }()

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.unreachable
            }
            return (data, http)
        } catch is URLError {
            throw ProviderError.unreachable
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable
        }
    }

    static func mapStatus(_ status: Int, provider: Provider) -> ProviderError? {
        switch status {
        case 200..<300:
            nil
        case 401, 403:
            .expired(provider.expiredHint)
        default:
            .unreachable
        }
    }

    static func get(_ url: URL, token: String, headers: [String: String] = [:], provider: Provider? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await data(for: request)
        if let error = mapStatus(response.statusCode, provider: provider ?? inferredProvider(from: url)) {
            throw error
        }
        return data
    }

    static func post(_ url: URL, token: String, headers: [String: String] = [:], body: Data = Data("{}".utf8), provider: Provider? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await data(for: request)
        if let error = mapStatus(response.statusCode, provider: provider ?? inferredProvider(from: url)) {
            throw error
        }
        return data
    }

    private static func inferredProvider(from url: URL) -> Provider {
        let host = url.host ?? ""
        if host.contains("anthropic") { return .claude }
        if host.contains("openai") || host.contains("chatgpt") { return .openai }
        if host.contains("cursor") { return .cursor }
        return .grok
    }
}

protocol ProviderClient: Sendable {
    var provider: Provider { get }
    func fetch() async -> Result<QuotaSnapshot, ProviderError>
}
