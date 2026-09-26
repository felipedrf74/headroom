import Foundation
import Synchronization

enum TokenroomHTTP {
    static let timeout: TimeInterval = 12
    static let fetchBudget: TimeInterval = 20
    /// Wait used when a 429 carries no usable Retry-After.
    static let defaultRetryAfter: TimeInterval = 15 * 60

    /// The session requests go through. Tests swap in one with a stub protocol.
    static var session: URLSession {
        sessionOverride.withLock { $0 } ?? defaultSession
    }

    private static let sessionOverride = Mutex<URLSession?>(nil)

    static func overrideSession(_ session: URLSession?) {
        sessionOverride.withLock { $0 = session }
    }

    static let defaultSession: URLSession = {
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
        configuration.httpAdditionalHeaders = ["User-Agent": TokenroomIdentity.userAgent]
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

    static func mapStatus(_ status: Int, retryAfter: String? = nil, provider: Provider, now: Date = .now) -> ProviderError? {
        switch status {
        case 200..<300:
            nil
        case 401, 403:
            .expired(provider.expiredHint)
        case 429:
            .rateLimited(until: retryDate(retryAfter, now: now))
        default:
            .unreachable
        }
    }

    /// Retry-After as delta-seconds or an HTTP date.
    static func retryDate(_ value: String?, now: Date = .now) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// A JSON request. `token` is sent as `Authorization: Bearer`; pass nil for APIs that take
    /// the key in another header (Anthropic's `x-api-key`) or in the body.
    static func request(_ url: URL, method: String = "GET", token: String?, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func get(_ url: URL, token: String?, headers: [String: String] = [:], provider: Provider) async throws -> Data {
        try await send(request(url, token: token, headers: headers), provider: provider)
    }

    static func post(_ url: URL, token: String?, headers: [String: String] = [:], body: Data = Data("{}".utf8), provider: Provider) async throws -> Data {
        try await send(request(url, method: "POST", token: token, headers: headers, body: body), provider: provider)
    }

    /// Throws the mapped error for a non-2xx status.
    static func check(_ response: HTTPURLResponse, provider: Provider) throws {
        if let error = mapStatus(
            response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            provider: provider
        ) {
            throw error
        }
    }

    private static func send(_ request: URLRequest, provider: Provider) async throws -> Data {
        let (data, response) = try await data(for: request)
        try check(response, provider: provider)
        return data
    }
}

protocol ProviderClient: Sendable {
    var provider: Provider { get }
    /// How long a check may take before it counts as unreachable.
    var fetchBudget: TimeInterval { get }
    func fetch() async -> Result<QuotaSnapshot, ProviderError>
    /// A cheap local reading while the provider's own endpoint is resting between checks, or nil.
    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot?
    /// A sign-in finished or a key changed: forget anything kept from the old credentials.
    func credentialsChanged()
}

extension ProviderClient {
    var fetchBudget: TimeInterval { TokenroomHTTP.fetchBudget }

    /// This check, given up on after its `fetchBudget` (or `budget`, when less time is left), so
    /// one slow provider never holds up the rest. The Mac's refresh, the iPhone's key providers,
    /// and widgets all read through it. A check cut short, by the time or by the caller, is
    /// unreachable.
    func fetchWithinBudget(_ budget: TimeInterval? = nil) async -> Result<QuotaSnapshot, ProviderError> {
        let limit = min(budget ?? fetchBudget, fetchBudget)
        return await TimeLimit.run(limit, otherwise: .failure(.unreachable)) { await self.fetch() }
    }

    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        nil
    }

    func credentialsChanged() {}
}

/// Work that has to give way at a set time: a provider check, or a widget's few seconds.
enum TimeLimit {
    /// `work`'s answer, or `fallback` once `seconds` pass or the caller is cancelled. `work` is
    /// then cancelled but not waited for: a task group would wait, and some calls (iCloud's
    /// account status) carry on regardless.
    static func run<T: Sendable>(_ seconds: TimeInterval, otherwise fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        let answer = FirstAnswer<T>()
        let worker = Task { answer.give(await work()) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            answer.give(fallback)
        }
        let result = await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            answer.give(fallback)
        }
        worker.cancel()
        timer.cancel()
        return result
    }
}

/// The first answer given, for the one caller waiting on it; later ones are dropped.
private final class FirstAnswer<T: Sendable>: Sendable {
    private struct State {
        var answer: T?
        var waiting: CheckedContinuation<T, Never>?
        var isGiven = false
    }

    private let state = Mutex(State())

    func give(_ answer: T) {
        let waiting: CheckedContinuation<T, Never>? = state.withLock { state in
            guard !state.isGiven else { return nil }
            state.isGiven = true
            guard let waiting = state.waiting else {
                // Given before anyone waits (a caller cancelled on arrival): kept for `wait`.
                state.answer = answer
                return nil
            }
            state.waiting = nil
            return waiting
        }
        waiting?.resume(returning: answer)
    }

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            let ready: T? = state.withLock { state in
                if let answer = state.answer { return answer }
                state.waiting = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
}
