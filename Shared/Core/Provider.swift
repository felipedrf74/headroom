import Foundation

/// Every provider this build knows. Raw values live in settings, caches, and the iCloud relay:
/// never rename or reuse one.
enum Provider: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case grok
    case grokBot
    case claude
    case openai
    case cursor

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
                expiredHint: "Session expired. Run claude once to refresh it."
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
        }
    }

    var displayName: String { descriptor.displayName }
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
}
