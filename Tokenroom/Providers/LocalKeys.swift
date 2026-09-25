import Foundation

/// Coding-plan keys that tools on this Mac already hold: Claude Code pointed at Z.ai, MiniMax, or
/// Kimi; the Kimi Code CLI's login; OpenCode's Go key. Read in place on every check, never copied,
/// refreshed, or rewritten. All of it blocks: call through `BlockingIO`.
enum LocalKeys {
    /// The key to use when none was pasted. Throws when one was found but can't be used.
    static func credential(for provider: Provider) throws -> APIKeyCredential? {
        guard let found = find(provider) else { return nil }
        return try found.credential.get()
    }

    /// The file holding that key, so a sign-in can be noticed without reading the key into a stamp.
    static func sourceFile(for provider: Provider) -> URL? {
        find(provider)?.file
    }

    struct Found {
        var credential: Result<APIKeyCredential, ProviderError>
        var file: URL
    }

    static func find(
        _ provider: Provider,
        claudeDirectory: URL = LocalSources.defaultClaudeDirectory,
        kimiHome: URL = LocalKeys.kimiHome,
        opencodeData: URL = LocalKeys.opencodeData,
        now: Date = .now
    ) -> Found? {
        switch provider {
        case .zai:
            return claudeSettings(global: ["api.z.ai"], china: ["open.bigmodel.cn"], claudeDirectory: claudeDirectory)
        case .minimax:
            return claudeSettings(global: ["api.minimax.io"], china: ["api.minimaxi.com"], claudeDirectory: claudeDirectory)
        case .kimiCode:
            return kimiCLI(home: kimiHome, now: now)
                ?? claudeSettings(global: ["api.kimi.ai"], china: ["api.kimi.com"], claudeDirectory: claudeDirectory)
        case .opencodeGo:
            let file = opencodeData.appendingPathComponent("auth.json")
            return LocalSources.jsonString(at: ["opencode-go", "key"], in: file).map {
                Found(credential: .success(APIKeyCredential(key: $0, source: "opencode")), file: file)
            }
        default:
            return nil
        }
    }

    /// Claude Code configured with a coding plan's Anthropic-compatible endpoint. The host says
    /// which region issued the key.
    private static func claudeSettings(global: [String], china: [String], claudeDirectory: URL) -> Found? {
        let file = claudeDirectory.appendingPathComponent("settings.json")
        for (region, hosts) in [("Global", global), ("China", china)] {
            if let key = LocalSources.claudeSettingsKey(forHosts: hosts, claudeDirectory: claudeDirectory) {
                return Found(credential: .success(APIKeyCredential(key: key, region: region, source: "claude-settings")), file: file)
            }
        }
        return nil
    }

    /// The Kimi Code CLI's login, used only while its access token is valid. The CLI refreshes it
    /// the next time it runs; Tokenroom never touches the refresh token.
    private static func kimiCLI(home: URL, now: Date) -> Found? {
        let file = home.appendingPathComponent("credentials/kimi-code.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONFlex.object(from: data),
              let token = JSONFlex.string(root["access_token"]), !token.isEmpty
        else { return nil }
        if let expiresAt = JSONFlex.date(root["expires_at"]), expiresAt.timeIntervalSince(now) <= 60 {
            return Found(credential: .failure(.expired(Provider.kimiCode.expiredHint)), file: file)
        }
        // The CLI signs in on kimi.com and reads usage there.
        return Found(credential: .success(APIKeyCredential(key: token, region: "China", source: "kimi-cli")), file: file)
    }

    static var kimiHome: URL {
        if let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static var opencodeData: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let data = environment["XDG_DATA_HOME"], !data.isEmpty {
            return URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// What Settings says about a key found on this Mac, shown when none was pasted.
    static func settingsCaption(for provider: Provider) -> String? {
        guard provider.access == .codingPlanKey, let found = find(provider) else { return nil }
        switch found.credential {
        case .success(let credential):
            switch credential.source {
            case "claude-settings": return "Using the key in Claude Code settings."
            case "kimi-cli": return "Using your kimi CLI login."
            case "opencode": return "Using the key OpenCode keeps."
            default: return nil
            }
        case .failure:
            return "Your kimi CLI login expired. Run kimi once to refresh it."
        }
    }

    /// What the card says about a key Tokenroom didn't store itself.
    static func caption(forSource source: String?) -> String? {
        switch source {
        case "claude-settings": "Key from Claude Code settings"
        case "kimi-cli": "Signed in with the kimi CLI"
        case "opencode": "Key from OpenCode"
        case "copilot-token": "With your fine-grained token"
        default: nil
        }
    }
}
