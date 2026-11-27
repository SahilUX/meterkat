import AppKit
import SwiftUI

/// The menu bar item's popover: usage per provider, with buttons to open
/// the window and Settings.
struct PanelView: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.barMode) private var barMode = BarMode.used
    @AppStorage(Prefs.panelStyle) private var panelStyle = UsageStyle.bars
    /// For `--render-panel`: no scroll view (ImageRenderer can't size one)
    /// and a fixed clock, since a TimelineView doesn't render offscreen.
    var snapshotDate: Date?
    /// Measured heights of the provider list and of the header and bottom
    /// sections around it.
    @State private var listHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    private let padding: CGFloat = 14
    private let spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: spacing) {
                header
                Divider()
            }
            .reportHeight(ChromeHeightKey.self)
            if snapshotDate != nil {
                list.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    list
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .reportHeight(ListHeightKey.self)
                }
                .frame(height: listViewportHeight)
            }
            VStack(alignment: .leading, spacing: spacing) {
                Divider()
                footer
            }
            .reportHeight(ChromeHeightKey.self)
        }
        .padding(padding)
        .frame(width: 320)
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .onAppear { Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: panelStyle) { Task { await model.loadHistoryIfStale() } }
    }

    /// The list scrolls once the whole panel would outgrow the screen, so
    /// the footer below it stays reachable.
    private var listViewportHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        // 20pt of the screen stays clear below the menu bar and at the bottom.
        let room = screen - 20 - chromeHeight - padding * 2 - spacing * 2
        return min(listHeight, max(room, 160))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: spacing) {
            StatusBanner()
            if model.snapshot != nil {
                if let snapshotDate {
                    providerList(now: snapshotDate)
                } else {
                    TimelineView(.everyMinute) { providerList(now: $0.date) }
                }
            }
        }
    }

    private func providerList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.providers) { ProviderSection(provider: $0, mode: barMode, style: panelStyle, now: now) }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Meterkat").font(.headline)
                Text(model.host ?? "This Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusIndicator()
                UsageStylePicker()
                    .controlSize(.mini)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: MainWindow.id)
                NSApp.activate()
            } label: {
                Label("Open Meterkat", systemImage: "macwindow")
            }
            Button { Task { await model.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh")
            .keyboardShortcut("r")
            .disabled(model.isRefreshing)
            Spacer()
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

/// Bars or graphs, as icons.
struct UsageStylePicker: View {
    @AppStorage(Prefs.panelStyle) private var panelStyle = UsageStyle.bars

    var body: some View {
        Picker("Show windows as", selection: $panelStyle) {
            ForEach(UsageStyle.allCases) { style in
                Image(systemName: style.symbol).help(style.label).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A colored dot and "Live", "Offline", etc.
struct StatusIndicator: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch model.state {
        case .online: return .green
        case .connecting: return .yellow
        case .offline, .failed: return .red
        case .notInstalled: return .gray
        }
    }

    private var text: String {
        switch model.state {
        case .online: return "Live"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        case .failed: return "Error"
        case .notInstalled: return "Not installed"
        }
    }
}

/// What's wrong with the link to the companion, if anything, with a Start
/// button when the service isn't running.
struct StatusBanner: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.setupDone) private var setupDone = false

    var body: some View {
        switch model.state {
        case .notInstalled, .offline where !Launchd.isInstalled:
            HStack {
                Label("The companion isn't set up on this Mac", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Set Up…") {
                    setupDone = false
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                }
                .controlSize(.small)
            }
        case .offline:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Companion not running", systemImage: "bolt.horizontal.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Start") { model.startCompanion() }
                        .controlSize(.small)
                }
                if let message = model.startMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                staleCaption
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                staleCaption
            }
        case .connecting where model.snapshot == nil:
            Text("Connecting to the companion…").font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var staleCaption: some View {
        if let updated = model.lastUpdated {
            Text("Showing data from \(updated, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Height of the provider list in the panel.
struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Combined height of the panel sections above and below the list.
struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
    /// Reports this view's height through `key`.
    func reportHeight<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        background(GeometryReader { Color.clear.preference(key: key, value: $0.size.height) })
    }
}

struct ProviderSection: View {
    let provider: ProviderUsage
    let mode: BarMode
    let style: UsageStyle
    let now: Date
    /// Token counts and API-rate cost, for windows without their own cost section.
    var showsAPICost = false
    /// The one-line split by product. The main window shows it in a section of its own.
    var showsBreakdown = true
    @State private var showsDetails = false

    var body: some View {
        let tint = UsageFormat.providerTint(provider.id)
        VStack(alignment: .leading, spacing: 10) {
            if provider.isOK {
                header(tint: tint)
                if provider.stale == true {
                    StaleNote(provider: provider)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(provider.windows) {
                    WindowRow(providerID: provider.id, window: $0, tint: tint, mode: mode, style: style, now: now)
                }
                if showsBreakdown, let breakdown = breakdownText {
                    Text(breakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Signed out, no plan, or failing: one line so it doesn't crowd the others.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    header(tint: tint).fixedSize()
                    if provider.status == "error" {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(provider.error ?? "Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(provider.error ?? "")
                    Spacer(minLength: 0)
                }
            }
            if let details = provider.details, !details.isEmpty {
                detailsList(details)
            }
            if showsAPICost, let cost = provider.apiCost {
                APICostView(cost: cost)
            }
        }
    }

    private func header(tint: Color) -> some View {
        HStack(spacing: 6) {
            ProviderLogo(providerID: provider.id)
                .frame(width: 14, height: 14)
                .foregroundStyle(tint)
            Text(provider.name).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            if let plan = provider.plan, !plan.isEmpty, !provider.name.localizedCaseInsensitiveContains(plan) {
                Text(plan.capitalized)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.15)))
                    .foregroundStyle(tint)
            }
        }
    }

    /// "Weekly usage: Claude Code 93% · Cowork 7%".
    private var breakdownText: String? {
        guard let breakdown = provider.breakdown else { return nil }
        let rows = breakdown.rows.filter { $0.percent.rounded() > 0 }
        guard !rows.isEmpty else { return nil }
        let window = breakdown.window.flatMap { id in provider.windows.first { $0.id == id } }
        let title = window.map { "\($0.label) usage" } ?? breakdown.title
        return "\(title): " + rows.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
    }

    private func detailsList(_ details: [ProviderDetail]) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                    GridRow {
                        Text(detail.label).foregroundStyle(.secondary)
                        Text(detail.value)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
            .padding(.top, 2)
        } label: {
            Text("Details").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

/// A window's title and percentage over its bar or graph. In Bars mode a
/// click opens the graph under the bar.
struct WindowRow: View {
    @EnvironmentObject private var model: CompanionModel
    let providerID: String
    let window: UsageWindow
    let tint: Color
    let mode: BarMode
    let style: UsageStyle
    let now: Date

    private var key: String { CompanionModel.historyKey(provider: providerID, window: window.id) }

    var body: some View {
        let values = window.barValues(mode: mode, at: now)
        let expanded = style == .bars && model.expandedRows.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.callout.weight(.medium)).lineLimit(1)
                if style == .bars {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Spacer(minLength: 8)
                Text("\(Int(values.fill.rounded()))%")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    + Text(" \(mode.suffix)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if style == .bars {
                PaceBar(fill: values.fill, marker: values.marker, tint: tint, height: 6)
            }
            if style == .graph || expanded {
                UsageChartView(window: window, providerID: providerID, mode: mode,
                               samples: model.samples(provider: providerID, window: window.id), now: now,
                               isCompact: true, compactChartHeight: 90)
                    .padding(.top, expanded ? 4 : 0)
            }
            if window.resetsAt != nil {
                Text(UsageFormat.resetTextDetailed(window, now: now))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let delta = window.paceDelta(at: now) {
                PaceHint(delta: delta)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard style == .bars else { return }
            withAnimation(.easeInOut(duration: 0.15)) { model.toggleExpanded(key) }
        }
        .help(style == .bars ? (expanded ? "Click to hide the graph" : "Click to show a graph") : "")
    }
}
