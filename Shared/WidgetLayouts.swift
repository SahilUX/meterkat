import SwiftUI
import WidgetKit

// Widget layouts as plain views: everything they draw comes in through their
// properties, so the widget extension and the app's DEBUG widget gallery
// render exactly the same thing.

// MARK: - Family

/// The sizes the layouts draw for. Mirrors `WidgetFamily`, which only the
/// widget extension can read from the environment.
enum WidgetLayoutFamily: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case accessoryRectangular
    case accessoryCircular
    case accessoryInline

    var id: String { rawValue }

    /// Lock Screen families, which render in vibrant (monochrome) mode.
    var isAccessory: Bool {
        switch self {
        case .small, .medium, .large: return false
        case .accessoryRectangular, .accessoryCircular, .accessoryInline: return true
        }
    }

    /// Size on an iPhone 13, in points.
    var size: CGSize {
        switch self {
        case .small: return CGSize(width: 158, height: 158)
        case .medium: return CGSize(width: 338, height: 158)
        case .large: return CGSize(width: 338, height: 354)
        case .accessoryRectangular: return CGSize(width: 160, height: 72)
        case .accessoryCircular: return CGSize(width: 72, height: 72)
        case .accessoryInline: return CGSize(width: 234, height: 26)
        }
    }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .accessoryRectangular: return "Rectangular"
        case .accessoryCircular: return "Circular"
        case .accessoryInline: return "Inline"
        }
    }
}

extension View {
    /// Widgets have fixed frames, so text stops growing at xLarge, as the
    /// system's own widgets do; past that, layouts would clip or truncate.
    func widgetDynamicTypeLimit() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

// MARK: - Text

enum WidgetText {
    static let turnedOff = "Turned off in \(AppConstants.appName)"
    static let notPaired = "Open \(AppConstants.appName) to pair with your computer"

    static func countdown(_ window: UsageWindow, at date: Date) -> String {
        guard let reset = window.resetsAt else { return "—" }
        if reset <= date { return "Reset" }
        return UsageFormat.countdown(to: reset, from: date)
    }

    static func providerName(_ id: ProviderID, _ usage: ProviderUsage?) -> String {
        usage?.name ?? id.displayName
    }

    /// Why a window can't be shown.
    static func unavailable(snapshot: UsageSnapshot?, usage: ProviderUsage?) -> String {
        guard snapshot != nil else { return "No data yet" }
        guard let usage else { return "Not available" }
        if usage.status == "not_signed_in" { return "Not signed in" }
        if usage.isNoPlan { return "No plan limits" }
        if !usage.isOK && usage.windows.isEmpty { return usage.error ?? "Error" }
        return "Not on this plan"
    }

    /// Why the multi-provider widgets have no provider to list.
    static func noProviders(snapshot: UsageSnapshot?, settings: UsageSettings) -> String {
        guard let snapshot else { return "No data yet. Open \(AppConstants.appName) to refresh." }
        let enabled = settings.enabledProviders
        if enabled.isEmpty { return "All providers are turned off in \(AppConstants.appName)." }
        if enabled.contains(where: { snapshot.provider($0)?.status == "not_signed_in" }) {
            return "None of your providers is signed in on your computer."
        }
        return "Your computer isn't reporting any enabled provider."
    }

    /// Enabled providers the snapshot reports and is signed in to: ones with
    /// limits first, then ones that only have a status line, each in
    /// `ProviderID` order. Providers not signed in on the computer are left
    /// out; with eight providers they'd crowd out the ones in use.
    static func visibleProviders(snapshot: UsageSnapshot?, settings: UsageSettings) -> [ProviderID] {
        guard let snapshot else { return [] }
        let reported = settings.enabledProviders.compactMap { id -> (ProviderID, ProviderUsage)? in
            guard let usage = snapshot.provider(id), usage.status != "not_signed_in" else { return nil }
            return (id, usage)
        }
        return reported.filter { !$0.1.windows.isEmpty }.map(\.0)
            + reported.filter { $0.1.windows.isEmpty }.map(\.0)
    }

    /// Every window a provider reports, in display order: 5-hour, weekly,
    /// per-model weekly (Fable), monthly and its per-model or per-feature
    /// windows, daily and its per-model windows, credit limits, then any
    /// window a newer companion adds.
    static func windows(of usage: ProviderUsage?) -> [UsageWindow] {
        guard let usage else { return [] }
        return usage.windows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func rank(_ window: UsageWindow) -> Int {
        switch window.id {
        case "five_hour": return 0
        case "weekly": return 10
        case "monthly": return 30
        case "daily": return 40
        case "key_limit": return 50
        default:
            if window.id.hasPrefix("five_hour_") { return 1 }
            if window.id.hasPrefix("weekly_") { return 20 }
            if window.id.hasPrefix("monthly_") { return 31 }
            if window.id.hasPrefix("daily_") { return 41 }
            return window.kind == "model" ? 20 : 60
        }
    }

    /// "5h", "Week", "Fable", "Month", "Day", "Key limit", and for per-model
    /// windows the model's name ("2.5 Pro" for "daily_gemini-2.5-pro").
    static func shortLabel(_ window: UsageWindow) -> String {
        if let slot = WindowSlot(windowID: window.id) { return slot.shortLabel }
        return window.id == "key_limit" ? "Key limit" : ownName(window)
    }

    /// "5h", "Wk", "Fable", "Mo", "Day": Lock Screen rows and gauges.
    static func tinyLabel(_ slot: WindowSlot) -> String {
        switch slot {
        case .fiveHour: return "5h"
        case .weekly: return "Wk"
        case .fable: return "Fable"
        case .monthly: return "Mo"
        case .daily: return "Day"
        }
    }

    /// `tinyLabel(_:)` for any window: "Key" for a credit limit, and the most
    /// telling word of a model's name, e.g. "Pro" for "Gemini 2.5 Pro",
    /// "Lite" for "2.5 Flash-Lite", "Chat" for "Monthly chat".
    static func tinyLabel(_ window: UsageWindow) -> String {
        if let slot = WindowSlot(windowID: window.id) { return tinyLabel(slot) }
        if window.id == "key_limit" { return "Key" }
        let words = ownName(window)
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .map(String.init)
        let word = words.last(where: { $0.contains(where: \.isLetter) }) ?? words.last ?? window.label
        return word.count <= 6 ? word.capitalizedFirst : String(word.prefix(5)).capitalizedFirst
    }

    /// A window's label without the words its row already implies: the
    /// provider's name and the period. "Gemini 2.5 Pro" → "2.5 Pro",
    /// "Monthly chat" → "Chat".
    private static func ownName(_ window: UsageWindow) -> String {
        let implied = Set(ProviderID.allCases.map { $0.displayName.lowercased() })
            .union(["5-hour", "daily", "weekly", "monthly"])
        var words = window.label.split(separator: " ").map(String.init)
        while words.count > 1, let first = words.first, implied.contains(first.lowercased()) {
            words.removeFirst()
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? window.id : name.capitalizedFirst
    }

    /// The number alone in the chosen mode ("32%" used, "68%" left), for rows
    /// whose bar already shows which way it reads.
    static func percent(_ window: UsageWindow, mode: BarMode, at date: Date) -> String {
        UsageFormat.percent(mode.value(used: window.effectivePercent(at: date)))
    }

    /// "32%" when showing usage, "68% left" when showing what's left, for
    /// one-line summaries without a bar.
    static func summaryPercent(_ window: UsageWindow, mode: BarMode, at date: Date) -> String {
        let used = window.effectivePercent(at: date)
        return mode == .used ? UsageFormat.percent(used) : mode.percentText(used: used)
    }
}

private extension String {
    /// "chat" → "Chat"; leaves "2.5 Pro" and "GPT-5" alone.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

// MARK: - Building blocks

struct WidgetStaleBadge: View {
    var body: some View {
        Text("Cached")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

/// Ring version of `PaceBar`: the arc is the fill in the chosen mode and a
/// tick across the ring marks the elapsed (or remaining) share of time.
struct WidgetRing: View {
    let window: UsageWindow
    let mode: BarMode
    let date: Date
    var lineWidth: CGFloat = 8

    var body: some View {
        let values = window.barValues(mode: mode, at: date)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(values.fill, 0), 100) / 100))
                .stroke(UsageFormat.tint(for: window.effectivePercent(at: date)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let marker = values.marker {
                Circle()
                    .trim(from: CGFloat(max(marker - 0.006, 0)), to: CGFloat(min(marker + 0.006, 1)))
                    .stroke(Color.primary, lineWidth: lineWidth + 4)
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// `PaceBar` for vibrant Lock Screen rendering: primary (white) fill and
/// marker, no provider tint, and a track that stays visible on any wallpaper.
struct WidgetLockScreenBar: View {
    let window: UsageWindow
    let mode: BarMode
    let date: Date
    var height: CGFloat = 5

    var body: some View {
        PaceBar(window: window, mode: mode, tint: .primary, at: date, height: height, style: .thin)
            // PaceBar's own track is 22% of the tint; this lifts it past 30%.
            .background(Capsule().fill(Color.primary.opacity(0.12)).frame(height: height))
            .widgetAccentable()
    }
}

struct WidgetNotPairedView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "link.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(WidgetText.notPaired)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "+2": windows that didn't fit, so a cut-off list doesn't look complete.
struct WidgetMoreBadge: View {
    let count: Int
    var fontSize: CGFloat = 9

    var body: some View {
        if count > 0 {
            Text("+\(count)")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) more")
        }
    }
}

struct WidgetMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A window's short label ("2.5 Flash-Lite"), or its tiny one ("Lite") when
/// the short one doesn't fit.
private struct WidgetWindowLabel: View {
    let window: UsageWindow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(WidgetText.shortLabel(window))
            Text(WidgetText.tinyLabel(window))
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
    }
}

/// Label, countdown and percent over a thin bar: the small and medium
/// widgets' row.
private struct WidgetBarRow: View {
    let window: UsageWindow
    let tint: Color
    let mode: BarMode
    let date: Date
    var showsCountdown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The countdown goes first when the row runs out of width, so the
            // percent always stays readable.
            ViewThatFits(in: .horizontal) {
                if showsCountdown, window.resetsAt != nil {
                    textLine(showsCountdown: true)
                }
                textLine(showsCountdown: false)
            }
            PaceBar(window: window, mode: mode, tint: tint, at: date, height: 5, style: .thin)
        }
    }

    private func textLine(showsCountdown: Bool) -> some View {
        HStack(spacing: 4) {
            WidgetWindowLabel(window: window)
                .font(.caption2.weight(.semibold))
            Spacer(minLength: 2)
            if showsCountdown {
                Text(WidgetText.countdown(window, at: date))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(WidgetText.percent(window, mode: mode, at: date))
                .font(.caption2.bold())
                .monospacedDigit()
                .layoutPriority(1)
        }
        .lineLimit(1)
    }
}

// MARK: - Usage Limit (one window, configurable)

/// One provider window: ring on the Home Screen, gauge, bar or one line of
/// text on the Lock Screen.
struct SingleLimitWidgetLayout: View {
    let family: WidgetLayoutFamily
    let snapshot: UsageSnapshot?
    let provider: ProviderID
    let slot: WindowSlot
    let date: Date
    let settings: UsageSettings
    let isStale: Bool
    var isPaired = true

    private var usage: ProviderUsage? { snapshot?.provider(provider) }
    private var isEnabled: Bool { settings.isEnabled(provider.rawValue) }
    /// Nil when the provider is turned off in the app, even if the companion reports it.
    private var window: UsageWindow? { isEnabled ? usage?.window(slot) : nil }
    private var mode: BarMode { settings.barMode }
    private var tint: Color { UsageFormat.providerTint(provider.rawValue) }

    private var reason: String {
        guard isEnabled else { return WidgetText.turnedOff }
        return WidgetText.unavailable(snapshot: snapshot, usage: usage)
    }

    /// Stands in for the percentage when there's no window to show.
    private var placeholderValue: String {
        isEnabled ? "N/A" : "Off"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            // All of the provider's bars: the chosen limit alone left the
            // larger Lock Screen widget showing one bar of three.
            case .accessoryRectangular:
                ProviderLimitsWidgetLayout(family: family, snapshot: snapshot, provider: provider, date: date,
                                           settings: settings, isStale: isStale, isPaired: isPaired)
            case .accessoryInline: inline
            case .small, .medium, .large: small
            }
        }
        .widgetDynamicTypeLimit()
    }

    @ViewBuilder
    private var small: some View {
        if !isPaired {
            WidgetNotPairedView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    ProviderLogo(providerID: provider.rawValue)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(WidgetText.providerName(provider, usage))
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    if isStale { WidgetStaleBadge() }
                }
                .foregroundStyle(tint)
                Text(slot.longLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let window {
                    ZStack {
                        WidgetRing(window: window, mode: mode, date: date, lineWidth: 9)
                        VStack(spacing: 0) {
                            Text(WidgetText.percent(window, mode: mode, at: date))
                                .font(.title3.bold())
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                            Text(mode == .used ? "used" : "left")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        // Inside the ring's stroke.
                        .padding(11)
                    }
                    .frame(width: 66, height: 66)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    Text(UsageFormat.resetText(window, now: date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 4) {
                        Text(placeholderValue)
                            .font(.title.bold())
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Capacity gauge around the provider logo, the number and the limit.
    @ViewBuilder
    private var circular: some View {
        if !isPaired {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "link")
            }
        } else if let window {
            let used = window.effectivePercent(at: date)
            Gauge(value: mode.value(used: used), in: 0...100) {
                Text(WidgetText.tinyLabel(slot))
            } currentValueLabel: {
                VStack(spacing: 0) {
                    ProviderLogo(providerID: provider.rawValue)
                        .frame(width: 11, height: 11)
                    Text(UsageFormat.percent(mode.value(used: used)).replacingOccurrences(of: "%", with: ""))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                    Text(WidgetText.tinyLabel(slot))
                        .font(.system(size: 9, weight: .medium))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.displayName) \(slot.longLabel)")
            .accessibilityValue(mode.percentText(used: used))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    ProviderLogo(providerID: provider.rawValue)
                        .frame(width: 16, height: 16)
                    Text(placeholderValue)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }

    /// Text only: inline widgets can't draw shapes. The longest variant
    /// that fits wins.
    @ViewBuilder
    private var inline: some View {
        if !isPaired {
            Text("\(AppConstants.appName): not paired")
        } else if let window {
            let value = WidgetText.summaryPercent(window, mode: mode, at: date)
            let countdown = WidgetText.countdown(window, at: date)
            ViewThatFits {
                Text("\(provider.displayName) \(slot.shortLabel) \(value) · \(countdown)")
                Text("\(provider.displayName) \(slot.shortLabel) \(value)")
                Text("\(slot.shortLabel) \(value) · \(countdown)")
            }
        } else {
            Text("\(provider.displayName) \(slot.shortLabel) \(placeholderValue)")
        }
    }
}

// MARK: - Provider Limits (every window of one provider)

/// All of one provider's windows as thin bars: Lock Screen rectangular (for
/// this widget and "Usage Limit") and Home Screen small.
struct ProviderLimitsWidgetLayout: View {
    let family: WidgetLayoutFamily
    let snapshot: UsageSnapshot?
    let provider: ProviderID
    let date: Date
    let settings: UsageSettings
    let isStale: Bool
    var isPaired = true

    /// As many rows as fit a 160×72 pt Lock Screen widget; more get a "+N".
    static let maxLockScreenRows = 5
    /// As many rows as fit a small Home Screen widget or an overview column.
    static let maxRows = 4

    private var usage: ProviderUsage? { snapshot?.provider(provider) }
    private var isEnabled: Bool { settings.isEnabled(provider.rawValue) }
    private var allRows: [UsageWindow] { isEnabled ? WidgetText.windows(of: usage) : [] }
    private var mode: BarMode { settings.barMode }
    private var tint: Color { UsageFormat.providerTint(provider.rawValue) }

    private var reason: String {
        guard isEnabled else { return WidgetText.turnedOff }
        return WidgetText.unavailable(snapshot: snapshot, usage: usage)
    }

    var body: some View {
        Group {
            switch family {
            case .small, .medium, .large: small
            case .accessoryRectangular, .accessoryCircular, .accessoryInline: rectangular
            }
        }
        .widgetDynamicTypeLimit()
    }

    // MARK: Lock Screen

    @ViewBuilder
    private var rectangular: some View {
        if !isPaired {
            Text(WidgetText.notPaired)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            let allRows = allRows
            let rows = Array(allRows.prefix(Self.maxLockScreenRows))
            let fontSize: CGFloat = switch rows.count {
            case ...2: 12
            case 3: 11
            case 4: 10
            default: 9
            }
            VStack(alignment: .leading, spacing: rows.count >= 4 ? 0 : 3) {
                lockScreenHeader(rows, hidden: allRows.count - rows.count, fontSize: fontSize)
                if rows.isEmpty {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    ForEach(rows) { window in
                        lockScreenRow(window, fontSize: fontSize, barHeight: rows.count >= 5 ? 3 : (rows.count == 4 ? 4 : 5))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Logo in place of the name, and the countdown to the soonest reset.
    private func lockScreenHeader(_ rows: [UsageWindow], hidden: Int, fontSize: CGFloat) -> some View {
        let next = rows
            .filter { ($0.resetsAt ?? .distantPast) > date }
            .min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        return HStack(spacing: 4) {
            ProviderLogo(providerID: provider.rawValue)
                .frame(width: 13, height: 13)
                .accessibilityLabel(provider.displayName)
            if let next {
                let label = WidgetText.tinyLabel(next)
                let countdown = WidgetText.countdown(next, at: date)
                ViewThatFits(in: .horizontal) {
                    Text("\(label) resets in \(countdown)")
                    Text("\(label) \(countdown)")
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            WidgetMoreBadge(count: hidden, fontSize: fontSize)
            if isStale {
                Text("Cached")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .lineLimit(1)
    }

    /// Label, bar and percent; the percent goes if the bar would get shorter than 40 pt.
    private func lockScreenRow(_ window: UsageWindow, fontSize: CGFloat, barHeight: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                lockScreenLabel(window, fontSize: fontSize)
                WidgetLockScreenBar(window: window, mode: mode, date: date, height: barHeight)
                    .frame(minWidth: 40)
                Text(WidgetText.percent(window, mode: mode, at: date))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 32, alignment: .trailing)
            }
            HStack(spacing: 5) {
                lockScreenLabel(window, fontSize: fontSize)
                WidgetLockScreenBar(window: window, mode: mode, date: date, height: barHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetText.shortLabel(window))
        .accessibilityValue(mode.percentText(used: window.effectivePercent(at: date)))
    }

    private func lockScreenLabel(_ window: UsageWindow, fontSize: CGFloat) -> some View {
        Text(WidgetText.tinyLabel(window))
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 30, alignment: .leading)
    }

    // MARK: Home Screen

    @ViewBuilder
    private var small: some View {
        if !isPaired {
            WidgetNotPairedView()
        } else {
            let allRows = allRows
            let rows = Array(allRows.prefix(Self.maxRows))
            VStack(alignment: .leading, spacing: rows.count >= 4 ? 5 : 7) {
                HStack(spacing: 4) {
                    ProviderLogo(providerID: provider.rawValue)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(WidgetText.providerName(provider, usage))
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let plan = usage?.plan {
                        Text(plan.capitalized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    WidgetMoreBadge(count: allRows.count - rows.count)
                    if isStale { WidgetStaleBadge() }
                }
                .foregroundStyle(tint)
                if rows.isEmpty {
                    WidgetMessageView(text: reason)
                } else {
                    ForEach(rows) { window in
                        WidgetBarRow(window: window, tint: tint, mode: mode, date: date)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Usage Overview (medium)

/// Every enabled provider side by side: one column each for up to four,
/// then a two-column grid with one bar per provider (its most-used limit).
struct OverviewWidgetLayout: View {
    let snapshot: UsageSnapshot?
    let date: Date
    let settings: UsageSettings
    let isStale: Bool
    var isPaired = true

    /// Columns that fit before switching to the grid.
    static let maxColumns = 4

    var body: some View {
        let providers = WidgetText.visibleProviders(snapshot: snapshot, settings: settings)
        Group {
            if !isPaired {
                WidgetNotPairedView()
            } else if providers.isEmpty {
                WidgetMessageView(text: WidgetText.noProviders(snapshot: snapshot, settings: settings))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if providers.count <= Self.maxColumns {
                        columns(providers)
                    } else {
                        grid(providers)
                    }
                    if isStale {
                        HStack(spacing: 4) {
                            WidgetStaleBadge()
                            if let snapshot {
                                (Text("Updated ") + Text(snapshot.generatedAt, style: .time))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .widgetDynamicTypeLimit()
    }

    private func columns(_ providers: [ProviderID]) -> some View {
        let density = OverviewColumn.Density(columns: providers.count)
        return HStack(alignment: .top, spacing: density == .regular ? 14 : 10) {
            ForEach(providers) { id in
                OverviewColumn(id: id, snapshot: snapshot, date: date, mode: settings.barMode,
                               density: density)
            }
        }
    }

    /// Two columns of four cells (three when the Cached line needs the room);
    /// the last cell becomes "+N more" if there are more providers than cells.
    private func grid(_ providers: [ProviderID]) -> some View {
        let capacity = isStale ? 6 : 8
        let shown = providers.count > capacity ? Array(providers.prefix(capacity - 1)) : providers
        let hidden = providers.count - shown.count
        let rows = stride(from: 0, to: capacity, by: 2).map { $0 }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { start in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(start..<start + 2, id: \.self) { index in
                        Group {
                            if index < shown.count {
                                OverviewGridCell(id: shown[index], snapshot: snapshot, date: date,
                                                 mode: settings.barMode)
                            } else if index == shown.count, hidden > 0 {
                                Text("+\(hidden) more in the app")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// One provider in the overview grid: logo and name, its most-used limit
/// with that limit's percent, and the bar.
private struct OverviewGridCell: View {
    let id: ProviderID
    let snapshot: UsageSnapshot?
    let date: Date
    let mode: BarMode

    var body: some View {
        let usage = snapshot?.provider(id)
        let windows = WidgetText.windows(of: usage)
        // The limit closest to running out, the one worth a glance.
        let window = windows.max { $0.effectivePercent(at: date) < $1.effectivePercent(at: date) }
        let tint = UsageFormat.providerTint(id.rawValue)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProviderLogo(providerID: id.rawValue)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(id.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if let window {
                    Text(WidgetText.tinyLabel(window))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.8)
                    Text(WidgetText.percent(window, mode: mode, at: date))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            .lineLimit(1)
            if let window {
                PaceBar(window: window, mode: mode, tint: tint, at: date, height: 5, style: .thin)
            } else {
                Text(WidgetText.unavailable(snapshot: snapshot, usage: usage))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewColumn: View {
    enum Density {
        /// One or two columns: name and plan.
        case regular
        /// Three columns: name only.
        case compact
        /// Four columns: logo and plan, no countdowns.
        case tight

        init(columns: Int) {
            switch columns {
            case ...2: self = .regular
            case 3: self = .compact
            default: self = .tight
            }
        }
    }

    let id: ProviderID
    let snapshot: UsageSnapshot?
    let date: Date
    let mode: BarMode
    let density: Density

    var body: some View {
        let usage = snapshot?.provider(id)
        let allWindows = WidgetText.windows(of: usage)
        let windows = allWindows.prefix(ProviderLimitsWidgetLayout.maxRows)
        let tint = UsageFormat.providerTint(id.rawValue)
        VStack(alignment: .leading, spacing: density == .regular ? 5 : 4) {
            HStack(spacing: 4) {
                ProviderLogo(providerID: id.rawValue)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(id.displayName)
                if density != .tight {
                    Text(WidgetText.providerName(id, usage))
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 2)
                WidgetMoreBadge(count: allWindows.count - windows.count)
                if density != .compact, let plan = usage?.plan {
                    Text(plan.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint)
            if windows.isEmpty {
                Text(WidgetText.unavailable(snapshot: snapshot, usage: usage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                ForEach(windows) { window in
                    WidgetBarRow(window: window, tint: tint, mode: mode, date: date,
                                 showsCountdown: density != .tight)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - All Limits (large)

/// Every enabled provider and window with reset times: a section per
/// provider, or one line per provider once the sections wouldn't fit.
struct AllLimitsWidgetLayout: View {
    let snapshot: UsageSnapshot?
    let date: Date
    let settings: UsageSettings
    let isStale: Bool
    var isPaired = true

    /// Sections fit up to four providers with twelve bars between them.
    static let maxSectionProviders = 4
    static let maxSectionRows = 12
    /// Provider lines that fit in the one-line-per-provider mode.
    static let maxSummaryRows = 8

    var body: some View {
        let providers = WidgetText.visibleProviders(snapshot: snapshot, settings: settings)
        Group {
            if !isPaired {
                WidgetNotPairedView()
            } else if providers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    header(hidden: 0)
                    Spacer(minLength: 0)
                    Text(WidgetText.noProviders(snapshot: snapshot, settings: settings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            } else if providers.count <= Self.maxSectionProviders, rowCount(providers) <= Self.maxSectionRows {
                sections(providers)
            } else {
                summary(providers)
            }
        }
        .widgetDynamicTypeLimit()
    }

    private func sections(_ providers: [ProviderID]) -> some View {
        let density = LimitBarRow.Density(rows: rowCount(providers))
        return VStack(alignment: .leading, spacing: density == .regular ? 10 : 6) {
            header(hidden: 0)
            ForEach(providers) { id in
                ProviderSection(id: id, snapshot: snapshot, date: date, mode: settings.barMode,
                                density: density)
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(_ providers: [ProviderID]) -> some View {
        let shown = Array(providers.prefix(Self.maxSummaryRows))
        // Seven or eight lines only fit without the countdowns; the bars'
        // time markers still show how far into each window you are.
        let showsCountdowns = shown.count <= 6
        return VStack(alignment: .leading, spacing: showsCountdowns ? 8 : 7) {
            header(hidden: providers.count - shown.count)
            ForEach(shown) { id in
                ProviderSummaryRow(id: id, snapshot: snapshot, date: date, mode: settings.barMode,
                                   showsCountdowns: showsCountdowns)
            }
            Spacer(minLength: 0)
        }
    }

    private func header(hidden: Int) -> some View {
        HStack(spacing: 4) {
            Text(AppConstants.appName)
                .font(.headline)
            WidgetMoreBadge(count: hidden, fontSize: 11)
            Spacer(minLength: 4)
            if isStale { WidgetStaleBadge() }
            if let snapshot {
                (Text("Updated ") + Text(snapshot.generatedAt, style: .time) + Text(snapshot.host.map { " · \($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// One row per bar, or one per provider that has none (its status line).
    private func rowCount(_ providers: [ProviderID]) -> Int {
        providers.reduce(0) { count, id in
            count + max(WidgetText.windows(of: snapshot?.provider(id)).count, 1)
        }
    }
}

/// A provider on one line: logo, name and plan, then up to three limits side
/// by side, each with its percent, bar and (room permitting) countdown. The
/// large widget's layout for five or more providers.
private struct ProviderSummaryRow: View {
    static let maxWindows = 3

    let id: ProviderID
    let snapshot: UsageSnapshot?
    let date: Date
    let mode: BarMode
    var showsCountdowns = true

    var body: some View {
        let usage = snapshot?.provider(id)
        let allWindows = WidgetText.windows(of: usage)
        let windows = Array(allWindows.prefix(Self.maxWindows))
        let tint = UsageFormat.providerTint(id.rawValue)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ProviderLogo(providerID: id.rawValue)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    // The short name: the plan line says "Go", "Plus", ...
                    Text(id.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(tint)
                HStack(spacing: 3) {
                    if let plan = usage?.plan {
                        Text(plan.capitalized)
                            .foregroundStyle(.secondary)
                    }
                    WidgetMoreBadge(count: allWindows.count - windows.count)
                }
                .font(.system(size: 9, weight: .medium))
                .padding(.leading, 16)
            }
            .lineLimit(1)
            .frame(width: 84, alignment: .leading)

            if windows.isEmpty {
                Text(WidgetText.unavailable(snapshot: snapshot, usage: usage))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Empty cells keep the columns lined up from row to row.
                ForEach(0..<Self.maxWindows, id: \.self) { index in
                    if index < windows.count {
                        cell(windows[index], tint: tint)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private func cell(_ window: UsageWindow, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(WidgetText.tinyLabel(window))
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(WidgetText.percent(window, mode: mode, at: date))
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            PaceBar(window: window, mode: mode, tint: tint, at: date, height: 4, style: .thin)
            if showsCountdowns {
                Text(WidgetText.countdown(window, at: date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(id.displayName) \(WidgetText.shortLabel(window))")
        .accessibilityValue(mode.percentText(used: window.effectivePercent(at: date)))
    }
}

private struct ProviderSection: View {
    let id: ProviderID
    let snapshot: UsageSnapshot?
    let date: Date
    let mode: BarMode
    let density: LimitBarRow.Density

    var body: some View {
        let usage = snapshot?.provider(id)
        let windows = WidgetText.windows(of: usage)
        let tint = UsageFormat.providerTint(id.rawValue)
        VStack(alignment: .leading, spacing: density == .regular ? 4 : 3) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ProviderLogo(providerID: id.rawValue)
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    Text(WidgetText.providerName(id, usage))
                        .font(density == .regular ? .subheadline.bold() : .caption.bold())
                        .lineLimit(1)
                }
                .foregroundStyle(tint)
                if let plan = usage?.plan {
                    Text(plan.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let account = usage?.account {
                    Text(account)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if windows.isEmpty {
                Text(WidgetText.unavailable(snapshot: snapshot, usage: usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ForEach(windows) { window in
                    LimitBarRow(window: window, tint: tint, mode: mode, date: date, density: density)
                }
            }
        }
    }
}

private struct LimitBarRow: View {
    enum Density {
        /// Up to six rows: text line over a bar.
        case regular
        /// Seven or eight rows: the same, smaller.
        case compact
        /// Nine to twelve rows: label, bar, countdown and percent on one line.
        case dense

        init(rows: Int) {
            switch rows {
            case ...6: self = .regular
            case 7...8: self = .compact
            default: self = .dense
            }
        }
    }

    let window: UsageWindow
    let tint: Color
    let mode: BarMode
    let date: Date
    let density: Density

    var body: some View {
        if density == .dense {
            HStack(spacing: 6) {
                WidgetWindowLabel(window: window)
                    .fontWeight(.semibold)
                    .frame(width: 42, alignment: .leading)
                PaceBar(window: window, mode: mode, tint: tint, at: date, height: 5, style: .thin)
                Text(WidgetText.countdown(window, at: date))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Text(WidgetText.percent(window, mode: mode, at: date))
                    .bold()
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            .font(.system(size: 10))
            .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(WidgetText.shortLabel(window))
                        .fontWeight(.semibold)
                    if window.resetsAt != nil {
                        ViewThatFits(in: .horizontal) {
                            Text(UsageFormat.resetTextDetailed(window, now: date))
                            Text(UsageFormat.resetText(window, now: date))
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(mode.percentText(used: window.effectivePercent(at: date)))
                        .font(density == .compact ? .caption2.bold() : .caption.bold())
                        .monospacedDigit()
                }
                .font(density == .compact ? .system(size: 10) : .caption2)
                .lineLimit(1)
                PaceBar(window: window, mode: mode, tint: tint, at: date, height: 6, style: .thin)
            }
        }
    }
}

// MARK: - Sample data

/// Stand-in usage for widget placeholders and the gallery before the first fetch.
enum WidgetSampleData {
    static func snapshot(now: Date = .now) -> UsageSnapshot {
        func window(_ id: String, _ kind: String, _ label: String, _ percent: Double,
                    in seconds: TimeInterval?, length: Int?) -> UsageWindow {
            UsageWindow(id: id, kind: kind, label: label, percent: percent,
                        resetsAt: seconds.map { now.addingTimeInterval($0) }, windowSeconds: length)
        }
        return UsageSnapshot(
            generatedAt: now,
            host: "sample",
            companionVersion: "1.3.0",
            providers: [
                ProviderUsage(id: "claude", name: "Claude", plan: "max", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("five_hour", "session", "5-hour", 42, in: 2 * 3600 + 600, length: 18_000),
                                  window("weekly", "weekly", "Weekly", 18, in: 3 * 86_400 + 4 * 3600, length: 604_800),
                                  window("weekly_fable", "model", "Fable", 7, in: 3 * 86_400 + 4 * 3600, length: 604_800)
                              ]),
                ProviderUsage(id: "openai", name: "ChatGPT Codex", plan: "plus", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("five_hour", "session", "5-hour", 12, in: 3600 + 1500, length: 18_000),
                                  window("weekly", "weekly", "Weekly", 45, in: 5 * 86_400, length: 604_800)
                              ]),
                ProviderUsage(id: "opencode", name: "OpenCode Go", plan: "go", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("five_hour", "session", "5-hour", 8, in: 4 * 3600, length: 18_000),
                                  window("weekly", "weekly", "Weekly", 22, in: 4 * 86_400 + 2 * 3600, length: 604_800),
                                  window("monthly", "monthly", "Monthly", 35, in: 18 * 86_400, length: 2_592_000)
                              ]),
                ProviderUsage(id: "openrouter", name: "OpenRouter", plan: "free", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("daily", "daily", "Free requests", 30, in: 9 * 3600, length: 86_400),
                                  window("key_limit", "credit", "Key credit limit", 64, in: nil, length: nil)
                              ]),
                ProviderUsage(id: "copilot", name: "Copilot", plan: "pro", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("monthly", "monthly", "Premium requests", 27, in: 12 * 86_400, length: 2_592_000)
                              ]),
                ProviderUsage(id: "gemini", name: "Gemini", plan: "free", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("daily", "daily", "Daily", 15, in: 7 * 3600, length: 86_400),
                                  window("daily_gemini-2.5-pro", "model", "Gemini 2.5 Pro", 52, in: 7 * 3600, length: 86_400),
                                  window("daily_gemini-2.5-flash", "model", "Gemini 2.5 Flash", 9, in: 7 * 3600, length: 86_400),
                                  window("daily_gemini-2.5-flash-lite", "model", "Gemini 2.5 Flash-Lite", 3, in: 7 * 3600, length: 86_400)
                              ]),
                ProviderUsage(id: "cursor", name: "Cursor", plan: "pro", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("monthly", "monthly", "Included requests", 61, in: 20 * 86_400, length: 2_592_000)
                              ]),
                ProviderUsage(id: "zai", name: "Z.ai", plan: "lite", account: nil, status: "ok",
                              error: nil, fetchedAt: now, windows: [
                                  window("five_hour", "session", "5-hour", 33, in: 3 * 3600, length: 18_000),
                                  window("monthly", "monthly", "Monthly", 11, in: 25 * 86_400, length: 2_592_000)
                              ])
            ]
        )
    }
}
