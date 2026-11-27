import SwiftUI

/// The devices that can read one machine's usage, for a machine this iPhone is an owner of.
/// Revoking asks for Face ID, Touch ID or the passcode first.
struct DevicesView: View {
    let clientID: UUID

    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DevicesModel()
    /// Rows showing their exact times.
    @State private var expanded: Set<String> = []
    @State private var pending: DeviceEntry?
    @State private var isRevoking = false
    @State private var notice: String?

    private var client: PairedClient? { store.clients.first { $0.id == clientID } }
    private var token: String? { OwnerKeychain.token(for: clientID) }

    private var routes: [CompanionRoute] {
        guard let client else { return [] }
        var routes = client.config.routes
        if let last = client.lastRoute, let index = routes.firstIndex(of: last) {
            routes.insert(routes.remove(at: index), at: 0)
        }
        return routes
    }

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let list = model.list {
                let mine = list.devices.filter(isThisPhone)
                let others = list.devices.filter { !isThisPhone($0) }
                if !mine.isEmpty {
                    Section {
                        ForEach(mine) { device in row(device) }
                    } header: {
                        Text("This iPhone")
                    } footer: {
                        Text("This iPhone has two devices here: one for managing devices, one for the dashboard, widgets and alerts. Revoking either asks first.")
                    }
                }
                Section {
                    ForEach(others) { device in row(device) }
                    if let shared = list.sharedToken { sharedRow(shared) }
                } header: {
                    Text(mine.isEmpty ? "Authorized devices" : "Other devices")
                } footer: {
                    Text("Tap a row for exact times. Revoking a device stops it at once; it has to pair again. Last active can be a minute behind.")
                }
            } else if model.isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle(client?.name ?? "Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert(item: $pending) { device in
            Alert(
                title: Text("Revoke \(device.name)?"),
                message: Text(warning(for: device)),
                primaryButton: .destructive(Text("Revoke")) { Task { await revoke(device) } },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Rows

    private func isUsageDevice(_ device: DeviceEntry) -> Bool { device.id == client?.usageDeviceID }
    private func isThisPhone(_ device: DeviceEntry) -> Bool { device.current || isUsageDevice(device) }

    private func row(_ device: DeviceEntry) -> some View {
        let isOpen = expanded.contains(device.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(device.name).font(.headline)
                tag(device.role.capitalized, tint: device.isOwner ? .orange : .secondary)
                if device.current { tag("This device", tint: .blue) }
                Spacer(minLength: 0)
            }
            if device.current {
                Text("This iPhone: owner access, for managing devices")
                    .font(.caption).foregroundStyle(.blue)
            } else if isUsageDevice(device) {
                Text("This iPhone: usage for the dashboard, widgets and alerts")
                    .font(.caption).foregroundStyle(.blue)
            }
            detail("Authorized", isOpen ? DeviceTime.exact(device.createdAt) : DeviceTime.relative(device.createdAt))
            detail("Last active", isOpen ? DeviceTime.exact(device.lastUsedAt) : DeviceTime.relative(device.lastUsedAt))
            Button(role: .destructive) {
                pending = device
            } label: {
                Label("Revoke", systemImage: "xmark.shield")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(isRevoking)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggle(device.id) }
        .accessibilityElement(children: .combine)
    }

    private func sharedRow(_ shared: SharedTokenEntry) -> some View {
        let isOpen = expanded.contains("shared")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(shared.label).font(.headline)
                tag("Shared", tint: .secondary)
                if shared.current { tag("This device", tint: .blue) }
                Spacer(minLength: 0)
            }
            detail("Last active", isOpen ? DeviceTime.exact(shared.lastUsedAt) : DeviceTime.relative(shared.lastUsedAt))
            Text("Can't be revoked here. Run `meterkat config rotate-token` on the machine to retire it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggle("shared") }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.subheadline)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func toggle(_ id: String) {
        withAnimation {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Actions

    private func warning(for device: DeviceEntry) -> String {
        let machine = client?.name ?? "this machine"
        if device.current {
            return "This is this iPhone. You'll lose owner access to \(machine) and won't be able to manage its devices from here until you pair as an owner again. Dashboard, widgets and alerts keep working."
        }
        if isUsageDevice(device) {
            return "This is the access this iPhone uses for \(machine)'s usage. The dashboard, widgets and alerts for it stop until you pair \(machine) again."
        }
        return "\(device.name) loses access to \(machine) at once and has to pair again."
    }

    private func load() async {
        guard let token else {
            model.error = "Owner access for this machine isn't on this iPhone any more. Pair it again as an owner."
            return
        }
        await model.load(routes: routes, token: token)
        if model.lostAccess { store.forgetOwnerAccess(clientID); dismiss() }
        #if DEBUG
        await runDebugRevoke()
        #endif
    }

    #if DEBUG
    private static var debugRevokeDone = false

    /// `-MeterkatDebugRevoke NAME` opens the revoke warning for that device, and adding
    /// `-MeterkatDebugConfirm YES` confirms it, so a simulator run can exercise the call.
    private func runDebugRevoke() async {
        guard !Self.debugRevokeDone, let name = UserDefaults.standard.string(forKey: "MeterkatDebugRevoke"),
              let device = model.list?.devices.first(where: { $0.name == name }) else { return }
        Self.debugRevokeDone = true
        if UserDefaults.standard.bool(forKey: "MeterkatDebugConfirm") { await revoke(device) } else { pending = device }
    }
    #endif

    private func revoke(_ device: DeviceEntry) async {
        guard let token else { return }
        notice = nil
        isRevoking = true
        defer { isRevoking = false }
        do {
            try await BiometricGate.confirm(reason: "Revoke \(device.name) from \(client?.name ?? "this machine")")
        } catch let error as BiometricGate.BiometricError {
            if let message = error.errorDescription { model.error = message }
            return
        } catch { return }
        do {
            try await OwnerAPI.revoke(device.id, routes: routes, token: token)
            notice = "\(device.name) was revoked."
            if device.current {
                store.forgetOwnerAccess(clientID)
                dismiss()
                return
            }
            if isUsageDevice(device) { await store.refresh() }
        } catch OwnerError.notFound {
            notice = "\(device.name) was already gone."
        } catch {
            model.error = error.localizedDescription
            return
        }
        await load()
    }
}

/// Explains how to get owner access for a machine paired as a viewer, and takes the owner link.
struct OwnerAccessSheet: View {
    let clientID: UUID

    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var isWorking = false
    @State private var message: String?

    private var client: PairedClient? { store.clients.first { $0.id == clientID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Owner access lets this iPhone see which devices can read \(client?.name ?? "this machine") and revoke them, for example when one is lost. It never creates new owners: that stays on the machine.")
                    Text("On \(client?.name ?? "the machine"), run:")
                    Text("meterkat pair --owner")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Then scan the QR code it shows, or copy the meterkat:// link and paste it here. The link works once and expires after five minutes.")
                }
                Section {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { showScanner = true }
                    Button("Paste owner link", systemImage: "doc.on.clipboard", action: paste)
                    if isWorking { HStack { ProgressView(); Text("Pairing…").foregroundStyle(.secondary) } }
                    if let message {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("Needs companion 2.5.0 or newer on the machine.")
                }
                .disabled(isWorking)
            }
            .navigationTitle("Get owner access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { config in redeem(config) }
            }
        }
    }

    private func paste() {
        guard let raw = UIPasteboard.general.string, let config = CompanionConfig(pairingString: raw) else {
            message = "The clipboard doesn't contain a meterkat://pair link."
            return
        }
        redeem(config)
    }

    private func redeem(_ link: CompanionConfig) {
        guard link.pairingCode != nil else {
            message = "That link has no one-time code. Run `meterkat pair --owner` for a new one."
            return
        }
        // Same address, or the same host name (a link can carry only the other address).
        let machine = Set(client?.config.routes.map(\.baseURL) ?? [])
        let names = [client?.name, client?.snapshot?.host].compactMap { $0?.lowercased() }
        guard !machine.isDisjoint(with: link.routes.map(\.baseURL)) || link.name.map({ names.contains($0.lowercased()) }) == true else {
            message = "That link is for a different machine. Run `meterkat pair --owner` on \(client?.name ?? "this machine")."
            return
        }
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.addOwnerAccess(to: clientID, link: link)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
