import Foundation

/// Runs blocking work (processes, SQLite, file reads, the Keychain CLI) off Swift's
/// cooperative thread pool, which must never wait on I/O.
enum BlockingIO {
    private static let queue = DispatchQueue(
        label: "app.tokenroom.blocking-io",
        qos: .utility,
        attributes: .concurrent
    )

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
