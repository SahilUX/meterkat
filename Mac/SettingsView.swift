import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings()
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            ScrollView {
                PairingSection().padding(20)
            }
            .tabItem { Label("iPhone", systemImage: "iphone") }
            MachinesSettings()
                .tabItem { Label("Machines", systemImage: "server.rack") }
        }
        .frame(width: 540, height: 560)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: CompanionModel
    @AppStorage(Prefs.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @AppStorage(Prefs.barMode) private var barMode = BarMode.used
    @AppStorage(Prefs.panelStyle) private var panelStyle = UsageStyle.bars
    @State private var skillExportError: String?
    @AppStorage(Prefs.setupDone) private var setupDone = false
    @Environment(\.openWindow) private var openWindow
    @State private var isUpdating = false
    @State private var updateError: String?
    @State private var startAtLogin = Launchd.LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { setStartAtLogin($0) }
                ))
            }
            Section {
                // One of the two stays on, or the app couldn't be reached.
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                    .disabled(!showInDock)
                Toggle("Show in Dock", isOn: $showInDock)
                    .disabled(!showInMenuBar)
            } footer: {
                Text("One of these stays on so you can always reach Meterkat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Usage") {
                Picker("Show", selection: $barMode) {
                    ForEach(BarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Windows", selection: $panelStyle) {
                    ForEach(UsageStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Companion") {
                LabeledContent("Status") { StatusIndicator() }
                if let version = model.snapshot?.companionVersion {
                    LabeledContent("Version") {
                        HStack {
                            Text(version)
                            if CompanionCLI.isOutdated(version), let bundled = CompanionCLI.bundledVersion {
                                Button(isUpdating ? "Updating…" : "Update to \(bundled)") { update() }
                                    .disabled(isUpdating)
                            }
                        }
                    }
                }
                LabeledContent("Setup") {
                    Button("Run Setup Again…") {
                        setupDone = false
                        openWindow(id: MainWindow.id)
                        NSApp.activate()
                    }
                }
                LabeledContent("Log") {
                    Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: Launchd.log)) }
                }
            }
            Section("AI access") {
                Button("Save Meterkat skill…") { saveSkill() }
                Text("Save SKILL.md to Downloads and add it to your AI tool. The skill reads the companion's usage limits through the local CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: panelStyle) { Task { await model.loadHistoryIfStale() } }
        .alert("Couldn't update the companion", isPresented: Binding(
            get: { updateError != nil },
            set: { if !$0 { updateError = nil } }
        )) {
            Button("OK", role: .cancel) { updateError = nil }
        } message: {
            Text(updateError ?? "")
        }
        .alert("Couldn't change the login item", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK", role: .cancel) { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // `meterkat install` and `meterkat uninstall` also change it.
            startAtLogin = Launchd.LoginItem.isEnabled
        }
        .alert("Couldn't save the skill", isPresented: Binding(
            get: { skillExportError != nil },
            set: { if !$0 { skillExportError = nil } }
        )) {
            Button("OK", role: .cancel) { skillExportError = nil }
        } message: {
            Text(skillExportError ?? "")
        }
    }

    /// Registers or removes Meterkat as a login item.
    private func setStartAtLogin(_ on: Bool) {
        do {
            try Launchd.LoginItem.setEnabled(on)
        } catch {
            loginItemError = error.localizedDescription
        }
        startAtLogin = Launchd.LoginItem.isEnabled
    }

    /// Reinstalls the companion from the copy in this app.
    private func update() {
        isUpdating = true
        Task {
            do {
                try await CompanionCLI.install()
                try? await Task.sleep(for: .seconds(2))
                await model.refresh(force: true)
            } catch {
                updateError = error.localizedDescription
            }
            isUpdating = false
        }
    }

    private func saveSkill() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "SKILL.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try SkillFile.data().write(to: url, options: .atomic)
            } catch {
                skillExportError = error.localizedDescription
            }
        }
    }
}

/// Which providers the companion tracks, and their keys.
struct ProvidersSettings: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Providers you turn off aren't checked, and they disappear here and on your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProviderSetupList()
            }
            .padding(20)
        }
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject private var model: CompanionModel
    @AppStorage(Prefs.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Prefs.iconStyle) private var iconStyle = IconStyle.combined
    @AppStorage(Prefs.showLogos) private var showLogos = true
    @AppStorage(Prefs.colored) private var colored = false
    @AppStorage(Prefs.hiddenProviders) private var hiddenProviders = ""

    var body: some View {
        Form {
            Section {
                Picker("Icon", selection: $iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Provider logos", isOn: $showLogos)
                Toggle("Provider colors", isOn: $colored)
            } footer: {
                if !showInMenuBar {
                    Text("Meterkat isn't in the menu bar. Turn it on in General.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Providers in the menu bar") {
                ForEach(providerChoices, id: \.id) { choice in
                    Toggle(choice.name, isOn: shown(choice.id))
                        .disabled(!choice.hasLimits)
                        .help(choice.hasLimits ? "" : "No limits to show right now")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!showInMenuBar)
    }

    /// Providers the companion reports, or the known ones before the first fetch.
    private var providerChoices: [(id: String, name: String, hasLimits: Bool)] {
        let providers = model.providers
        guard !providers.isEmpty else {
            return ProviderID.allCases.map { ($0.rawValue, $0.displayName, true) }
        }
        return providers.map { ($0.id, $0.name, !$0.menuBarWindows.isEmpty) }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !Prefs.ids(hiddenProviders).contains(id) },
            set: { shown in
                var hidden = Prefs.ids(hiddenProviders)
                if shown { hidden.remove(id) } else { hidden.insert(id) }
                hiddenProviders = Prefs.raw(hidden)
            }
        )
    }
}

/// The pairing QR code and addresses for the iPhone app.
struct PairingSection: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var copied: String?
    /// Off where the surrounding view already says "Pair your iPhone".
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Pair iPhone").font(.subheadline.weight(.semibold))
            }
            if let pairing = model.pairing {
                if let qr = model.qrCode {
                    VStack(spacing: 6) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        Text("Scan with the Meterkat app or the iPhone Camera")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Code expires after 5 minutes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                urlRow("Local", pairing.local)
                urlRow("Remote", pairing.remote)
                Button { copy(pairing.link, key: "link") } label: {
                    Label(copied == "link" ? "Copied" : "Copy pairing link",
                          systemImage: copied == "link" ? "checkmark" : "link")
                }
                .controlSize(.small)
                Button("Refresh code", systemImage: "arrow.clockwise") {
                    Task { await model.refresh(includePairing: true, force: true) }
                }
                .controlSize(.small)
            } else {
                Text(model.pairingIssue ?? (model.state == .online ? "Loading…" : "Available once the companion is running"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func urlRow(_ title: String, _ url: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(url ?? "not available")
                .font(.caption.monospaced())
                .foregroundStyle(url == nil ? HierarchicalShapeStyle.tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let url {
                Button { copy(url, key: title) } label: {
                    Image(systemName: copied == title ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(title.lowercased()) URL")
            }
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == key { copied = nil }
        }
    }
}
