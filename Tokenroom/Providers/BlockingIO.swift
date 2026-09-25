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

    struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool

        var succeeded: Bool {
            !timedOut && status == 0
        }
    }

    /// Runs a process to completion and returns its stdout. Output is drained while the process
    /// runs, so more than a pipe buffer's worth can't deadlock it. Killed after `timeout`.
    /// Blocks the calling thread: call it from `run`, never from an async context directly.
    static func runProcess(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ProcessOutput(status: -1, stdout: Data(), timedOut: false)
        }

        let collected = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            collected.set(reader.readDataToEndOfFile())
            drained.signal()
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // EOF arrives once the process closes stdout; don't wait forever on a lingering child.
        _ = drained.wait(timeout: .now() + 1)
        return ProcessOutput(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: collected.data,
            timedOut: timedOut
        )
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        var data: Data {
            lock.withLock { value }
        }

        func set(_ data: Data) {
            lock.withLock { value = data }
        }
    }
}
