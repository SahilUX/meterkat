import AppIntents
import WidgetKit

/// Provider picker for the configurable widgets.
enum ProviderChoice: String, AppEnum {
    case claude
    case openai
    case opencode
    case openrouter
    case copilot
    case gemini
    case cursor
    case zai
    case kimi
    case minimax
    case bailian
    case deepseek

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .claude: "Claude",
        .openai: "OpenAI",
        .opencode: "OpenCode",
        .openrouter: "OpenRouter",
        .copilot: "Copilot",
        .gemini: "Gemini",
        .cursor: "Cursor",
        .zai: "Z.ai",
        .kimi: "Moonshot Kimi",
        .minimax: "MiniMax",
        .bailian: "Alibaba Coding Plan",
        .deepseek: "DeepSeek API"
    ]

    var providerID: ProviderID {
        switch self {
        case .claude: return .claude
        case .openai: return .openai
        case .opencode: return .opencode
        case .openrouter: return .openrouter
        case .copilot: return .copilot
        case .gemini: return .gemini
        case .cursor: return .cursor
        case .zai: return .zai
        case .kimi: return .kimi
        case .minimax: return .minimax
        case .bailian: return .bailian
        case .deepseek: return .deepseek
        }
    }
}

/// Limit picker for the configurable "Usage Limit" widget.
enum WindowChoice: String, AppEnum {
    case fiveHour
    case weekly
    case fable
    case monthly
    case daily

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Limit"
    static var caseDisplayRepresentations: [WindowChoice: DisplayRepresentation] = [
        .fiveHour: "5-hour",
        .weekly: "Weekly",
        .fable: "Fable weekly",
        .monthly: "Monthly",
        .daily: "Daily"
    ]

    var slot: WindowSlot {
        switch self {
        case .fiveHour: return .fiveHour
        case .weekly: return .weekly
        case .fable: return .fable
        case .monthly: return .monthly
        case .daily: return .daily
        }
    }
}

struct UsageLimitIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Usage Limit"
    static var description = IntentDescription("Choose which provider and usage limit to show.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderChoice

    @Parameter(title: "Limit", default: .fiveHour)
    var window: WindowChoice

    /// The chosen limit, or the provider's first one if it has no such limit
    /// (OpenRouter and Gemini have only a daily one, Copilot and Cursor only a
    /// monthly one), so switching providers never
    /// leaves the widget on "Not on this plan".
    var slot: WindowSlot {
        let knownSlots = provider.providerID.knownSlots
        return knownSlots.contains(window.slot) ? window.slot : knownSlots.first ?? window.slot
    }
}

struct ProviderLimitsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Provider Limits"
    static var description = IntentDescription("Choose which provider's limits to show.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderChoice
}
