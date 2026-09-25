import AppIntents
import WidgetKit

/// Which provider a widget leads with.
enum ProviderOption: String, AppEnum {
    case automatic
    case claude, openai, grok, grokBot, cursor, copilot, antigravity, devin
    case zai, kimiCode, minimax, opencodeGo
    case openrouter, deepseek, moonshot, vercelGateway
    case openaiOrg, anthropicOrg, xaiOrg

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] = [
        .automatic: "Most Urgent",
        .claude: "Claude",
        .openai: "OpenAI (Codex)",
        .grok: "Grok Build",
        .grokBot: "Grok Bot",
        .cursor: "Cursor",
        .copilot: "GitHub Copilot",
        .antigravity: "Antigravity",
        .devin: "Devin",
        .zai: "Z.ai",
        .kimiCode: "Kimi Code",
        .minimax: "MiniMax",
        .opencodeGo: "OpenCode Go",
        .openrouter: "OpenRouter",
        .deepseek: "DeepSeek",
        .moonshot: "Moonshot",
        .vercelGateway: "Vercel AI Gateway",
        .openaiOrg: "OpenAI API",
        .anthropicOrg: "Anthropic API",
        .xaiOrg: "xAI API",
    ]

    /// Nil for Most Urgent.
    var providerID: String? {
        self == .automatic ? nil : rawValue
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Provider"
    static let description = IntentDescription("The provider this widget shows first.")

    @Parameter(title: "Provider", default: .automatic)
    var provider: ProviderOption

    init() {}

    init(provider: ProviderOption) {
        self.provider = provider
    }
}

/// The refresh button on medium and large widgets.
struct RefreshReadingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Usage"
    static let description = IntentDescription("Checks your usage again.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        _ = await WidgetRefresher.cache(force: true)
        return .result()
    }
}
