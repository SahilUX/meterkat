import Foundation

// What the Mac app adds to the shared contract in Shared/UsageModels.swift:
// the menu bar's ordering and titles, and the loopback-only /v1/pairing.

extension ProviderUsage {
    /// Display order for known providers; unknown ids follow in companion order.
    static let order = ProviderID.allCases.map(\.rawValue)

    /// Up to three windows for the menu bar icon: session, weekly, model
    /// windows, monthly, daily. None unless the provider is `ok`, so signed
    /// out providers stay out of the menu bar.
    var menuBarWindows: [UsageWindow] {
        guard isOK else { return [] }
        let sorted = windows.enumerated()
            .sorted { ($0.element.displayRank, $0.offset) < ($1.element.displayRank, $1.offset) }
            .map(\.element)
        return Array(sorted.prefix(3))
    }

    static func sorted(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        let rank = { (id: String) in order.firstIndex(of: id) ?? order.count }
        return providers.enumerated()
            .sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }
            .map(\.element)
    }
}

extension UsageWindow {
    /// Menu bar order: session, weekly, model windows, monthly, daily, others.
    var displayRank: Int {
        switch id {
        case "five_hour": return 0
        case "weekly": return 1
        case "monthly": return 3
        case "daily": return 4
        default:
            if id.hasPrefix("monthly_") { return 3 }
            if id.hasPrefix("daily_") { return 4 }
            return kind == "model" || id.hasPrefix("weekly_") || id.hasPrefix("five_hour_") ? 2 : 5
        }
    }

    /// "Current session", "Weekly limit", "Monthly limit", "Daily limit",
    /// "Free requests" (a daily window with its own label), "<model> weekly",
    /// "<model> daily", "Chat monthly".
    var title: String {
        switch id {
        case "five_hour": return "Current session"
        case "weekly": return "Weekly limit"
        case "monthly": return isGeneric(label, period: "month") ? "Monthly limit" : label
        case "daily": return isGeneric(label, period: "da") ? "Daily limit" : label
        default:
            if id.hasPrefix("weekly_") { return titled(label, period: "weekly") }
            if id.hasPrefix("five_hour_") { return "\(label) session" }
            if id.hasPrefix("monthly_") { return titled(label, period: "monthly") }
            if id.hasPrefix("daily_") { return titled(label, period: "daily") }
            return label
        }
    }

    /// A label that only names the period ("Monthly", "Day", "Daily limit").
    private func isGeneric(_ label: String, period: String) -> Bool {
        let words = label.lowercased().split(separator: " ")
        return words.isEmpty || words.allSatisfy { $0.hasPrefix(period) || $0 == "limit" }
    }

    /// "Fable weekly", unless the label already says the period.
    private func titled(_ label: String, period: String) -> String {
        label.localizedCaseInsensitiveContains(period) ? label : "\(label) \(period)"
    }
}

extension BarMode {
    /// Follows the percentage: "32% used", "68% left".
    var suffix: String { self == .used ? "used" : "left" }
}

extension UsageStyle {
    var symbol: String { self == .bars ? "chart.bar.xaxis" : "chart.xyaxis.line" }

    static var saved: UsageStyle {
        UsageStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.panelStyle) ?? "") ?? .bars
    }
}

/// GET /v1/pairing, which only answers this machine.
struct PairingInfo: Decodable {
    var host: String?
    var version: String?
    var local: String?
    var remote: String?
    var link: String
}
