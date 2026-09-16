import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class SignInCoordinator {
    enum Phase: Equatable {
        case idle
        case running(Provider)
        case needsInstall(Provider, tool: String, url: URL)
        case failed(Provider, String)
    }

    var phase: Phase = .idle

    private var job: Task<Void, Never>?
    var onConnected: ((Provider) -> Void)?

    func isWorking(_ provider: Provider) -> Bool {
        if case .running(let active) = phase {
            return active == provider
        }
        return false
    }

    func signIn(_ provider: Provider) {
        cancel()
        job = Task { [weak self] in
            await self?.run(provider)
        }
    }

    func openInstallPage(_ provider: Provider) {
        if case .needsInstall(let active, _, let url) = phase, active == provider {
            Tooling.open(url)
            return
        }
        Tooling.open(provider.installURL)
    }

    func cancel() {
        job?.cancel()
        job = nil
        phase = .idle
    }

    private func run(_ provider: Provider) async {
        phase = .running(provider)
        CredentialReaders.invalidateCaches()
        let baseline = CredentialReaders.sessionStamp(provider)
        if CredentialReaders.hasUsableSession(provider) {
            finishSuccess(provider)
            return
        }

        switch provider {
        case .cursor, .grokBot:
            guard let app = Tooling.applicationURL(
                bundleIdentifiers: provider.appBundleIdentifiers,
                names: provider.appNames
            ) else {
                phase = .needsInstall(provider, tool: provider.installToolName, url: provider.installURL)
                return
            }
            Tooling.openApplication(app)
        case .grok, .claude, .openai:
            guard let executable = provider.cliExecutable.flatMap({ Tooling.resolve($0) }) else {
                phase = .needsInstall(provider, tool: provider.installToolName, url: provider.installURL)
                return
            }
            let resetDeadSession = provider == .claude && !((try? CredentialReaders.claudeAuth())?.canRefresh ?? false)
            launchInTerminal(
                executable: executable,
                arguments: provider.loginArguments,
                resetClaudeSession: resetDeadSession
            )
        }

        let deadline = Date().addingTimeInterval(180)
        while !Task.isCancelled, Date() < deadline {
            CredentialReaders.invalidateCaches()
            if sessionBecameUsable(provider, baseline: baseline) {
                finishSuccess(provider)
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        if Task.isCancelled {
            phase = .idle
            return
        }
        CredentialReaders.invalidateCaches()
        if sessionBecameUsable(provider, baseline: baseline) {
            finishSuccess(provider)
        } else {
            phase = .failed(provider, "Couldn't finish \(provider.displayName) sign-in.")
        }
    }

    private func sessionBecameUsable(_ provider: Provider, baseline: String?) -> Bool {
        guard CredentialReaders.hasUsableSession(provider) else { return false }
        let stamp = CredentialReaders.sessionStamp(provider)
        if baseline == nil {
            return stamp != nil
        }
        return stamp != baseline
    }

    private func finishSuccess(_ provider: Provider) {
        CredentialReaders.invalidateCaches()
        phase = .idle
        onConnected?(provider)
    }

    private func launchInTerminal(executable: URL, arguments: [String], resetClaudeSession: Bool = false) {
        guard !executable.path.isEmpty else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("login.command")
        let quoted = Self.quote(executable.path)
        let reset = resetClaudeSession ? "\(quoted) auth logout >/dev/null 2>&1 || true\n" : ""
        let command = """
        #!/bin/zsh
        export PATH=\(Self.quote(Tooling.searchPATH))
        \(reset)\(quoted) \(arguments.map(Self.quote).joined(separator: " "))
        echo
        echo "You can close this window."
        """
        try? command.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        Tooling.open(script)
    }

    private static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
