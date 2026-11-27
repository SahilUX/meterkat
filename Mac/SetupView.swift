import AppKit
import SwiftUI

/// First-run setup in the main window: install the companion, choose the
/// providers to track, and optionally pair an iPhone.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case companion
        case providers
        case iPhone
    }

    @EnvironmentObject private var model: CompanionModel
    @AppStorage(Prefs.setupDone) private var setupDone = false
    @State private var step: Step
    /// For `--render-setup`, which can't run the steps' async loading.
    private let preview: (providers: [DetectedProvider], phase: CompanionInstallStep.Phase)?

    init(step: Step = .welcome, preview: (providers: [DetectedProvider], phase: CompanionInstallStep.Phase)? = nil) {
        _step = State(initialValue: step)
        self.preview = preview
    }

    var body: some View {
        VStack(spacing: 0) {
            if preview != nil {
                // ImageRenderer draws nothing inside a ScrollView.
                page
                Spacer(minLength: 0)
            } else {
                ScrollView { page }
            }
            Divider()
            footer
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 20) {
            content
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            title("Welcome to Meterkat",
                  "See how much of your Claude, ChatGPT Codex, Copilot, and other plan limits you've used, here, in the menu bar, and on your iPhone.")
            Text("A small background service, the companion, reads the sign-ins you already have on this Mac and checks each provider's usage. Your provider tokens never leave this Mac.")
                .foregroundStyle(.secondary)
        case .companion:
            title("Install the companion", "The companion runs in the background and starts when you log in.")
            CompanionInstallStep(phase: preview?.phase ?? .checking)
        case .providers:
            title("Choose providers",
                  "Turn off the ones you don't use. The companion stops checking them, and they disappear everywhere, including on your iPhone.")
            ProviderSetupList(presetFromDetection: true, providers: preview?.providers ?? [])
        case .iPhone:
            title("Pair your iPhone", "Optional. You can do this later in Settings > iPhone.")
            PairingSection(showsTitle: false)
        }
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            if step == .companion, !companionReady {
                Button("Set Up Later") { finish() }
                    .help("Use Meterkat without the companion for now")
            }
            if step == .iPhone {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .companion && !companionReady)
            }
        }
        .padding(16)
    }

    private var companionReady: Bool {
        Launchd.isInstalled && model.state == .online && !CompanionCLI.isOutdated(model.snapshot?.companionVersion)
    }

    private func move(_ offset: Int) {
        step = Step(rawValue: step.rawValue + offset) ?? step
    }

    private func finish() {
        setupDone = true
        Task { await model.refresh(force: true) }
    }
}

/// Finds Python, then installs or updates the companion service.
struct CompanionInstallStep: View {
    enum Phase: Equatable {
        case checking
        case needsPython
        case ready
        case installing
        case failed(String)
    }

    @EnvironmentObject private var model: CompanionModel
    @State var phase = Phase.checking

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCurrent {
                Label("Companion \(model.snapshot?.companionVersion ?? "") is running.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                switch phase {
                case .checking:
                    ProgressView("Checking this Mac…").controlSize(.small)
                case .needsPython:
                    Text("The companion needs Python 3, which comes with Apple's Command Line Tools. Install them, then check again.")
                    HStack {
                        Button("Install Command Line Tools") { CompanionCLI.installDeveloperTools() }
                        Button("Check Again") { Task { await check() } }
                    }
                case .ready:
                    Text(Launchd.isInstalled
                         ? "This Mac has companion \(model.snapshot?.companionVersion ?? "(unknown version)"). Meterkat comes with \(CompanionCLI.bundledVersion ?? "a newer one")."
                         : "It goes in ~/.local/share/meterkat, with the `meterkat` command in ~/.local/bin.")
                        .foregroundStyle(.secondary)
                    Button(Launchd.isInstalled ? "Update Companion" : "Install Companion") { Task { await install() } }
                        .controlSize(.large)
                case .installing:
                    ProgressView("Installing…").controlSize(.small)
                case .failed(let log):
                    Label("Installing the companion failed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ScrollView {
                        Text(log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    Button("Try Again") { Task { await install() } }
                }
            }
        }
        .task { await check() }
    }

    private var isCurrent: Bool {
        Launchd.isInstalled && model.state == .online && !CompanionCLI.isOutdated(model.snapshot?.companionVersion)
    }

    private func check() async {
        phase = .checking
        await model.refresh(includePairing: false)
        guard !isCurrent else { return }
        phase = await CompanionCLI.findPython() == nil ? .needsPython : .ready
    }

    private func install() async {
        phase = .installing
        do {
            try await CompanionCLI.install()
            // The service needs a moment to start listening.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                await model.refresh(includePairing: false)
                if isCurrent { break }
            }
            phase = isCurrent ? .ready : .failed("The companion was installed but isn't answering yet. Check the log:\n\(Launchd.log)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Each provider with what was found on this Mac, a switch to track it, and
/// a key field for the providers that take one. Changes apply at once.
struct ProviderSetupList: View {
    @EnvironmentObject private var model: CompanionModel
    /// First run: providers without credentials start off.
    var presetFromDetection = false

    @State var providers: [DetectedProvider] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var keyDrafts: [String: String] = [:]
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && providers.isEmpty {
                ProgressView("Looking for sign-ins…").controlSize(.small).padding(.vertical, 8)
            }
            ForEach(providers) { provider in
                row(provider)
                if provider.id != providers.last?.id { Divider() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Check Again") { Task { await load() } }
                    .disabled(isLoading)
            }
            .padding(.top, 10)
        }
        .task { await load(preset: presetFromDetection) }
    }

    private func row(_ provider: DetectedProvider) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderLogo(providerID: provider.id)
                .frame(width: 18, height: 18)
                .foregroundStyle(UsageFormat.providerTint(provider.id))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(.body.weight(.medium))
                if provider.found {
                    Label(provider.source ?? "Found", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let hint = provider.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if provider.takesKey && (!provider.found || provider.savedKey) {
                    keyField(provider)
                }
            }
            Spacer(minLength: 12)
            if busy.contains(provider.id) {
                ProgressView().controlSize(.small)
            }
            Toggle("Track \(provider.name)", isOn: enabled(provider))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(busy.contains(provider.id))
        }
        .padding(.vertical, 10)
    }

    private func keyField(_ provider: DetectedProvider) -> some View {
        let draft = Binding(get: { keyDrafts[provider.id] ?? "" }, set: { keyDrafts[provider.id] = $0 })
        return HStack {
            SecureField(provider.savedKey ? "Replace the saved key" : (provider.id == "copilot" ? "GitHub token" : "API key"),
                        text: draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { save(draft.wrappedValue, for: provider) }
            Button("Save") { save(draft.wrappedValue, for: provider) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            if provider.savedKey {
                Button("Remove") { change(provider) { try await CompanionCLI.deleteKey(provider: provider.id) } }
            }
        }
        .controlSize(.small)
    }

    private func enabled(_ provider: DetectedProvider) -> Binding<Bool> {
        Binding(
            get: { provider.enabled },
            set: { on in change(provider) { try await CompanionCLI.setEnabled(on, provider: provider.id) } }
        )
    }

    private func save(_ key: String, for provider: DetectedProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        change(provider) {
            try await CompanionCLI.saveKey(key, provider: provider.id)
            keyDrafts[provider.id] = nil
            // A key is only saved to be used.
            if !provider.enabled { try await CompanionCLI.setEnabled(true, provider: provider.id) }
        }
    }

    /// Runs a config change, then re-reads detection and the companion's usage.
    private func change(_ provider: DetectedProvider, _ action: @escaping () async throws -> Void) {
        busy.insert(provider.id)
        Task {
            do {
                try await action()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await load()
            busy.remove(provider.id)
            await model.refresh(includePairing: false, force: true)
        }
    }

    /// `preset`: when every provider is still on (nothing chosen yet), turn
    /// off the ones without credentials.
    private func load(preset: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var detected = try await CompanionCLI.detect()
            if preset, detected.allSatisfy(\.enabled) {
                for provider in detected where !provider.found {
                    try await CompanionCLI.setEnabled(false, provider: provider.id)
                }
                detected = try await CompanionCLI.detect()
                await model.refresh(includePairing: false, force: true)
            }
            providers = detected
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
