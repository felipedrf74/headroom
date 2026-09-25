import Foundation

/// How to sign in to a provider on this Mac: the CLI to run or the app to open.
struct ProviderLogin: Sendable {
    var cliExecutable: String?
    var loginArguments: [String] = []
    var installToolName: String
    var installURL: URL
    var appBundleIdentifiers: [String] = []
    var appNames: [String] = []
}

extension Provider {
    /// Nil for providers read with a pasted API key.
    var login: ProviderLogin? {
        switch self {
        case .grok:
            ProviderLogin(
                cliExecutable: "grok",
                loginArguments: ["login", "--device-auth"],
                installToolName: "grok",
                installURL: URL(string: "https://grok.com")!
            )
        case .grokBot:
            ProviderLogin(
                installToolName: "Grok Bot",
                installURL: URL(string: "https://grok.com/download")!,
                appBundleIdentifiers: ["com.anysphere.sand", "com.todesktop.230313mzl4w4u92"],
                appNames: ["Grok Bot", "Cursor"]
            )
        case .claude:
            ProviderLogin(
                cliExecutable: "claude",
                loginArguments: ["auth", "login", "--claudeai"],
                installToolName: "claude",
                installURL: URL(string: "https://code.claude.com/docs/setup")!,
                appBundleIdentifiers: ["com.anthropic.claudefordesktop"],
                appNames: ["Claude"]
            )
        case .openai:
            ProviderLogin(
                cliExecutable: "codex",
                loginArguments: ["login", "--device-auth"],
                installToolName: "codex",
                installURL: URL(string: "https://github.com/openai/codex")!,
                appBundleIdentifiers: ["com.openai.chat", "com.openai.codex"],
                appNames: ["ChatGPT"]
            )
        case .cursor:
            ProviderLogin(
                installToolName: "Cursor",
                installURL: URL(string: "https://cursor.com/download")!,
                appBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
                appNames: ["Cursor"]
            )
        case .copilot:
            ProviderLogin(
                cliExecutable: "gh",
                loginArguments: ["auth", "login", "--hostname", "github.com", "--web"],
                installToolName: "gh",
                installURL: URL(string: "https://cli.github.com")!
            )
        case .antigravity:
            ProviderLogin(
                installToolName: "Antigravity",
                installURL: URL(string: "https://antigravity.google/download")!,
                appNames: ["Antigravity"]
            )
        case .devin:
            ProviderLogin(
                installToolName: "Devin",
                installURL: URL(string: "https://devin.ai/download")!,
                appNames: ["Devin", "Windsurf"]
            )
        case .zai, .kimiCode, .minimax, .opencodeGo, .openrouter, .deepseek, .moonshot, .vercelGateway, .openaiOrg, .anthropicOrg, .xaiOrg:
            nil
        }
    }

    var signInTitle: String { usesAPIKey ? "Add Key" : "Sign In" }
    var cliExecutable: String? { login?.cliExecutable }
    var loginArguments: [String] { login?.loginArguments ?? [] }
    var installToolName: String { login?.installToolName ?? displayName }

    /// The app or CLI whose usage endpoint Tokenroom reads, as people call it.
    var toolName: String {
        switch self {
        case .grok: "Grok Build"
        case .grokBot, .cursor: "Cursor"
        case .claude: "Claude Code"
        case .openai: "Codex"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        case .devin: "Devin"
        default: displayName
        }
    }
    var installURL: URL { login?.installURL ?? key?.createURL ?? TokenroomIdentity.repositoryURL }
    var appBundleIdentifiers: [String] { login?.appBundleIdentifiers ?? [] }
    var appNames: [String] { login?.appNames ?? [] }
}

struct MenuMeter: Equatable, Identifiable, Sendable {
    var provider: Provider
    var valueText: String
    var remaining: Double
    var usedPercent: Double
    var isStale: Bool
    var isPlaceholder: Bool

    var id: Provider { provider }
}
