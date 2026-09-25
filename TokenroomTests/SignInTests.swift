import XCTest
@testable import Tokenroom

final class SignInTests: XCTestCase {
    func testToolingResolveFindsExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("tokenroom-fake-cli")
        FileManager.default.createFile(
            atPath: binary.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )

        XCTAssertEqual(
            Tooling.resolve("tokenroom-fake-cli", extraDirectories: [directory])?.resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path
        )
        XCTAssertNil(Tooling.resolve("tokenroom-missing-cli-\(UUID().uuidString)", extraDirectories: [directory]))
    }

    func testSessionStampMissingFiles() {
        let previousGrok = ProcessInfo.processInfo.environment["GROK_HOME"]
        let previousCodex = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previousGrok {
                setenv("GROK_HOME", previousGrok, 1)
            } else {
                unsetenv("GROK_HOME")
            }
            if let previousCodex {
                setenv("CODEX_HOME", previousCodex, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        setenv("GROK_HOME", empty.path, 1)
        setenv("CODEX_HOME", empty.path, 1)
        XCTAssertNil(CredentialReaders.sessionStamp(.grok))
        XCTAssertFalse(CredentialReaders.hasSession(.grok))
        XCTAssertNil(CredentialReaders.sessionStamp(.openai))
    }

    func testISOFormatterRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_788_856_564)
        let encoded = JSONFlex.isoString(from: date)
        let decoded = JSONFlex.parseISO(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    func testResolveClaudeUsesNewestVersionWhenShimIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let desktop = root.appendingPathComponent("claude-code", isDirectory: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = versions.appendingPathComponent("2.1.259")
        let newer = desktop.appendingPathComponent("2.1.280/claude.app/Contents/MacOS/claude")
        try FileManager.default.createDirectory(at: newer.deletingLastPathComponent(), withIntermediateDirectories: true)
        let macho = Data([0xCF, 0xFA, 0xED, 0xFE])
        FileManager.default.createFile(atPath: older.path, contents: macho, attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: newer.path, contents: macho, attributes: [.posixPermissions: 0o755])

        let resolved = Tooling.resolveClaude(
            extraDirectories: [root],
            versionRoots: [versions, desktop]
        )
        XCTAssertEqual(resolved?.resolvingSymlinksInPath().path, newer.resolvingSymlinksInPath().path)
    }

    func testProviderLoginMetadata() {
        XCTAssertEqual(Provider.grok.cliExecutable, "grok")
        XCTAssertEqual(Provider.claude.loginArguments, ["auth", "login", "--claudeai"])
        XCTAssertEqual(Provider.openai.cliExecutable, "codex")
        XCTAssertNil(Provider.cursor.cliExecutable)
        XCTAssertEqual(Provider.grokBot.appNames, ["Grok Bot", "Cursor"])
        XCTAssertEqual(Provider.grokBot.installToolName, "Grok Bot")
        XCTAssertEqual(Provider.grokBot.appBundleIdentifiers.first, "com.anysphere.sand")
        XCTAssertTrue(Provider.grokBot.signInHint.contains("Grok Bot"))
    }

    func testSnapshotsDoNotEncodeIdentity() throws {
        let snapshot = QuotaSnapshot(
            provider: .grok,
            usedPercent: 12,
            resetsAt: Date(timeIntervalSince1970: 100),
            fetchedAt: Date(timeIntervalSince1970: 50),
            primaryTitle: "Weekly",
            windows: [
                QuotaWindow(id: "primary", kind: .weekly, title: "Weekly", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 100)),
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.lowercased().contains("email"))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.contains("user_id"))
        XCTAssertTrue(json.contains("usedPercent"))
    }
}
