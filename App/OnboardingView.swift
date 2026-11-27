import SwiftUI
import UIKit
import UserNotifications

/// The steps of the first-run walkthrough, in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case companion
    case pair
    case notifications
    case providers
    case widgets
}

/// First-run walkthrough: install the companion, pair with it, allow
/// notifications, pick providers and alerts, and learn about widgets.
/// Presented as a full-screen cover from `RootView`; steps only advance with
/// the buttons.
struct OnboardingView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pairing = PairingModel()
    @State private var step: OnboardingStep = .welcome
    @State private var movingForward = true
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Providers get switched on to match the paired computer only once.
    @State private var didPresetProviders = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                stepContent
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
        .task { await refreshNotificationStatus() }
        .confirmsPairingAddition(store)
        .onChange(of: scenePhase) { _, phase in
            // Picks up a change made in iOS Settings.
            if phase == .active { Task { await refreshNotificationStatus() } }
        }
        .onChange(of: store.config) { _, config in
            // A pairing link opened while onboarding is up (e.g. from the Camera app).
            // The Pair step always reflects the saved config, even if it's behind us.
            guard let config, config != pairing.config else { return }
            if step.rawValue < OnboardingStep.pair.rawValue { go(to: .pair) }
            // go(to:) may already have picked it up.
            if config != pairing.config { pairing.adopt(config, store: store) }
        }
        .onChange(of: store.snapshot) { _, _ in
            // The first fetch can land after the Providers step is already up.
            if step == .providers { presetProviders() }
        }
        .onChange(of: store.pairingMessage) { _, message in
            // The Pair step shows the outcome, so don't leave an alert waiting behind the cover.
            guard let message, step.rawValue <= OnboardingStep.pair.rawValue else { return }
            store.pairingMessage = nil
            if pairing.results.isEmpty { pairing.message = message }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Button {
                go(to: OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .accessibilityLabel("Back")

            Spacer()
            ProgressCapsules(current: step)
            Spacer()

            if SharedStore.hasCompletedOnboarding {
                // Reopened from Settings or the dashboard: no need to step through to Done.
                Button {
                    store.showOnboarding = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .companion: CompanionStep()
        case .pair: PairStep(pairing: pairing)
        case .notifications: NotificationsStep(status: notificationStatus)
        case .providers: ProvidersStep()
        case .widgets: WidgetsStep()
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(step == .pair && !pairing.isConnected)

            if let secondaryTitle {
                Button(secondaryTitle, action: next)
                    .font(.subheadline.weight(.medium))
                    .frame(height: 44)
            } else {
                Color.clear.frame(height: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .background(Color(.systemBackground))
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .notifications where notificationStatus == .notDetermined: return "Allow Notifications"
        case .widgets: return "Done"
        default: return "Continue"
        }
    }

    private var secondaryTitle: String? {
        switch step {
        case .pair where !pairing.isConnected: return "Skip for now"
        case .notifications where notificationStatus == .notDetermined: return "Not now"
        default: return nil
        }
    }

    private func primaryAction() {
        switch step {
        case .notifications where notificationStatus == .notDetermined:
            Task {
                await NotificationManager.requestAuthorization()
                await refreshNotificationStatus()
            }
        case .widgets:
            store.completeOnboarding()
        default:
            next()
        }
    }

    // MARK: Navigation

    private func next() {
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        go(to: following)
    }

    private func go(to target: OnboardingStep) {
        guard target != step else { return }
        movingForward = target.rawValue > step.rawValue
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { step = target }
        if target == .pair, pairing.config == nil, let config = store.config, config.isComplete {
            // Already paired (e.g. onboarding reopened from Settings): show the current status.
            pairing.adopt(config, store: store)
        }
        if target == .providers { presetProviders() }
    }

    /// Turns on the providers the paired computer has usage for, and off the
    /// ones it isn't signed in to, has no plan for or doesn't report. A
    /// provider whose fetch failed stays on: the error is usually transient.
    /// Skipped once the user has changed any provider setting.
    private func presetProviders() {
        guard !didPresetProviders, pairing.isConnected, let snapshot = store.snapshot,
              store.settings.providers.isEmpty
        else { return }
        didPresetProviders = true
        var settings = store.settings
        for provider in ProviderID.allCases {
            settings[provider].enabled = snapshot.provider(provider).map { $0.isOK || $0.status == "error" } ?? false
        }
        store.updateSettings(settings)
    }

    private func refreshNotificationStatus() async {
        let status = await NotificationManager.authorizationStatus()
        withAnimation { notificationStatus = status }
    }
}

// MARK: - Pairing model

/// Probes each route of a config and keeps per-route status for the Pair
/// step. Lives for the whole walkthrough so results survive Back/Continue.
@MainActor
final class PairingModel: ObservableObject {
    enum Status: Equatable {
        case checking
        case connected
        case failed(String)
    }

    struct RouteResult: Identifiable {
        var route: CompanionRoute
        var status: Status
        var id: CompanionRoute.Kind { route.kind }
    }

    @Published private(set) var config: CompanionConfig?
    @Published private(set) var results: [RouteResult] = []
    @Published private(set) var host: String?
    /// Problems not tied to a route, e.g. an invalid clipboard link.
    @Published var message: String?

    // Manual entry fields; filled in from whatever config was adopted last.
    @Published var localURL = ""
    @Published var remoteURL = ""
    @Published var token = ""

    private var probeTask: Task<Void, Never>?
    /// Owner access that came with the pairing link being adopted.
    private var pendingOwner: OwnerGrant?

    var isChecking: Bool { results.contains { $0.status == .checking } }
    var isConnected: Bool { results.contains { $0.status == .connected } }
    var hasFailures: Bool { results.contains { if case .failed = $0.status { return true } else { return false } } }

    var canConnectManually: Bool {
        CompanionConfig(localURL: localURL, remoteURL: remoteURL, token: token).isComplete
    }

    /// Saves the config and tests every route at once.
    func adopt(_ newConfig: CompanionConfig, store: UsageStore) {
        guard newConfig.isComplete else {
            message = "Add a token and at least one address."
            return
        }
        if newConfig.pairingCode != nil {
            config = newConfig
            localURL = newConfig.localURL ?? ""
            remoteURL = newConfig.remoteURL ?? ""
            message = "Redeeming one-time pairing code…"
            probeTask?.cancel()
            probeTask = Task {
                do {
                    switch try await store.redeemPairing(newConfig) {
                    case .ready(let paired, let owner):
                        guard !Task.isCancelled else { return }
                        self.pendingOwner = owner
                        self.adopt(paired, store: store)
                    case .upgraded(let name):
                        self.message = "Owner access added to \(name)."
                    }
                } catch {
                    self.message = error.localizedDescription
                }
            }
            return
        }
        config = newConfig
        localURL = newConfig.localURL ?? ""
        remoteURL = newConfig.remoteURL ?? ""
        token = newConfig.token
        message = nil
        host = nil
        store.save(config: newConfig, owner: pendingOwner)
        pendingOwner = nil

        probeTask?.cancel()
        results = newConfig.routes.map { RouteResult(route: $0, status: .checking) }
        probeTask = Task { await probe(newConfig, store: store) }
    }

    func retry(store: UsageStore) {
        guard let config else { return }
        adopt(config, store: store)
    }

    func connectManually(store: UsageStore) {
        adopt(CompanionConfig(localURL: localURL, remoteURL: remoteURL, token: token), store: store)
    }

    func pasteLink(store: UsageStore) {
        guard let text = UIPasteboard.general.string, let pasted = CompanionConfig(pairingString: text) else {
            message = "The clipboard doesn't contain a Meterkat pairing link."
            return
        }
        adopt(pasted, store: store)
    }

    private func probe(_ config: CompanionConfig, store: UsageStore) async {
        await withTaskGroup(of: (CompanionRoute, Result<UsageSnapshot, Error>).self) { group in
            for route in config.routes {
                group.addTask { (route, await CompanionClient.probe(route: route, token: config.token)) }
            }
            for await (route, result) in group {
                guard !Task.isCancelled, let index = results.firstIndex(where: { $0.route == route }) else { continue }
                withAnimation {
                    switch result {
                    case .success(let snapshot):
                        results[index].status = .connected
                        host = host ?? snapshot.host ?? "your computer"
                    case .failure(let error):
                        results[index].status = .failed(Self.shortMessage(for: error))
                    }
                }
            }
        }
        // Fill the dashboard and widgets now rather than on the next tick. Even if
        // every route failed, this leaves an error on the dashboard, not a spinner.
        guard !Task.isCancelled else { return }
        await store.refresh()
    }

    private static func shortMessage(for error: Error) -> String {
        if let error = error as? CompanionError {
            switch error {
            case .unauthorized: return "Token rejected"
            case .badURL: return "Invalid address"
            case .http(let code): return "HTTP \(code)"
            case .decoding: return "Unexpected response"
            default: return error.localizedDescription
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "Timed out"
            case .cannotFindHost, .dnsLookupFailed: return "Host not found"
            case .cannotConnectToHost: return "Connection refused"
            case .notConnectedToInternet, .networkConnectionLost: return "No network"
            default: break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        StepScroll {
            HeroRings()
                .padding(.top, 24)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text("Meterkat")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Your Claude, OpenAI, Copilot, Gemini, Cursor and other AI plan limits, on your iPhone.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    systemImage: "square.grid.2x2.fill",
                    tint: UsageFormat.providerTint(ProviderID.claude.rawValue),
                    title: "Widgets for every limit",
                    detail: "5-hour, weekly, monthly, daily and Fable limits on your Home Screen and Lock Screen."
                )
                FeatureRow(
                    systemImage: "arrow.clockwise.circle.fill",
                    tint: UsageFormat.providerTint("openai"),
                    title: "Reset alerts",
                    detail: "Know the moment a limit you've used refreshes."
                )
                FeatureRow(
                    systemImage: "gauge.with.dots.needle.67percent",
                    tint: .orange,
                    title: "Nearing-limit alerts",
                    detail: "A heads-up when usage reaches the level you set for each provider."
                )
            }
            .padding(.top, 8)
        }
    }
}

private struct CompanionStep: View {
    var body: some View {
        StepScroll {
            StepHeader(
                systemImage: "laptopcomputer.and.iphone",
                title: "Install the companion",
                subtitle: "Your usage comes from a small companion on your Mac or Linux machine, using the logins already there for Claude Code, Codex, OpenCode, GitHub Copilot, Gemini CLI, Cursor, Kimi Code, MiniMax and Alibaba Model Studio (and OpenRouter, Z.ai, or DeepSeek API keys, if you add them). Your provider tokens never leave the computer."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("From the Meterkat project folder, run:")
                    .font(.subheadline.weight(.medium))
                CommandBox(command: "./companion/install.sh")
                Text("Then show the pairing code:")
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 6)
                CommandBox(command: "meterkat pair")
            }

            Label {
                Text("On a Mac, the installer adds a menu bar app that shows your pairing QR code.")
            } icon: {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PairStep: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var pairing: PairingModel
    @State private var showScanner = false
    @State private var showManual = false

    var body: some View {
        StepScroll {
            StepHeader(
                systemImage: "qrcode.viewfinder",
                title: "Pair with your computer",
                subtitle: "Scan the QR code from the menu bar app or `meterkat pair`, or paste the pairing link."
            )

            VStack(spacing: 10) {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    pairing.pasteLink(store: store)
                } label: {
                    Label("Paste pairing link", systemImage: "doc.on.clipboard")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let message = pairing.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !pairing.results.isEmpty {
                results
            }

            manualEntry

            Text("**Local network** is used at home. **Remote** (e.g. Tailscale) works anywhere else. Both are optional, but at least one is needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerSheet { config in
                pairing.adopt(config, store: store)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let host = pairing.host {
                Label("Paired with \(host)", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.bottom, 10)
            }
            ForEach(pairing.results) { result in
                RouteStatusRow(result: result)
                if result.id != pairing.results.last?.id {
                    Divider().padding(.leading, 36)
                }
            }
            if pairing.hasFailures, !pairing.isChecking {
                Button {
                    pairing.retry(store: store)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 10)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var manualEntry: some View {
        DisclosureGroup("Enter manually", isExpanded: $showManual.animation()) {
            VStack(spacing: 10) {
                InputField(title: "Local URL", placeholder: "http://192.168.1.20:47300", text: $pairing.localURL)
                InputField(title: "Remote URL", placeholder: "http://100.x.y.z:47300", text: $pairing.remoteURL)
                InputField(title: "Token", placeholder: "Pairing token", text: $pairing.token, secure: true)
                Button {
                    pairing.connectManually(store: store)
                } label: {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!pairing.canConnectManually || pairing.isChecking)
            }
            .padding(.top, 10)
        }
        .font(.subheadline.weight(.medium))
    }
}

private struct RouteStatusRow: View {
    var result: PairingModel.RouteResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.route.kind.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.route.kind.label)
                    .font(.subheadline.weight(.medium))
                Text(result.route.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        switch result.status {
        case .checking:
            ProgressView()
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct NotificationsStep: View {
    var status: UNAuthorizationStatus

    var body: some View {
        StepScroll {
            StepHeader(
                systemImage: "bell.badge.fill",
                title: "Stay ahead of your limits",
                subtitle: "Meterkat can tell you when it's worth getting back to work, and before you run out."
            )

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    systemImage: "arrow.clockwise.circle.fill",
                    tint: UsageFormat.providerTint("openai"),
                    title: "Reset alerts",
                    detail: "A notification when a 5-hour, daily, weekly or monthly limit you've used refreshes."
                )
                FeatureRow(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Nearing-limit alerts",
                    detail: "A heads-up when usage reaches a level you choose, like 80%."
                )
            }

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications allowed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        case .denied:
            VStack(alignment: .leading, spacing: 10) {
                Label("Notifications are off for Meterkat", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        default:
            EmptyView()
        }
    }
}

private struct ProvidersStep: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        // Full cards for what the computer is signed in to (or for everything
        // before the first fetch); the rest collapse into one short list.
        let signedIn = store.snapshot == nil
            ? ProviderID.allCases
            : ProviderID.allCases.filter { $0.isSignedIn(in: store.snapshot) }
        let others = ProviderID.allCases.filter { !signedIn.contains($0) }
        StepScroll {
            StepHeader(
                systemImage: "slider.horizontal.3",
                title: "Providers & alerts",
                subtitle: "Choose what to track and when to hear about it. You can change these any time in Settings."
            )

            VStack(spacing: 12) {
                ForEach(signedIn) { provider in
                    ProviderAlertCard(provider: provider)
                }
            }

            if !others.isEmpty {
                NotSignedInList(providers: others)
            }
        }
    }
}

/// Providers the paired computer isn't signed in to, one compact row each
/// with just the on/off switch. Their alerts are in Settings once they're on.
private struct NotSignedInList: View {
    @EnvironmentObject private var store: UsageStore
    var providers: [ProviderID]

    @ScaledMetric(relativeTo: .subheadline) private var logoSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in on your computer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(providers) { provider in
                    row(provider)
                    if provider != providers.last {
                        Divider().padding(.leading, logoSize + 12)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Sign in on your computer and they'll report usage on the next refresh. Turn one on now to have it ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func row(_ provider: ProviderID) -> some View {
        let tint = UsageFormat.providerTint(provider.rawValue)
        return Toggle(isOn: store.binding(provider, \.enabled).animation()) {
            HStack(spacing: 12) {
                ProviderLogo(providerID: provider.rawValue)
                    .foregroundStyle(tint)
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.subheadline.weight(.medium))
                    if let detail = detail(provider) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(tint)
        .padding(.vertical, 8)
    }

    /// Only what the heading doesn't already say: a missing API key, or a
    /// companion too old to know the provider.
    private func detail(_ provider: ProviderID) -> String? {
        let summary = provider.statusSummary(in: store.snapshot)
        return summary == "Not signed in on companion" ? nil : summary
    }
}

/// One provider's switch, limit alert and reset alerts on the Providers step.
private struct ProviderAlertCard: View {
    @EnvironmentObject private var store: UsageStore
    var provider: ProviderID

    @ScaledMetric(relativeTo: .headline) private var logoSize: CGFloat = 22

    private var settings: ProviderSettings { store.settings[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: store.binding(provider, \.enabled).animation()) {
                HStack(spacing: 12) {
                    ProviderLogo(providerID: provider.rawValue)
                        .foregroundStyle(UsageFormat.providerTint(provider.rawValue))
                        .frame(width: logoSize, height: logoSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(.headline)
                            .foregroundStyle(UsageFormat.providerTint(provider.rawValue))
                        if store.snapshot != nil {
                            Text(provider.statusSummary(in: store.snapshot))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 10)

            if settings.enabled {
                Divider()

                Toggle(isOn: store.binding(provider, \.limitAlerts).animation()) {
                    ToggleLabel(title: "Nearing-limit alert", detail: "Once per reset cycle, for each limit")
                }
                .padding(.vertical, 10)

                ThresholdSlider(value: settings.limitThreshold, mode: store.settings.barMode) { threshold in
                    store.updateSettings(for: provider) { $0.limitThreshold = threshold }
                }
                .padding(.bottom, 10)
                .disabled(!settings.limitAlerts)
                .opacity(settings.limitAlerts ? 1 : 0.4)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset alerts")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(provider.knownSlots) { slot in
                            SelectableChip(title: chipTitle(slot), isSelected: settings.announcesReset(of: slot.windowID)) {
                                toggleReset(slot)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(UsageFormat.providerTint(provider.rawValue))
    }

    private func toggleReset(_ slot: WindowSlot) {
        let reset = store.resetBinding(provider, slot)
        reset.wrappedValue = !reset.wrappedValue
    }

    private func chipTitle(_ slot: WindowSlot) -> String {
        switch slot {
        case .fiveHour: return "5h"
        case .weekly: return "Weekly"
        case .fable: return "Fable"
        case .monthly: return "Monthly"
        case .daily: return "Daily"
        }
    }
}

private struct WidgetsStep: View {
    var body: some View {
        StepScroll {
            WidgetMock()
                .padding(.top, 16)

            VStack(spacing: 8) {
                Text("Add a widget")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Keep your limits one glance away.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    systemImage: "apps.iphone",
                    tint: .blue,
                    title: "Home Screen",
                    detail: "Touch and hold the Home Screen → Edit → Add Widget → Meterkat."
                )
                FeatureRow(
                    systemImage: "lock.iphone",
                    tint: .indigo,
                    title: "Lock Screen",
                    detail: "Touch and hold the Lock Screen → Customize → Lock Screen, tap the widget area, then choose Meterkat."
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Four widgets")
                    .font(.headline)
                WidgetKindRow(name: "Usage Limit", detail: "Pick a provider and one of its limits (touch and hold → Edit Widget). Also on the Lock Screen, where the wide size shows all of the provider's limits.")
                WidgetKindRow(name: "Provider Limits", detail: "Every limit of one provider as bars, on the Lock Screen or as a small Home Screen widget. Touch and hold → Edit Widget to pick the provider.")
                WidgetKindRow(name: "Usage Overview", detail: "The providers you've turned on, side by side.")
                WidgetKindRow(name: "All Limits", detail: "Every limit in one large widget.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Building blocks

/// Scrollable, centered column shared by every step.
private struct StepScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct StepHeader: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(height: 64)
                .padding(.top, 12)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(subtitle))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct ProgressCapsules: View {
    var current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: step == current ? 24 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

private struct FeatureRow: View {
    var systemImage: String
    var tint: Color
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A shell command with a Copy button.
private struct CommandBox: View {
    var command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = command
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { copied = false }
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InputField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(.URL)
                }
            }
            .font(.body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct ToggleLabel: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SelectableChip: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WidgetKindRow: View {
    var name: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Illustrations

/// Two concentric usage rings, Claude outside and OpenAI inside.
private struct HeroRings: View {
    @State private var filled = false

    private let claude = UsageFormat.providerTint(ProviderID.claude.rawValue)
    private let openai = UsageFormat.providerTint("openai")

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [claude.opacity(0.16), openai.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            ring(tint: claude, value: 0.72, diameter: 136)
            ring(tint: openai, value: 0.45, diameter: 94)
        }
        .frame(width: 184, height: 184)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).delay(0.2)) { filled = true }
        }
        .accessibilityHidden(true)
    }

    private func ring(tint: Color, value: Double, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 14)
            Circle()
                .trim(from: 0, to: filled ? value : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A static small widget and Lock Screen gauge, just for show.
private struct WidgetMock: View {
    private let claude = UsageFormat.providerTint(ProviderID.claude.rawValue)

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    ProviderLogo(providerID: ProviderID.claude.rawValue)
                        .foregroundStyle(claude)
                        .frame(width: 12, height: 12)
                    Text("Claude")
                        .font(.caption2.weight(.semibold))
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(claude.opacity(0.2), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: 0.42)
                        .stroke(claude, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("42%")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("5-hour")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 76, height: 76)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text("Resets in 2h 14m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 148, height: 148)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color(.tertiarySystemFill))
                    Circle()
                        .trim(from: 0, to: 0.68)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(6)
                    Text("68")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                }
                .frame(width: 60, height: 60)
                Text("Lock Screen")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
