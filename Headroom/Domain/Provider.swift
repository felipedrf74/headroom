import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case grok
    case grokBot
    case claude
    case openai
    case cursor

    var id: String { rawValue }

    var letter: String {
        switch self {
        case .grok: "G"
        case .grokBot: "B"
        case .claude: "C"
        case .openai: "O"
        case .cursor: "U"
        }
    }

    var shortName: String {
        switch self {
        case .grok: "Build"
        case .grokBot: "Bot"
        case .claude: "Claude"
        case .openai: "GPT"
        case .cursor: "Cursor"
        }
    }

    var displayName: String {
        switch self {
        case .grok: "Grok Build"
        case .grokBot: "Grok Bot"
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .cursor: "Cursor"
        }
    }

    var assetName: String {
        switch self {
        case .grok: "ProviderBuild"
        case .grokBot: "ProviderBot"
        case .claude: "ProviderClaude"
        case .openai: "ProviderGPT"
        case .cursor: "ProviderCursor"
        }
    }

    var menuGlyphName: String? {
        switch self {
        case .grok: "GlyphBuild"
        case .grokBot: "GlyphBot"
        case .openai: "GlyphGPT"
        default: nil
        }
    }

    var signInHint: String {
        switch self {
        case .grok: "Sign in with grok login to see usage."
        case .grokBot: "Sign in to Grok Bot to see usage."
        case .claude: "Sign in with claude login to see usage."
        case .openai: "Sign in with codex login to see usage."
        case .cursor: "Sign in to Cursor to see usage."
        }
    }

    var expiredHint: String {
        switch self {
        case .grok: "Session expired. Sign in with grok login again."
        case .grokBot: "Session expired. Sign in to Grok Bot again."
        case .claude: "Session expired. Sign in with claude login again."
        case .openai: "Session expired. Sign in with codex login again."
        case .cursor: "Session expired. Sign in to Cursor again."
        }
    }

    var signInTitle: String { "Sign In" }

    var cliExecutable: String? {
        switch self {
        case .grok: "grok"
        case .claude: "claude"
        case .openai: "codex"
        case .grokBot, .cursor: nil
        }
    }

    var loginArguments: [String] {
        switch self {
        case .grok: ["login", "--device-auth"]
        case .claude: ["auth", "login", "--claudeai"]
        case .openai: ["login", "--device-auth"]
        case .grokBot, .cursor: []
        }
    }

    var installToolName: String {
        switch self {
        case .grok: "grok"
        case .grokBot: "Grok Bot"
        case .cursor: "Cursor"
        case .claude: "claude"
        case .openai: "codex"
        }
    }

    var installURL: URL {
        switch self {
        case .grok:
            URL(string: "https://grok.com")!
        case .grokBot:
            URL(string: "https://grok.com/download")!
        case .cursor:
            URL(string: "https://cursor.com/download")!
        case .claude:
            URL(string: "https://code.claude.com/docs/setup")!
        case .openai:
            URL(string: "https://github.com/openai/codex")!
        }
    }

    var appBundleIdentifiers: [String] {
        switch self {
        case .grokBot:
            ["com.anysphere.sand", "com.todesktop.230313mzl4w4u92"]
        case .cursor:
            ["com.todesktop.230313mzl4w4u92"]
        case .claude:
            ["com.anthropic.claudefordesktop"]
        case .openai:
            ["com.openai.chat", "com.openai.codex"]
        case .grok:
            []
        }
    }

    var appNames: [String] {
        switch self {
        case .grokBot: ["Grok Bot", "Cursor"]
        case .cursor: ["Cursor"]
        case .claude: ["Claude"]
        case .openai: ["ChatGPT"]
        case .grok: []
        }
    }
}

enum WindowKind: String, Codable, Sendable {
    case weekly
    case session
    case billingCycle
    case pool
}

struct QuotaWindow: Equatable, Codable, Sendable, Identifiable {
    var id: String
    var kind: WindowKind
    var title: String
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Equatable, Codable, Sendable {
    var provider: Provider
    var usedPercent: Double
    var resetsAt: Date?
    var fetchedAt: Date
    var primaryTitle: String
    var windows: [QuotaWindow]

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

enum ProviderError: Error, Equatable, Sendable {
    case signedOut(String)
    case expired(String)
    case unreachable
    case parse
}

enum ProviderStatus: Equatable, Sendable {
    case loading
    case live(QuotaSnapshot)
    case stale(QuotaSnapshot)
    case signedOut(String)
    case expired(String)
    case unreachable(cached: QuotaSnapshot?)

    var snapshot: QuotaSnapshot? {
        switch self {
        case .live(let snapshot), .stale(let snapshot):
            snapshot
        case .unreachable(let cached):
            cached
        default:
            nil
        }
    }

    var isStale: Bool {
        switch self {
        case .stale, .unreachable(cached: .some):
            true
        default:
            false
        }
    }
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
