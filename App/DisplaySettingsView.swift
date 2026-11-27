import SwiftUI

/// How usage is drawn: used or remaining, and bars or graph. Pushed from
/// Settings.
struct DisplaySettingsView: View {
    @EnvironmentObject private var store: UsageStore

    private var barMode: BarMode { store.settings.barMode }
    private var usageStyle: UsageStyle { store.settings.usageStyle }

    var body: some View {
        Form {
            Section {
                DisplaySample(mode: barMode, style: usageStyle)
            } header: {
                Text("Preview")
            }

            Section {
                Picker("Show usage as", selection: barModeBinding) {
                    ForEach(BarMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Usage view", selection: usageStyleBinding) {
                    ForEach(UsageStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        switch usageStyle {
        case .bars:
            return barModeFooter
        case .graph:
            return "Graph plots \(barMode == .used ? "usage" : "what's left") over the current window against a steady pace to the reset, with a projection from the last few minutes. Widgets always show bars."
        }
    }

    private var barModeFooter: String {
        switch barMode {
        case .used:
            return "Bars fill up as you use a limit. The line shows how much of the window has passed: a bar past the line is running ahead of an even pace. Applies to the app and widgets."
        case .remaining:
            return "Bars empty as you use a limit. The line shows how much of the window is left: a bar short of the line is running ahead of an even pace. Applies to the app and widgets."
        }
    }

    private var barModeBinding: Binding<BarMode> {
        Binding {
            store.settings.barMode
        } set: { mode in
            var settings = store.settings
            settings.barMode = mode
            store.updateSettings(settings)
        }
    }

    private var usageStyleBinding: Binding<UsageStyle> {
        Binding {
            store.settings.usageStyle
        } set: { style in
            var settings = store.settings
            settings.usageStyle = style
            store.updateSettings(settings)
        }
    }
}

/// A made-up 5-hour limit drawn with the chosen mode and view, so the effect
/// of both pickers is obvious: 32% used, 45% of the window gone.
private struct DisplaySample: View {
    var mode: BarMode
    var style: UsageStyle

    private static let usedPercent: Double = 32
    private static let elapsed: Double = 0.45
    private static let windowSeconds = 5 * 3600

    private let tint = UsageFormat.providerTint(ProviderID.claude.rawValue)

    var body: some View {
        let now = Date.now
        let window = UsageWindow(
            id: WindowSlot.fiveHour.windowID,
            kind: "session",
            label: "5-hour",
            percent: Self.usedPercent,
            resetsAt: now.addingTimeInterval(Double(Self.windowSeconds) * (1 - Self.elapsed)),
            windowSeconds: Self.windowSeconds
        )
        VStack(alignment: .leading, spacing: 10) {
            SettingsValueRow("Sample 5-hour limit") {
                Text(mode.percentText(used: Self.usedPercent))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            switch style {
            case .bars:
                PaceBar(window: window, mode: mode, tint: tint, at: now)
                Text(markerCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .graph:
                UsageChartView(window: window, providerID: ProviderID.claude.rawValue, mode: mode,
                               samples: Self.samples(now: now), now: now, isCompact: true)
            }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.25), value: mode)
        .animation(.easeInOut(duration: 0.25), value: style)
        .accessibilityElement(children: .combine)
    }

    /// An uneven climb from 0% at the window start to `usedPercent` now.
    private static func samples(now: Date) -> [UsageSample] {
        let start = now.addingTimeInterval(-Double(windowSeconds) * elapsed)
        let span = now.timeIntervalSince(start)
        let shape: [Double] = [0, 0.05, 0.18, 0.3, 0.34, 0.5, 0.66, 0.72, 0.85, 1]
        return shape.indices.map { index in
            let fraction = Double(index) / Double(shape.count - 1)
            return UsageSample(date: start.addingTimeInterval(span * fraction), percent: usedPercent * shape[index])
        }
    }

    private var markerCaption: String {
        switch mode {
        case .used:
            return "Line: \(UsageFormat.percent(Self.elapsed * 100)) of the window has passed"
        case .remaining:
            return "Line: \(UsageFormat.percent((1 - Self.elapsed) * 100)) of the window is left"
        }
    }
}
