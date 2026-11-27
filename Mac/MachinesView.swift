import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Machines: this Mac's companion, and the headless or remote machines you manage
/// from here. Each machine's Devices tab lists who is paired with it and lets you revoke them.
struct MachinesSettings: View {
    @EnvironmentObject private var machines: MachinesModel
    @State private var selected: String?
    @State private var showAdd = false

    init(selected: String? = nil) {
        _selected = State(initialValue: selected)
    }

    var body: some View {
        Group {
            if let selected {
                MachineDetail(id: selected) { self.selected = nil }
            } else {
                list
            }
        }
        .task {
            while !Task.isCancelled {
                await machines.refreshAll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    MachineRow(id: MachinesModel.localID) { selected = MachinesModel.localID }
                } header: {
                    Text("This Mac")
                }
                Section {
                    if machines.machines.isEmpty {
                        Text("No other machines yet. Run `meterkat pair --owner` on a server or another computer, then add it here with the link it prints.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(machines.machines) { machine in
                        MachineRow(id: machine.id.uuidString) { selected = machine.id.uuidString }
                    }
                } header: {
                    HStack {
                        Text("Other machines")
                        Spacer()
                        Button("Add machine…", systemImage: "plus") { showAdd = true }
                            .controlSize(.small)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddMachineSheet() }
    }
}

private struct MachineRow: View {
    @EnvironmentObject private var machines: MachinesModel
    let id: String
    let open: () -> Void

    var body: some View {
        let status = machines.status(for: id)
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: icon(status))
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(status)).font(.body.weight(.medium))
                    Text(subtitle(status)).font(.caption).foregroundStyle(.secondary)
                    if let summary = providerSummary(status) {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LinkBadge(link: status.link)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(_ status: MachinesModel.Status) -> String {
        if id == MachinesModel.localID { return status.host ?? MachinesModel.thisMacName }
        return machines.name(for: id)
    }

    private func icon(_ status: MachinesModel.Status) -> String {
        if id == MachinesModel.localID { return "laptopcomputer" }
        return status.me?.headless == true ? "server.rack" : "desktopcomputer"
    }

    private func subtitle(_ status: MachinesModel.Status) -> String {
        var parts: [String] = []
        if let system = status.me?.systemLabel { parts.append(system) }
        if let version = status.version { parts.append("companion \(version)") }
        return parts.isEmpty ? (id == MachinesModel.localID ? "The companion on this Mac" : "Checking…") : parts.joined(separator: " · ")
    }

    private func providerSummary(_ status: MachinesModel.Status) -> String? {
        let parts = status.providers.filter(\.isOK).compactMap { provider -> String? in
            guard let window = provider.windows.first(where: { $0.kind == "session" }) ?? provider.windows.first else { return nil }
            return "\(provider.name) \(Int(window.effectivePercent().rounded()))%"
        }
        return parts.isEmpty ? nil : parts.prefix(4).joined(separator: " · ")
    }
}

private struct LinkBadge: View {
    let link: MachinesModel.Link

    var body: some View {
        switch link {
        case .checking:
            ProgressView().controlSize(.small)
        case .online:
            Label("Online", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.green)
        case .offline:
            Label("Unreachable", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
        case .rejected:
            Label("Access revoked", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Label("Problem", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .help(message)
        }
    }
}

// MARK: - One machine

private struct MachineDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case devices = "Devices"
        var id: String { rawValue }
    }

    @EnvironmentObject private var machines: MachinesModel
    let id: String
    let back: () -> Void
    @State private var tab = Tab.devices
    @State private var confirmRemove = false

    var body: some View {
        let status = machines.status(for: id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) { Label("Machines", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(id == MachinesModel.localID ? "This Mac" : machines.name(for: id))
                    .font(.headline)
                Spacer()
                LinkBadge(link: status.link)
            }
            .padding([.horizontal, .top], 16)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            switch tab {
            case .overview: overview(status)
            case .devices: DevicesList(id: id)
            }
        }
        .task { await machines.refresh(id) }
    }

    private func overview(_ status: MachinesModel.Status) -> some View {
        Form {
            Section {
                LabeledContent("Status") { LinkBadge(link: status.link) }
                if let host = status.host ?? status.me?.host { LabeledContent("Host name", value: host) }
                if let system = status.me?.systemLabel { LabeledContent("System", value: system) }
                if let version = status.version { LabeledContent("Companion", value: version) }
                if let role = status.me?.role, id != MachinesModel.localID {
                    LabeledContent("This Mac is", value: role == "owner" ? "an owner" : role)
                }
                if let machine = machine {
                    LabeledContent("Address") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(machine.routes, id: \.baseURL) { route in
                                Text(route.baseURL).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            if !status.providers.isEmpty {
                Section("Providers") {
                    ForEach(status.providers) { provider in
                        LabeledContent(provider.name) { Text(providerText(provider)).foregroundStyle(.secondary) }
                    }
                }
            }
            if let machine {
                Section {
                    Button("Remove from this Mac…", role: .destructive) { confirmRemove = true }
                    Note("This Mac's own device stays in \(machine.name)'s list until you revoke it there.")
                }
                .confirmationDialog("Remove \(machine.name) from this Mac?", isPresented: $confirmRemove) {
                    Button("Remove", role: .destructive) {
                        machines.remove(machine)
                        back()
                    }
                } message: {
                    Text("Meterkat forgets its access. You can add the machine again with a new owner link.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var machine: MachinesModel.Machine? {
        UUID(uuidString: id).flatMap { uuid in machines.machines.first { $0.id == uuid } }
    }

    private func providerText(_ provider: ProviderUsage) -> String {
        guard provider.isOK else { return provider.status.replacingOccurrences(of: "_", with: " ") }
        let windows = provider.windows.prefix(3).map { "\($0.label) \(Int($0.effectivePercent().rounded()))%" }
        return windows.joined(separator: " · ")
    }
}

// MARK: - Devices

private struct DevicesList: View {
    @EnvironmentObject private var machines: MachinesModel
    let id: String
    @State private var pending: DeviceEntry?
    @State private var revokeError: String?

    var body: some View {
        let status = machines.status(for: id)
        List {
            if let issue = status.devicesIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else if status.link != .online && status.devices == nil {
                Text(status.link == .checking ? "Loading…" : "The machine isn't reachable right now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let list = status.devices {
                Section {
                    if list.devices.isEmpty {
                        Text("No devices have paired yet. Pair one with `meterkat pair`.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(list.devices) { device in
                        DeviceRow(device: device) { pending = device }
                    }
                    Note("Authorized is when the pairing code was used. Last active can lag by about a minute.")
                }
                if let shared = list.sharedToken {
                    Section {
                        SharedRow(shared: shared)
                        Note("Older app versions, and this Mac's widgets, use the shared token. It can't be revoked on its own. `meterkat config rotate-token` replaces it, and every client still holding it must pair again.")
                    }
                }
            }
        }
        .confirmationDialog(
            pending.map { "Revoke \($0.name)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { device in
            Button("Revoke \(device.name)", role: .destructive) { revoke(device) }
        } message: { device in
            Text(warning(for: device))
        }
        .alert("Couldn't revoke", isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })) {
            Button("OK", role: .cancel) { revokeError = nil }
        } message: {
            Text(revokeError ?? "")
        }
    }

    private func warning(for device: DeviceEntry) -> String {
        var text = "It stops working at once and has to pair again to come back."
        if device.current {
            text = "This is the device this Mac uses to manage \(machines.name(for: id)). " +
                "Revoking it ends that access, and you would need a new owner link to add the machine again. " + text
        } else if device.isOwner {
            text = "It is an owner: it can manage this machine's devices. " + text
        }
        return text
    }

    private func revoke(_ device: DeviceEntry) {
        Task {
            do {
                try await machines.revoke(device, on: id)
            } catch {
                revokeError = error.localizedDescription
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceEntry
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body.weight(.medium))
                    Tag(text: device.role, tint: device.isOwner ? .orange : .secondary)
                    if device.current { Tag(text: "this device", tint: .blue) }
                }
                HStack(spacing: 12) {
                    TimeText(title: "Authorized", date: device.createdAt, emptyText: "unknown")
                    TimeText(title: "Last active", date: device.lastUsedAt, emptyText: "never")
                }
            }
            Spacer()
            Button("Revoke", role: .destructive, action: onRevoke)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

private struct SharedRow: View {
    let shared: SharedTokenEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(shared.label).font(.body.weight(.medium))
                Tag(text: "shared", tint: .secondary)
                if shared.current { Tag(text: "this device", tint: .blue) }
            }
            TimeText(title: "Last active", date: shared.lastUsedAt, emptyText: "never")
        }
        .padding(.vertical, 3)
    }
}

/// A wrapped explanation under a group of rows. (A List section's footer truncates to one line.)
private struct Note: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// "Authorized 3 days ago", with the exact time on hover.
private struct TimeText: View {
    let title: String
    let date: Date?
    let emptyText: String

    var body: some View {
        Text("\(title) \(relative)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.map { Self.exact.string(from: $0) } ?? "")
    }

    private var relative: String {
        guard let date else { return emptyText }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let exact: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Adding a machine

private struct AddMachineSheet: View {
    @EnvironmentObject private var machines: MachinesModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a machine").font(.title3.weight(.semibold))
            Text("On the machine, run `meterkat pair --owner`. Paste the link it prints, or choose a screenshot of its QR code. The link works once and expires after five minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("meterkat://pair?…", text: $link, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            HStack {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) { link = text }
                }
                Button("Choose QR image…", systemImage: "qrcode") { chooseImage() }
                Spacer()
            }
            .controlSize(.small)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(machines.isAdding ? "Adding…" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || machines.isAdding)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        error = nil
        Task {
            do {
                try await machines.add(link: link)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = QRImageReader.text(in: url) {
            link = text
            error = nil
        } else {
            error = "No QR code found in that image."
        }
    }
}
