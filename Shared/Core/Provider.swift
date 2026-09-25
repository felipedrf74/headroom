import Foundation

/// Every provider this build knows. Raw values live in settings, caches, and the iCloud relay:
/// never rename or reuse one.
enum Provider: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case grok
    case grokBot
    case claude
    case openai
    case cursor
    case copilot
    case antigravity
    case devin
    case zai
    case kimiCode
    case minimax
    case opencodeGo
    case openrouter
    case deepseek
    case moonshot
    case vercelGateway
    case openaiOrg
    case anthropicOrg
    case xaiOrg

    var id: String { rawValue }

    /// Providers Headroom 1.x shipped with. Settings written by 1.x already knew about them.
    static let legacy: Set<Provider> = [.grok, .grokBot, .claude, .openai, .cursor]
}

/// What a provider is, in one place. Adding a provider means one entry in `Provider.descriptor`.
struct ProviderDescriptor: Sendable {
    enum Category: String, Sendable {
        /// Subscription quota (weekly, session, or billing-cycle windows).
        case subscription
        /// Pay-as-you-go credit balance, read with an API key.
        case apiBalance
        /// Organization spend, read with an admin key.
        case orgSpend
    }

    /// Where a provider's credential comes from.
    enum Access: Sendable {
        /// Another tool's login on the Mac (a CLI or an app). The iPhone sees it through the relay.
        case localLogin
        /// A pasted key, or on the Mac the key a coding tool is already configured with.
        case codingPlanKey
        /// A pasted key only.
        case pastedKey
    }

    var displayName: String
    var shortName: String
    /// One letter for the Mac's fallback icon tile.
    var letter: String
    /// Up to two letters for the monogram mark on iPhone and Apple Watch (no brand logos there).
    var monogram: String
    /// Monogram tint, `#RRGGBB`.
    var tintHex: String
    var category: Category = .subscription
    /// Whether a provider this install has never seen starts enabled. Otherwise it is enabled
    /// only when a local session is detected.
    var enabledByDefault: Bool = false
    /// Mac popover icon in the asset catalog; nil falls back to the letter tile.
    var assetName: String?
    /// Mac menu-bar glyph; nil falls back to a drawn mark.
    var menuGlyphName: String?
    var signInHint: String
    var expiredHint: String
    /// Checks closer together than this are skipped, even when forced (rate-limited endpoints).
    var minimumInterval: TimeInterval = 0
    /// For providers read with a pasted API key.
    var key: KeySpec? = nil

    var access: Access {
        guard let key else { return .localLogin }
        return key.isCodingPlan ? .codingPlanKey : .pastedKey
    }
}

/// How a provider's API key is entered.
struct KeySpec: Sendable {
    var label = "API key"
    /// Where to create a key.
    var createURL: URL
    /// Start of a typical key, shown as a hint.
    var prefixHint = ""
    /// Accounts in separate regions, e.g. Moonshot's global and China platforms.
    var regions: [String] = []
    /// Org-wide admin or management keys get an extra warning.
    var isAdmin = false
    /// A subscription's key that a coding tool on the Mac may already hold (Claude Code
    /// settings, the Kimi Code CLI, OpenCode). Pasting one is optional there.
    var isCodingPlan = false
}

extension Provider {
    var descriptor: ProviderDescriptor {
        switch self {
        case .grok:
            ProviderDescriptor(
                displayName: "Grok Build",
                shortName: "Build",
                letter: "G",
                monogram: "G",
                tintHex: "#8E8E93",
                enabledByDefault: true,
                assetName: "ProviderBuild",
                menuGlyphName: "GlyphBuild",
                signInHint: "Sign in with grok login to see usage.",
                // The Grok CLI owns its session; Tokenroom never refreshes it.
                expiredHint: "Session expired. Run grok once to refresh it."
            )
        case .grokBot:
            ProviderDescriptor(
                displayName: "Grok Bot",
                shortName: "Bot",
                letter: "B",
                monogram: "GB",
                tintHex: "#5E5CE6",
                enabledByDefault: true,
                assetName: "ProviderBot",
                menuGlyphName: "GlyphBot",
                signInHint: "Sign in to Grok Bot to see usage.",
                expiredHint: "Session expired. Sign in to Grok Bot again."
            )
        case .claude:
            ProviderDescriptor(
                displayName: "Claude",
                shortName: "Claude",
                letter: "C",
                monogram: "C",
                tintHex: "#D97757",
                enabledByDefault: true,
                assetName: "ProviderClaude",
                signInHint: "Sign in with claude login to see usage.",
                // Claude Code owns its session; Tokenroom never refreshes it.
                expiredHint: "Session expired. Run claude once to refresh it.",
                // The usage endpoint answers 429 to more than about one call every few minutes.
                minimumInterval: 5 * 60
            )
        case .openai:
            ProviderDescriptor(
                displayName: "OpenAI",
                shortName: "GPT",
                letter: "O",
                monogram: "O",
                tintHex: "#10A37F",
                enabledByDefault: true,
                assetName: "ProviderGPT",
                menuGlyphName: "GlyphGPT",
                signInHint: "Sign in with codex login to see usage.",
                expiredHint: "Session expired. Sign in with codex login again."
            )
        case .cursor:
            ProviderDescriptor(
                displayName: "Cursor",
                shortName: "Cursor",
                letter: "U",
                monogram: "Cu",
                tintHex: "#636366",
                enabledByDefault: true,
                assetName: "ProviderCursor",
                signInHint: "Sign in to Cursor to see usage.",
                expiredHint: "Session expired. Sign in to Cursor again."
            )
        case .copilot:
            ProviderDescriptor(
                displayName: "GitHub Copilot",
                shortName: "Copilot",
                letter: "H",
                monogram: "GH",
                tintHex: "#24292F",
                signInHint: "Sign in with gh auth login, or in a Copilot editor extension, to see usage.",
                expiredHint: "GitHub session expired. Run gh auth login again."
            )
        case .antigravity:
            ProviderDescriptor(
                displayName: "Antigravity",
                shortName: "Antigravity",
                letter: "A",
                monogram: "AG",
                tintHex: "#4285F4",
                signInHint: "Sign in to Antigravity, and install agy 1.1.11 or later, to see usage.",
                expiredHint: "Session expired. Open Antigravity to sign in again.",
                // Each check runs the agy CLI, which can take a while.
                minimumInterval: 5 * 60
            )
        case .devin:
            ProviderDescriptor(
                displayName: "Devin",
                shortName: "Devin",
                letter: "D",
                monogram: "DV",
                tintHex: "#2F6F5E",
                signInHint: "Sign in to Devin Desktop to see usage.",
                expiredHint: "Session expired. Sign in to Devin Desktop again."
            )
        case .zai:
            ProviderDescriptor(
                displayName: "Z.ai",
                shortName: "GLM",
                letter: "Z",
                monogram: "Z",
                tintHex: "#2D5BFF",
                signInHint: "Add a Z.ai API key, or use a GLM Coding Plan key in Claude Code on this Mac.",
                expiredHint: "Z.ai rejected this key. It may belong to the other region.",
                key: KeySpec(createURL: URL(string: "https://z.ai/manage-apikey/apikey-list")!, regions: ["Global", "China"], isCodingPlan: true)
            )
        case .kimiCode:
            ProviderDescriptor(
                displayName: "Kimi Code",
                shortName: "Kimi",
                letter: "K",
                monogram: "K",
                tintHex: "#1F2937",
                signInHint: "Sign in with the kimi CLI (Kimi Code), or add a Kimi Code API key.",
                // The CLI owns its login; Tokenroom never refreshes it.
                expiredHint: "Session expired. Run kimi once to refresh it, or add an API key.",
                key: KeySpec(createURL: URL(string: "https://www.kimi.com/code/console")!, prefixHint: "sk-kimi-", regions: ["Global", "China"], isCodingPlan: true)
            )
        case .minimax:
            ProviderDescriptor(
                displayName: "MiniMax",
                shortName: "MiniMax",
                letter: "M",
                monogram: "MM",
                tintHex: "#E2167E",
                signInHint: "Add a MiniMax Coding Plan key, or use one in Claude Code on this Mac.",
                expiredHint: "MiniMax rejected this key. It may belong to the other region.",
                key: KeySpec(createURL: URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key")!, regions: ["Global", "China"], isCodingPlan: true)
            )
        case .opencodeGo:
            ProviderDescriptor(
                displayName: "OpenCode Go",
                shortName: "OpenCode",
                letter: "O",
                monogram: "OC",
                tintHex: "#211E1E",
                signInHint: "Sign in to OpenCode Go in OpenCode, or add its API key.",
                expiredHint: "OpenCode rejected this key. Sign in to OpenCode again.",
                key: KeySpec(createURL: URL(string: "https://opencode.ai/go")!, isCodingPlan: true)
            )
        case .openrouter:
            ProviderDescriptor(
                displayName: "OpenRouter",
                shortName: "OpenRouter",
                letter: "R",
                monogram: "OR",
                tintHex: "#6467F2",
                category: .apiBalance,
                signInHint: "Add an OpenRouter API key to see usage.",
                expiredHint: "Couldn't use this OpenRouter key. Add a new one in Settings.",
                key: KeySpec(createURL: URL(string: "https://openrouter.ai/settings/keys")!, prefixHint: "sk-or-")
            )
        case .deepseek:
            ProviderDescriptor(
                displayName: "DeepSeek",
                shortName: "DeepSeek",
                letter: "D",
                monogram: "DS",
                tintHex: "#4D6BFE",
                category: .apiBalance,
                signInHint: "Add a DeepSeek API key to see your balance.",
                expiredHint: "Couldn't use this DeepSeek key. Add a new one in Settings.",
                key: KeySpec(createURL: URL(string: "https://platform.deepseek.com/api_keys")!, prefixHint: "sk-")
            )
        case .moonshot:
            ProviderDescriptor(
                displayName: "Moonshot",
                shortName: "Moonshot",
                letter: "M",
                monogram: "MS",
                tintHex: "#16191E",
                category: .apiBalance,
                signInHint: "Add a Moonshot API key to see your balance.",
                expiredHint: "Couldn't use this Moonshot key. It may belong to the other region.",
                key: KeySpec(createURL: URL(string: "https://platform.kimi.ai/console/api-keys")!, prefixHint: "sk-", regions: ["Global", "China"])
            )
        case .vercelGateway:
            ProviderDescriptor(
                displayName: "Vercel AI Gateway",
                shortName: "Vercel",
                letter: "V",
                monogram: "V",
                tintHex: "#000000",
                category: .apiBalance,
                signInHint: "Add an AI Gateway API key to see your credits.",
                expiredHint: "Couldn't use this AI Gateway key. Add a new one in Settings.",
                key: KeySpec(createURL: URL(string: "https://vercel.com/dashboard/ai-gateway/api-keys")!)
            )
        case .openaiOrg:
            ProviderDescriptor(
                displayName: "OpenAI API",
                shortName: "OpenAI API",
                letter: "O",
                monogram: "OA",
                tintHex: "#0E7C66",
                category: .orgSpend,
                signInHint: "Add an OpenAI Admin key to see this month's spend.",
                expiredHint: "Couldn't use this key. It needs to be an OpenAI Admin key.",
                key: KeySpec(label: "Admin key", createURL: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!, prefixHint: "sk-admin-", isAdmin: true)
            )
        case .anthropicOrg:
            ProviderDescriptor(
                displayName: "Anthropic API",
                shortName: "Anthropic API",
                letter: "A",
                monogram: "AN",
                tintHex: "#B85C38",
                category: .orgSpend,
                signInHint: "Add an Anthropic Admin key to see this month's spend.",
                expiredHint: "Couldn't use this key. It needs to be an Anthropic Admin key.",
                // Cost reports update slowly; polling faster only spends rate limit.
                minimumInterval: 15 * 60,
                key: KeySpec(label: "Admin key", createURL: URL(string: "https://console.anthropic.com/settings/admin-keys")!, prefixHint: "sk-ant-admin", isAdmin: true)
            )
        case .xaiOrg:
            ProviderDescriptor(
                displayName: "xAI API",
                shortName: "xAI API",
                letter: "X",
                monogram: "XA",
                tintHex: "#3A3A3C",
                category: .orgSpend,
                signInHint: "Add an xAI management key to see spend and credits.",
                expiredHint: "Couldn't use this key. It needs to be an xAI management key.",
                key: KeySpec(label: "Management key", createURL: URL(string: "https://console.x.ai")!, isAdmin: true)
            )
        }
    }

    var displayName: String { descriptor.displayName }
    var key: KeySpec? { descriptor.key }
    var usesAPIKey: Bool { descriptor.key != nil }
    var access: ProviderDescriptor.Access { descriptor.access }
    var shortName: String { descriptor.shortName }
    var letter: String { descriptor.letter }
    var monogram: String { descriptor.monogram }
    var tintHex: String { descriptor.tintHex }
    var category: ProviderDescriptor.Category { descriptor.category }
    var enabledByDefault: Bool { descriptor.enabledByDefault }
    var assetName: String? { descriptor.assetName }
    var menuGlyphName: String? { descriptor.menuGlyphName }
    var signInHint: String { descriptor.signInHint }
    var expiredHint: String { descriptor.expiredHint }
    var minimumInterval: TimeInterval { descriptor.minimumInterval }
}
