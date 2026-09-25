import Foundation

/// Running processes is Mac-only.
extension BlockingIO {
    struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool

        var succeeded: Bool {
            !timedOut && status == 0
        }
    }

    /// Runs a process to completion and returns its stdout. Output is drained while the process
    /// runs, so more than a pipe buffer's worth can't deadlock it. Killed after `timeout`, or
    /// once it writes more than `maxOutput` bytes.
    /// Blocks the calling thread: call it from `run`, never from an async context directly.
    static func runProcess(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        maxOutput: Int = 16 * 1024 * 1024
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
            var data = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.count > maxOutput {
                    process.terminate()
                    break
                }
            }
            collected.set(data)
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
