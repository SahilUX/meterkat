import SwiftUI

/// One provider's settings: whether it's shown, its limit alert and which
/// resets to announce. Pushed from the Providers section of Settings.
struct ProviderSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    let provider: ProviderID

    @ScaledMetric(relativeTo: .title3) private var logoSize: CGFloat = 32

    private var settings: ProviderSettings { store.settings[provider] }
    private var tint: Color { UsageFormat.providerTint(provider.rawValue) }

    var body: some View {
        Form {
            Section {
                header
            }

            if let usage = store.snapshot?.provider(provider), usage.isNoPlan || usage.status == "not_signed_in" {
                Section {
                    Label(usage.error ?? provider.statusSummary(in: store.snapshot), systemImage: usage.isNoPlan ? "info.circle" : "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle("Show \(provider.displayName)", isOn: store.binding(provider, \.enabled).animation())
            } footer: {
                Text("Hidden from the dashboard, widgets and alerts when off.")
            }

            if settings.enabled {
                limitSection
                resetSection
            }
        }
        .tint(tint)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Logo, name and plan, e.g. "Claude · Max plan".
    private var header: some View {
        HStack(spacing: 14) {
            ProviderLogo(providerID: provider.rawValue)
                .foregroundStyle(tint)
                .frame(width: logoSize, height: logoSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.title3.weight(.semibold))
                Text(provider.statusSummary(in: store.snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var limitSection: some View {
        Section {
            Toggle("Alert when nearing the limit", isOn: store.binding(provider, \.limitAlerts).animation())
            ThresholdSlider(value: settings.limitThreshold, mode: store.settings.barMode) { threshold in
                store.updateSettings(for: provider) { $0.limitThreshold = threshold }
            }
            .disabled(!settings.limitAlerts)
            .opacity(settings.limitAlerts ? 1 : 0.4)
        } header: {
            Text("Limit alert")
        } footer: {
            Text("Applies to each of \(provider.displayName)'s limits, once per reset cycle.")
        }
    }

    private var resetSection: some View {
        Section {
            ForEach(provider.knownSlots) { slot in
                Toggle(slot.resetAlertTitle, isOn: store.resetBinding(provider, slot))
            }
        } header: {
            Text("Reset alerts")
        } footer: {
            Text("A notification when a limit you've used refreshes.")
        }
    }
}

/// "Alert at 80% used" (or "20% left") over a slider. Follows the finger
/// locally and reports the value once the drag ends, so alerts aren't
/// re-evaluated on every tick. The value is always the percent used.
struct ThresholdSlider: View {
    var value: Double
    var mode: BarMode = .used
    var onCommit: (Double) -> Void

    @State private var draft: Double?
    @State private var isDragging = false

    private let range = ProviderSettings.thresholdRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Alert at \(mode.percentText(used: draft ?? value))")
                .monospacedDigit()
            Slider(value: binding, in: range, step: ProviderSettings.thresholdStep) {
                Text("Alert threshold")
            } minimumValueLabel: {
                Text(UsageFormat.percent(mode.value(used: range.lowerBound)))
            } maximumValueLabel: {
                Text(UsageFormat.percent(mode.value(used: range.upperBound)))
            } onEditingChanged: { editing in
                isDragging = editing
                if !editing { commit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityValue(mode.percentText(used: draft ?? value))
        }
        .padding(.vertical, 2)
    }

    private var binding: Binding<Double> {
        Binding {
            draft ?? value
        } set: { newValue in
            draft = newValue
            // VoiceOver adjustments don't report a drag; save them right away.
            if !isDragging { commit() }
        }
    }

    private func commit() {
        guard let draft else { return }
        if draft != value { onCommit(draft) }
        self.draft = nil
    }
}

extension UsageStore {
    /// Changes one provider's settings through `updateSettings`, asking for
    /// notification permission when an alert gets turned on.
    func updateSettings(for provider: ProviderID, _ change: (inout ProviderSettings) -> Void) {
        var newSettings = settings
        change(&newSettings[provider])
        let old = settings[provider]
        let new = newSettings[provider]
        let addsAlerts = (new.limitAlerts && !old.limitAlerts) || !new.resetAlertWindows.isSubset(of: old.resetAlertWindows)
        updateSettings(newSettings)
        if addsAlerts {
            Task { await NotificationManager.requestAuthorization() }
        }
    }

    func binding(_ provider: ProviderID, _ keyPath: WritableKeyPath<ProviderSettings, Bool>) -> Binding<Bool> {
        Binding {
            self.settings[provider][keyPath: keyPath]
        } set: { value in
            self.updateSettings(for: provider) { $0[keyPath: keyPath] = value }
        }
    }

    /// Whether resets of `slot` are announced for `provider`.
    func resetBinding(_ provider: ProviderID, _ slot: WindowSlot) -> Binding<Bool> {
        Binding {
            self.settings[provider].announcesReset(of: slot.windowID)
        } set: { isOn in
            self.updateSettings(for: provider) { settings in
                if isOn {
                    settings.resetAlertWindows.insert(slot.windowID)
                } else {
                    settings.resetAlertWindows.remove(slot.windowID)
                }
            }
        }
    }
}

extension ProviderID {
    /// Whether the companion reports this provider as signed in, whatever
    /// the plan or the last fetch's outcome.
    func isSignedIn(in snapshot: UsageSnapshot?) -> Bool {
        guard let usage = snapshot?.provider(self) else { return false }
        return usage.status != "not_signed_in"
    }

    /// Every provider, the ones signed in on the companion first, each group
    /// in `allCases` order. Plain `allCases` before the first fetch.
    static func signedInFirst(in snapshot: UsageSnapshot?) -> [ProviderID] {
        guard snapshot != nil else { return allCases }
        return allCases.filter { $0.isSignedIn(in: snapshot) } + allCases.filter { !$0.isSignedIn(in: snapshot) }
    }

    /// Providers the companion reads an API key or token for, rather than
    /// an app's login.
    var usesAPIKey: Bool {
        self == .openrouter || self == .zai || self == .deepseek
    }

    /// One line for settings rows, e.g. "Max plan" or "Not signed in on companion".
    func statusSummary(in snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "No usage fetched yet" }
        guard let usage = snapshot.provider(self) else { return "Not reported by companion" }
        switch usage.status {
        case "ok":
            guard let plan = usage.plan, !plan.isEmpty else { return "Signed in" }
            // OpenRouter reports "free" or "paid": whether credits were ever bought.
            return self == .openrouter ? "\(plan.capitalized) tier" : "\(plan.capitalized) plan"
        case "not_signed_in":
            return usesAPIKey ? "No API key on companion" : "Not signed in on companion"
        case "no_plan":
            return self == .opencode ? "No Go plan" : "No plan with limits"
        default:
            return "Couldn't fetch usage"
        }
    }
}

extension WindowSlot {
    /// "5-hour reset", "Weekly reset", "Fable weekly reset", "Monthly reset", "Daily reset".
    var resetAlertTitle: String {
        switch self {
        case .fiveHour: return "5-hour reset"
        case .weekly: return "Weekly reset"
        case .fable: return "Fable weekly reset"
        case .monthly: return "Monthly reset"
        case .daily: return "Daily reset"
        }
    }
}
