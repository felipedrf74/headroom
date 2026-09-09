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

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openApplication(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
