import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Screens pushed from the Settings root.
enum SettingsPage: Hashable {
    case clients
    case client(UUID)
    case addClient
    case devices(UUID)
    case display
    case provider(ProviderID)
}

/// Settings root: navigation rows for clients, each provider and the
/// display options, plus the about section inline.
struct SettingsView: View {
    /// Parts of the root list that can be scrolled to on appear.
    enum Anchor: Hashable {
        case providers
    }

    @EnvironmentObject private var store: UsageStore

    @State private var path: NavigationPath
    @State private var pendingAnchor: Anchor?
    @State private var exportingSkill = false
    @State private var skillExportError: String?

    /// `initialPath` opens sub-pages right away, e.g. for the debug screen router.
    init(initialPath: [SettingsPage] = [], scrollTo anchor: Anchor? = nil) {
        _path = State(initialValue: NavigationPath(initialPath))
        _pendingAnchor = State(initialValue: anchor)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    clientsSection
                    displaySection
                    providersSection
                    aboutSection
                }
                .task {
                    // Once, after the first layout pass.
                    guard let anchor = pendingAnchor else { return }
                    pendingAnchor = nil
                    try? await Task.sleep(for: .milliseconds(100))
                    switch anchor {
                    case .providers:
                        let first = ProviderID.signedInFirst(in: store.snapshot).first ?? .claude
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .clients: ClientsView()
                case .client(let id): CompanionSettingsView(clientID: id)
                case .addClient: CompanionSettingsView()
                case .devices(let id): DevicesView(clientID: id)
                case .display: DisplaySettingsView()
                case .provider(let provider): ProviderSettingsView(provider: provider)
                }
            }
            .fileExporter(isPresented: $exportingSkill, document: SkillDocument(),
                          contentType: UTType(filenameExtension: "md") ?? .plainText,
                          defaultFilename: "SKILL.md") { result in
                if case .failure(let error) = result { skillExportError = error.localizedDescription }
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
    }

    // MARK: Clients

    private var clientsSection: some View {
        Section {
            NavigationLink(value: SettingsPage.clients) {
                SettingsRowLabel(title: "Clients", subtitle: clientsSummary) {
                    Image(systemName: "laptopcomputer")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private var clientsSummary: String {
        let count = store.clients.count
        return count == 0 ? "No clients paired" : "\(count) paired · \(store.clients.first?.name ?? "Default") is default"
    }

    // MARK: Providers

    private var providersSection: some View {
        Section {
            ForEach(ProviderID.signedInFirst(in: store.snapshot)) { provider in
                NavigationLink(value: SettingsPage.provider(provider)) {
                    providerRow(provider)
                }
                .id(provider)
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Turn providers on or off and choose their alerts.")
        }
    }

    private func providerRow(_ provider: ProviderID) -> some View {
        SettingsRowLabel(
            title: provider.displayName,
            subtitle: provider.statusSummary(in: store.snapshot),
            trailing: store.settings[provider].enabled ? nil : "Off"
        ) {
            ProviderLogo(providerID: provider.rawValue)
                .foregroundStyle(UsageFormat.providerTint(provider.rawValue))
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            NavigationLink(value: SettingsPage.display) {
                SettingsRowLabel(title: "Display", subtitle: displaySummary) {
                    Image(systemName: "chart.bar.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    /// "Bars · Used" / "Graph · Remaining".
    private var displaySummary: String {
        "\(store.settings.usageStyle.label) · \(store.settings.barMode.label)"
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            Button("Setup guide", systemImage: "list.bullet.clipboard") {
                store.showOnboarding = true
            }

            Button("Save Meterkat skill", systemImage: "square.and.arrow.up") {
                exportingSkill = true
            }

            Text("Save SKILL.md to Downloads in Files, then add it to your AI tool on the computer running the companion.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("How it works")
                    .font(.headline)
                Text("Each companion reads the logins on its computer for Claude Code, Codex, OpenCode, GitHub Copilot, Gemini CLI, Cursor, Kimi Code, MiniMax and Alibaba Model Studio (and OpenRouter, Z.ai, or DeepSeek API keys, if you add them). It asks each provider for usage and serves a summary to this phone over your local network or Tailscale. Provider tokens stay on their computers; the phone stores a pairing token for each client.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Apps installed with a free Apple developer account expire after 7 days. Reinstall from Xcode each week to keep Meterkat and its widgets running.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            SettingsValueRow("Version") { Text(appVersion) }
            if let version = store.snapshot?.companionVersion {
                SettingsValueRow("Companion") { Text(version) }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Rows

/// Icon, title and a one-line summary for a navigation row. The icon scales
/// with Dynamic Type; the text wraps instead of truncating at large sizes.
struct SettingsRowLabel<Icon: View>: View {
    var title: String
    var subtitle: String
    var trailing: String?
    @ViewBuilder var icon: Icon

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18

    init(title: String, subtitle: String, trailing: String? = nil, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: iconSize * 1.3, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A title with a value on the trailing edge, e.g. "Using  (wifi) Local
/// network". At accessibility text sizes the value moves under the title so
/// neither side gets squeezed. Use this rather than `LabeledContent` around a
/// `Label`, which can lay out hundreds of points tall at those sizes.
struct SettingsValueRow<Value: View>: View {
    var title: String
    @ViewBuilder var value: Value

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            value
                .foregroundStyle(.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
