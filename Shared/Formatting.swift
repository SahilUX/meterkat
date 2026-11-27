import SwiftUI

enum UsageFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "Resets in 2h 14m", "Resets in 3d 4h", "Reset" or "No reset time".
    static func resetText(_ window: UsageWindow, now: Date = .now) -> String {
        guard let resetsAt = window.resetsAt else { return "No reset time" }
        if resetsAt <= now { return "Reset" }
        return "Resets in " + countdown(to: resetsAt, from: now)
    }

    /// "Resets in 4 hr 43 min (Sat, 3:09 AM)" — the long form used on the
    /// dashboard and in notifications.
    static func resetTextDetailed(_ window: UsageWindow, now: Date = .now) -> String {
        guard let resetsAt = window.resetsAt else { return "No reset time" }
        if resetsAt <= now { return "Reset" }
        let day = resetsAt.formatted(.dateTime.weekday(.abbreviated))
        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return "Resets in \(longCountdown(to: resetsAt, from: now)) (\(day), \(time))"
    }

    /// "4 hr 43 min", "5 days 22 hr", "12 min".
    static func longCountdown(to date: Date, from now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) \(days == 1 ? "day" : "days") \(hours) hr" }
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(max(minutes, 1)) min"
    }

    static func countdown(to date: Date, from now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// "$12.34", or "<$0.01" for a cost too small to round to a cent.
    static func usd(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "<$0.01" : value.formatted(.currency(code: "USD"))
    }

    /// "1.24B", "512K", "38".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func tint(for percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    static func providerTint(_ id: String) -> Color {
        switch ProviderID(rawValue: id) {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)   // #D97757
        case .openai: return Color(red: 0.06, green: 0.64, blue: 0.50)   // #10A37F
        case .opencode: return Color(red: 0.36, green: 0.51, blue: 0.96) // #5B82F5
        case .openrouter: return Color(red: 0.58, green: 0.40, blue: 0.95) // #9466F2
        case .copilot: return Color(red: 0.54, green: 0.34, blue: 0.90)    // #8957E5
        case .gemini: return Color(red: 0.11, green: 0.41, blue: 1.00)     // #1C69FF
        case .cursor: return Color(red: 0.55, green: 0.55, blue: 0.58)     // #8C8C94
        case .zai: return Color(red: 0.08, green: 0.72, blue: 0.65)        // #14B8A6
        case .kimi: return Color(red: 0.95, green: 0.35, blue: 0.35)     // Kimi coral
        case .minimax: return Color(red: 0.30, green: 0.52, blue: 0.98) // MiniMax blue
        case .bailian: return Color(red: 0.94, green: 0.47, blue: 0.20) // Alibaba orange
        case .deepseek: return Color(red: 0.20, green: 0.43, blue: 0.82) // DeepSeek blue
        case nil: return .accentColor
        }
    }
}
