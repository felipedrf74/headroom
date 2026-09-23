import AppKit
import Foundation

enum Tooling {
    static var searchPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "\(home)/.grok/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var seen = Set<String>()
        var parts: [String] = []
        for part in extras + inherited.split(separator: ":").map(String.init) where !part.isEmpty {
            if seen.insert(part).inserted {
                parts.append(part)
            }
        }
        return parts.joined(separator: ":")
    }

    static func resolveProviderCLI(_ provider: Provider, extraDirectories: [URL] = [], claudeVersionRoots: [URL]? = nil) -> URL? {
        switch provider {
        case .claude:
            resolveClaude(extraDirectories: extraDirectories, versionRoots: claudeVersionRoots)
        default:
            provider.cliExecutable.flatMap { resolve($0, extraDirectories: extraDirectories) }
        }
    }

    static func resolveClaude(extraDirectories: [URL] = [], versionRoots: [URL]? = nil) -> URL? {
        if let direct = resolve("claude", extraDirectories: extraDirectories) {
            return direct
        }
        let roots = versionRoots ?? defaultClaudeVersionRoots()
        let fileManager = FileManager.default
        var best: (parts: [Int], url: URL)?
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                let version = child.lastPathComponent
                let candidates = [
                    child,
                    child.appendingPathComponent("claude.app/Contents/MacOS/claude"),
                ]
                for url in candidates where isMacExecutable(url) {
                    let parts = versionParts(version)
                    if let best, !versionIsNewer(parts, than: best.parts) {
                        continue
                    }
                    best = (parts, url)
                }
            }
        }
        return best?.url
    }

    static func resolve(_ name: String, extraDirectories: [URL] = []) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = extraDirectories
        directories.append(contentsOf: [
            home.appendingPathComponent(".grok/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        ])
        let fileManager = FileManager.default
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func applicationURL(bundleIdentifiers: [String], names: [String]) -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        let fileManager = FileManager.default
        let homeApps = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        for name in names {
            let bundled = "\(name).app"
            let system = URL(fileURLWithPath: "/Applications/\(bundled)")
            if fileManager.fileExists(atPath: system.path) {
                return system
            }
            let home = homeApps.appendingPathComponent(bundled)
            if fileManager.fileExists(atPath: home.path) {
                return home
            }
        }
        return nil
    }

    private static func defaultClaudeVersionRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/share/claude/versions", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true),
        ]
    }

    private static func versionParts(_ name: String) -> [Int] {
        name.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func versionIsNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        let count = max(candidate.count, current.count)
        for index in 0..<count {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func isMacExecutable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: url.path) else { return false }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        if magic.count >= 4, magic[0] == 0x7F, magic[1] == 0x45, magic[2] == 0x4C, magic[3] == 0x46 {
            return false
        }
        return true
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openApplication(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
