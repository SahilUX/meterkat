import SwiftUI
import UIKit

struct ClientsView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        List {
            if !store.clients.isEmpty {
                Section {
                ForEach(Array(store.clients.enumerated()), id: \.element.id) { index, client in
                    NavigationLink(value: SettingsPage.client(client.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(client.name)
                                Text(client.snapshot?.host ?? client.config.routes.first?.baseURL ?? "Waiting for first connection")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                machineLine(client)
                            }
                            Spacer()
                            if index == 0 { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if index != 0 {
                            Button("Make default", systemImage: "star") { store.makeDefault(client.id) }
                                .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "trash", role: .destructive) { store.removeClient(client.id) }
                    }
                }
                } footer: {
                    Text("The default client supplies a provider when more than one client reports the same account. Another client takes over if it is unavailable. Accounts with different names appear separately.")
                }
            }
            Section {
                NavigationLink(value: SettingsPage.addClient) {
                    Label("Add client", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Clients")
        .task { await store.refreshMachineInfo() }
        .refreshable {
            await store.refresh()
            await store.refreshMachineInfo()
        }
    }

    /// "Linux, headless · 2.5.1 · Owner" and whether the machine answered the last refresh.
    private func machineLine(_ client: PairedClient) -> some View {
        let info = store.machineInfo[client.id]
        var parts: [String] = []
        if let system = info?.systemLabel { parts.append(system) }
        if let version = info?.companionVersion ?? client.snapshot?.companionVersion { parts.append("Companion \(version)") }
        if client.ownerDeviceID != nil { parts.append("Owner") }
        let reachability = Reachability(client: client, error: store.clientErrors[client.id])
        return HStack(spacing: 5) {
            Circle().fill(reachability.tint).frame(width: 7, height: 7)
            Text(([reachability.label] + parts).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Whether the last refresh reached a client's companion.
struct Reachability {
    let label: String
    let tint: Color

    init(client: PairedClient, error: String?) {
        if let error {
            let rejected = error.localizedCaseInsensitiveContains("rejected")
            label = rejected ? "Token rejected" : "Unreachable"
            tint = rejected ? .red : .orange
        } else if client.snapshot != nil {
            label = "Reachable"
            tint = .green
        } else {
            label = "Checking"
            tint = .secondary
        }
    }
}

/// Pairing with the companion: scan or paste a pairing link, or edit the
/// addresses and token by hand, then test each route. Pushed from Settings.
struct CompanionSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    var clientID: UUID? = nil
    @State private var addedClientID: UUID?

    @State private var nameText = ""
    @State private var localText = ""
    @State private var remoteText = ""
    @State private var tokenText = ""
    @State private var pairingCode: String?
    @State private var revealToken = false
    @State private var isTesting = false
    @State private var routeChecks: [RouteCheck] = []
    @State private var message: String?
    @State private var showScanner = false
    @State private var showOwnerAccess = false

    /// Result of probing one route after Save & Test.
    struct RouteCheck: Identifiable, Equatable {
        enum Status: Equatable {
            case testing
            case connected(String)
            case failed(String)
        }

        let route: CompanionRoute
        var status: Status = .testing
        var id: CompanionRoute.Kind { route.kind }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Client name", text: $nameText)
                if let effectiveClientID, store.clients.first?.id != effectiveClientID {
                    Button("Make default", systemImage: "star") { store.makeDefault(effectiveClientID) }
                }
            }
            if client != nil { ownerSection }
            pairSection
            connectionSection
            if client != nil {
                statusSection
                forgetSection
            }
        }
        .navigationTitle(clientID == nil ? "Add client" : "Client")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { config in apply(config) }
        }
        .sheet(isPresented: $showOwnerAccess) {
            if let effectiveClientID { OwnerAccessSheet(clientID: effectiveClientID).environmentObject(store) }
        }
        .onAppear { loadConfig() }
        .task { await store.refreshMachineInfo() }
        .onChange(of: store.clients) { _, _ in loadConfig() }
    }

    private var effectiveClientID: UUID? { clientID ?? addedClientID }
    private var client: PairedClient? { store.clients.first { $0.id == effectiveClientID } }

    // MARK: Sections

    private var pairSection: some View {
        Section {
            Button("Scan QR code", systemImage: "qrcode.viewfinder") { showScanner = true }
            Button("Paste pairing link", systemImage: "doc.on.clipboard", action: pastePairingLink)
        } header: {
            Text("Pair")
        } footer: {
            Text("On a Mac, the Meterkat menu bar app shows a pairing QR code. On Linux, `meterkat setup` and `meterkat pair` show one. Scan it here or with the Camera, or copy the meterkat:// link and paste it.")
        }
    }

    private var connectionSection: some View {
        Section {
            urlField(
                "Local URL",
                placeholder: "http://192.168.1.20:47300",
                caption: "Used on your home network",
                text: $localText
            )
            urlField(
                "Remote URL",
                placeholder: "http://100.x.y.z:47300",
                caption: "Tailscale or another address that works away from home",
                text: $remoteText
            )
            if client == nil { tokenField }

            Button {
                Task { await saveAndTest() }
            } label: {
                HStack {
                    Label("Save & Test", systemImage: "checkmark.circle")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(!canSave || isTesting)

            if let message {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(routeChecks) { check in
                routeCheckRow(check)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(client == nil
                 ? "The local address is tried first, then the remote one. Either is optional, but at least one is needed."
                 : "The saved token stays on this iPhone and is hidden here. The local address is tried first, then the remote one.")
        }
    }

    private var statusSection: some View {
        Section {
            if let route = client?.lastRoute {
                SettingsValueRow("Using") {
                    Label(route.kind.label, systemImage: route.kind.systemImage)
                        .labelStyle(.titleAndIcon)
                }
            }
            if let client, let effectiveClientID {
                let reachability = Reachability(client: client, error: store.clientErrors[effectiveClientID])
                SettingsValueRow("Reachability") {
                    HStack(spacing: 5) {
                        Circle().fill(reachability.tint).frame(width: 7, height: 7)
                        Text(reachability.label)
                    }
                }
            }
            if let host = client?.snapshot?.host {
                SettingsValueRow("Computer") { Text(host) }
            }
            if let system = machineInfo?.systemLabel {
                SettingsValueRow("System") { Text(system) }
            }
            if let version = machineInfo?.companionVersion ?? client?.snapshot?.companionVersion {
                SettingsValueRow("Companion version") { Text(version) }
            }
            if let effectiveClientID, let error = store.clientErrors[effectiveClientID] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Status")
        }
    }

    private var machineInfo: MachineMe? { effectiveClientID.flatMap { store.machineInfo[$0] } }

    /// Owner machines get the Devices screen; viewer-only ones get a hint on how to become an owner.
    @ViewBuilder
    private var ownerSection: some View {
        if let effectiveClientID, let client {
            Section {
                if client.ownerDeviceID != nil, OwnerKeychain.token(for: effectiveClientID) != nil {
                    NavigationLink(value: SettingsPage.devices(effectiveClientID)) {
                        Label("Devices", systemImage: "iphone.and.arrow.forward")
                    }
                    Button("Remove owner access from this iPhone", role: .destructive) {
                        store.forgetOwnerAccess(effectiveClientID)
                    }
                } else {
                    Button("Get owner access", systemImage: "key.horizontal") { showOwnerAccess = true }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text(client.ownerDeviceID != nil
                     ? "This iPhone is an owner of this machine. It can list and revoke the devices that read its usage. Removing owner access only forgets it here; this iPhone stays in the machine's device list until you revoke it."
                     : "Paired as a viewer, so this iPhone can read usage but not see or revoke devices. Run `meterkat pair --owner` on the machine to get owner access.")
            }
        }
    }

    private var forgetSection: some View {
        Section {
            Button("Remove client", role: .destructive) {
                if let effectiveClientID { store.removeClient(effectiveClientID) }
                localText = ""
                remoteText = ""
                tokenText = ""
                routeChecks = []
                message = nil
                dismiss()
            }
        } footer: {
            Text("Removes this client's address and token from this iPhone.")
        }
    }

    // MARK: Rows

    private func urlField(_ title: String, placeholder: String, caption: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Token")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Group {
                    if revealToken {
                        TextField("Pairing token", text: $tokenText)
                    } else {
                        SecureField("Pairing token", text: $tokenText)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    revealToken.toggle()
                } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealToken ? "Hide token" : "Show token")
            }
        }
        .padding(.vertical, 2)
    }

    private func routeCheckRow(_ check: RouteCheck) -> some View {
        SettingsValueRow(check.route.kind.label) {
            switch check.status {
            case .testing:
                ProgressView()
            case .connected(let host):
                Text("Connected · \(host)")
                    .foregroundStyle(.green)
            case .failed(let error):
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .font(.subheadline)
    }

    // MARK: Actions

    private func loadConfig() {
        guard let client else { return }
        nameText = client.name
        localText = client.config.localURL ?? ""
        remoteText = client.config.remoteURL ?? ""
        tokenText = ""
        // Drop results for routes that are no longer configured.
        let routes = client.config.routes
        routeChecks.removeAll { !routes.contains($0.route) }
    }

    private var canSave: Bool {
        (client != nil || pairingCode != nil || !trimmed(tokenText).isEmpty) && !(trimmed(localText).isEmpty && trimmed(remoteText).isEmpty)
    }

    private func saveAndTest() async {
        message = nil
        isTesting = true
        var resolvedToken = client?.config.token ?? trimmed(tokenText)
        var grant: OwnerGrant?
        if let pairingCode {
            let link = CompanionConfig(localURL: localText, remoteURL: remoteText, token: "", pairingCode: pairingCode)
            do {
                switch try await store.redeemPairing(link) {
                case .ready(let paired, let owner):
                    resolvedToken = paired.token
                    grant = owner
                case .upgraded(let name):
                    self.pairingCode = nil
                    message = nil
                    isTesting = false
                    store.pairingMessage = "Owner access added to \(name)."
                    if clientID == nil { dismiss() }
                    return
                }
            } catch {
                message = error.localizedDescription
                isTesting = false
                return
            }
            self.pairingCode = nil
        }
        let config = CompanionConfig(localURL: localText, remoteURL: remoteText, token: resolvedToken)
        guard config.isComplete else {
            message = "Enter the token and at least one URL."
            isTesting = false
            return
        }
        routeChecks = config.routes.map { RouteCheck(route: $0) }

        // Save + fetch (which updates the dashboard) while each route is probed on its own.
        let editingID = effectiveClientID
        let clientName = nameText
        async let connecting: String? = {
            if let editingID { return await store.updateClient(editingID, name: clientName, config: config, owner: grant) }
            let error = await store.addClient(config, name: clientName, owner: grant)
            return error
        }()
        await withTaskGroup(of: (CompanionRoute, RouteCheck.Status).self) { group in
            for route in config.routes {
                group.addTask {
                    switch await CompanionClient.probe(route: route, token: config.token) {
                    case .success(let snapshot):
                        return (route, .connected(snapshot.host ?? "companion"))
                    case .failure(let error):
                        return (route, .failed(error.localizedDescription))
                    }
                }
            }
            for await (route, status) in group {
                if let index = routeChecks.firstIndex(where: { $0.route == route }) {
                    routeChecks[index].status = status
                }
            }
        }
        if let error = await connecting { message = error }
        if clientID == nil, addedClientID == nil { addedClientID = store.clients.last?.id }
        isTesting = false
        if clientID == nil && message == nil { dismiss() }
    }

    /// Fills the fields from a scanned or pasted pairing link, then saves and tests.
    private func apply(_ config: CompanionConfig) {
        if PairedClient.isPlaceholderName(nameText), let name = config.name { nameText = name }
        localText = config.localURL ?? ""
        remoteText = config.remoteURL ?? ""
        tokenText = config.token
        pairingCode = config.pairingCode
        Task { await saveAndTest() }
    }

    private func pastePairingLink() {
        guard let raw = UIPasteboard.general.string,
              let config = CompanionConfig(pairingString: raw)
        else {
            message = "The clipboard doesn't contain a meterkat://pair link."
            return
        }
        apply(config)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
