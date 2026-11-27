import Foundation
import SwiftUI
import WidgetKit

enum AppTab: Hashable {
    case dashboard
    case settings
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot? = SharedStore.lastSnapshot
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var config: CompanionConfig? = SharedStore.config
    @Published private(set) var clients: [PairedClient] = SharedStore.clients
    @Published private(set) var clientErrors: [UUID: String] = [:]
    /// What each machine says about itself (GET /v1/me). Missing for companions before 2.5.0.
    @Published private(set) var machineInfo: [UUID: MachineMe] = [:]
    @Published var selectedTab: AppTab = .dashboard
    @Published var pairingMessage: String?
    @Published var pendingPairing: CompanionConfig?
    /// Drives the onboarding full-screen cover. Settings can set it back to true.
    @Published var showOnboarding = !SharedStore.hasCompletedOnboarding
    /// The route (local or remote) the last successful fetch used.
    @Published var route: CompanionRoute? = SharedStore.lastRoute
    /// Per-provider preferences and display style. Change via `updateSettings`.
    @Published private(set) var settings: UsageSettings = SharedStore.usageSettings
    /// Recorded usage for each window's current cycle, for the graphs.
    @Published var history: UsageHistory? = SharedStore.lastHistory

    private var autoRefreshTask: Task<Void, Never>?
    /// The latest alert run; each run waits for the one before it.
    private var alertsTask: Task<Void, Never>?

    var isPaired: Bool { clients.contains { $0.config.isComplete } }

    /// Providers from the latest snapshot that are turned on, in `ProviderID` order.
    var visibleProviders: [ProviderUsage] {
        guard let snapshot else { return [] }
        return snapshot.providers.enumerated()
            .filter { settings.isEnabled($0.element.id) }
            .sorted { lhs, rhs in
                let order = ProviderID.allCases.map(\.rawValue)
                let lhsOrder = order.firstIndex(of: lhs.element.id) ?? .max
                let rhsOrder = order.firstIndex(of: rhs.element.id) ?? .max
                return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
            }
            .map(\.element)
    }

    /// Saves settings, then re-evaluates alerts and widgets against them.
    func updateSettings(_ newSettings: UsageSettings) {
        guard newSettings != settings else { return }
        SharedStore.usageSettings = newSettings
        settings = newSettings
        WidgetCenter.shared.reloadAllTimelines()
        if let snapshot { processAlerts(snapshot) }
    }

    /// Fetches from the companion unless a fetch is already running.
    func refresh() async {
        guard isPaired, !isLoading else { return }
        _ = await fetchClients()
    }

    /// Saves the config, fetches with it and returns an error message (nil on success).
    @discardableResult
    func connect(_ newConfig: CompanionConfig, owner: OwnerGrant? = nil) async -> String? {
        save(config: newConfig, owner: owner)
        _ = await fetchClients()
        return clients.first.flatMap { clientErrors[$0.id] }
    }

    func save(config newConfig: CompanionConfig?, owner: OwnerGrant? = nil) {
        if let newConfig {
            if clients.isEmpty {
                clients = [PairedClient(name: newConfig.name ?? PairedClient.defaultName, config: newConfig)]
            } else {
                if clients[0].config != newConfig {
                    clients[0].snapshot = nil
                    clients[0].history = nil
                }
                clients[0].config = newConfig
                clients[0].adoptHostName(newConfig.name)
                if !newConfig.routes.contains(clients[0].lastRoute ?? CompanionRoute(kind: .local, baseURL: "")) {
                    clients[0].lastRoute = nil
                }
            }
            if let owner, let first = clients.first { attach(owner, to: first.id) }
            startLoop(refreshFirst: false)
        } else if !clients.isEmpty {
            forgetOwnerAccess(clients[0].id)
            clients.removeFirst()
        }
        persistClients()
    }

    func addClient(_ config: CompanionConfig, name: String, owner: OwnerGrant? = nil) async -> String? {
        if clients.contains(where: { $0.config == config }) { return "This client is already paired." }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = config.name ?? "Client \(clients.count + 1)"
        let added = PairedClient(name: trimmed.isEmpty ? fallback : trimmed, config: config)
        clients.append(added)
        if let owner { attach(owner, to: added.id) }
        persistClients()
        startLoop(refreshFirst: false)
        _ = await fetchClients()
        return clientErrors[added.id]
    }

    func updateClient(_ id: UUID, name: String, config: CompanionConfig, owner: OwnerGrant? = nil) async -> String? {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { clients[index].name = trimmed }
        if clients[index].config != config {
            clients[index].snapshot = nil
            clients[index].history = nil
            clients[index].lastRoute = nil
        }
        clients[index].config = config
        if let owner { attach(owner, to: id) }
        persistClients()
        _ = await fetchClients()
        return clientErrors[id]
    }

    func removeClient(_ id: UUID) {
        OwnerKeychain.delete(id)
        clients.removeAll { $0.id == id }
        clientErrors.removeValue(forKey: id)
        machineInfo.removeValue(forKey: id)
        if clients.isEmpty { stopAutoRefresh() }
        persistClients()
        publishMerged()
        if clients.isEmpty { Task { await NotificationManager.clearAlerts() } }
    }

    func makeDefault(_ id: UUID) {
        guard let index = clients.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let chosen = clients.remove(at: index)
        clients.insert(chosen, at: 0)
        persistClients()
        publishMerged()
    }

    // MARK: Owner access

    /// What redeeming a pairing link produced.
    enum PairingResult {
        /// A usage token for a new or edited client, and the owner access that came with it.
        case ready(CompanionConfig, OwnerGrant?)
        /// An owner link for a machine that is already paired: it gained owner access (the client's name).
        case upgraded(String)
    }

    /// What this iPhone is called in a machine's device list.
    static var deviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
    }

    /// Redeems the link's one-time code. A viewer link gives the usual shared token, exactly as
    /// before. An owner link (`meterkat pair --owner`) gives this iPhone an owner device: its token goes
    /// in the Keychain. A machine that isn't paired yet also gets a viewer device for widgets and
    /// background refresh, which can't read the Keychain item.
    func redeemPairing(_ config: CompanionConfig) async throws -> PairingResult {
        guard let code = config.pairingCode else { return .ready(config, nil) }
        let routes = config.routes
        do {
            let reply = try await OwnerAPI.pair(code: code, name: nil, routes: routes)
            var paired = CompanionConfig(localURL: config.localURL, remoteURL: config.remoteURL, token: reply.token)
            paired.name = config.name
            return .ready(paired, nil)
        } catch OwnerError.nameRequired {
            return try await redeemOwnerLink(config, code: code)
        }
    }

    private func redeemOwnerLink(_ config: CompanionConfig, code: String) async throws -> PairingResult {
        let routes = config.routes
        guard OwnerKeychain.isWritable() else {
            throw OwnerError.http(0, "Couldn't use the Keychain on this iPhone, so owner access can't be saved. The link wasn't used.")
        }
        let reply = try await OwnerAPI.pair(code: code, name: Self.deviceName, routes: routes)
        guard reply.role == "owner", let deviceID = reply.deviceId else { throw OwnerError.notOwnerLink }
        var grant = OwnerGrant(token: reply.token, deviceID: deviceID, usageDeviceID: nil)
        let known = Set(routes.map(\.baseURL))
        if let existing = clients.first(where: { !known.isDisjoint(with: $0.config.routes.map(\.baseURL)) }) {
            guard attach(grant, to: existing.id) else {
                try? await OwnerAPI.revoke(deviceID, routes: routes, token: grant.token)
                throw OwnerError.http(0, "Couldn't save the owner token in the Keychain.")
            }
            persistClients()
            return .upgraded(existing.name)
        }
        do {
            let usageCode = try await OwnerAPI.viewerPairingCode(routes: routes, ownerToken: grant.token)
            let usage = try await OwnerAPI.pair(code: usageCode, name: "\(Self.deviceName) (usage)", routes: routes)
            grant.usageDeviceID = usage.deviceId
            var paired = CompanionConfig(localURL: config.localURL, remoteURL: config.remoteURL, token: usage.token)
            paired.name = config.name
            return .ready(paired, grant)
        } catch {
            // Don't leave a stray owner device on the machine.
            try? await OwnerAPI.revoke(deviceID, routes: routes, token: grant.token)
            throw error
        }
    }

    @discardableResult
    private func attach(_ grant: OwnerGrant, to id: UUID) -> Bool {
        guard let index = clients.firstIndex(where: { $0.id == id }),
              OwnerKeychain.set(grant.token, for: id) else { return false }
        clients[index].ownerDeviceID = grant.deviceID
        clients[index].usageDeviceID = grant.usageDeviceID ?? clients[index].usageDeviceID
        return true
    }

    /// Adds owner access to a client that is already paired, from an owner link.
    func addOwnerAccess(to id: UUID, link: CompanionConfig) async throws {
        guard let code = link.pairingCode else { throw OwnerError.pairingFailed }
        let routes = link.routes
        guard OwnerKeychain.isWritable() else {
            throw OwnerError.http(0, "Couldn't use the Keychain on this iPhone, so owner access can't be saved. The link wasn't used.")
        }
        let reply: OwnerAPI.PairReply
        do {
            reply = try await OwnerAPI.pair(code: code, name: nil, routes: routes)
        } catch OwnerError.nameRequired {
            reply = try await OwnerAPI.pair(code: code, name: Self.deviceName, routes: routes)
        }
        guard reply.role == "owner", let deviceID = reply.deviceId else { throw OwnerError.notOwnerLink }
        guard attach(OwnerGrant(token: reply.token, deviceID: deviceID, usageDeviceID: nil), to: id) else {
            try? await OwnerAPI.revoke(deviceID, routes: routes, token: reply.token)
            throw OwnerError.http(0, "Couldn't save the owner token in the Keychain.")
        }
        persistClients()
    }

    /// Drops this iPhone's owner token for a client; the usage token stays.
    func forgetOwnerAccess(_ id: UUID) {
        OwnerKeychain.delete(id)
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[index].ownerDeviceID = nil
        clients[index].usageDeviceID = nil
        persistClients()
    }

    /// Asks each machine who it is (OS, version). Companions before 2.5.0 have no /v1/me.
    func refreshMachineInfo(missingOnly: Bool = false) async {
        let current = clients.filter { !missingOnly || machineInfo[$0.id] == nil }
        await withTaskGroup(of: (UUID, MachineMe?).self) { group in
            for client in current {
                group.addTask {
                    var routes = client.config.routes
                    if let last = client.lastRoute, let index = routes.firstIndex(of: last) {
                        routes.insert(routes.remove(at: index), at: 0)
                    }
                    return (client.id, try? await OwnerAPI.me(routes: routes, token: client.config.token))
                }
            }
            for await (id, me) in group {
                if let me { machineInfo[id] = me }
            }
        }
    }

    private func persistClients() {
        SharedStore.clients = clients
        config = clients.first?.config
        route = clients.first?.lastRoute
        SharedStore.lastRoute = route
    }

    private func publishMerged() {
        snapshot = ClientMerge.snapshot(clients, unavailable: Set(clientErrors.keys))
        history = ClientMerge.history(clients, snapshot: snapshot)
        SharedStore.lastSnapshot = snapshot
        SharedStore.lastHistory = history
        WatchSync.shared.publish(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func completeOnboarding() {
        SharedStore.hasCompletedOnboarding = true
        showOnboarding = false
    }

    func handleOpenURL(_ url: URL) {
        // Widgets open meterkat://open; only meterkat://pair links carry a pairing.
        guard url.host == "pair" else {
            selectedTab = .dashboard
            return
        }
        guard let newConfig = CompanionConfig(pairingURL: url) else {
            pairingMessage = "That link isn't a valid Meterkat pairing link."
            return
        }
        if isPaired, !clients.contains(where: { $0.config == newConfig }) {
            pendingPairing = newConfig
            return
        }
        acceptPairing(newConfig)
    }

    /// Connects to a config from a pairing link and reports the outcome in `pairingMessage`.
    func acceptPairing(_ newConfig: CompanionConfig) {
        pendingPairing = nil
        if clients.contains(where: { $0.config == newConfig }) {
            pairingMessage = "This client is already paired."
            return
        }
        selectedTab = .settings
        Task {
            do {
                switch try await redeemPairing(newConfig) {
                case .upgraded(let name):
                    pairingMessage = "Owner access added to \(name)."
                case .ready(let paired, let owner):
                    let error: String?
                    if clients.isEmpty { error = await connect(paired, owner: owner) }
                    else { error = await addClient(paired, name: "", owner: owner) }
                    if let error {
                        pairingMessage = "Pairing saved, but the client couldn't be reached: \(error)"
                    } else {
                        pairingMessage = owner == nil ? "Client added." : "Client added with owner access."
                    }
                }
            } catch {
                pairingMessage = error.localizedDescription
            }
        }
    }

    // MARK: Foreground auto-refresh

    /// Starts the 60s foreground loop (refreshes immediately). No-op if already running.
    func startAutoRefresh() {
        startLoop(refreshFirst: true)
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    // MARK: Private

    private func startLoop(refreshFirst: Bool) {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            if !refreshFirst { try? await Task.sleep(for: .seconds(60)) }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Runs `NotificationManager.process` after any run still in flight, so a
    /// settings change during a fetch can't read the fired-alert history
    /// before the other run writes it and deliver the same alert twice.
    @discardableResult
    private func processAlerts(_ snapshot: UsageSnapshot) -> Task<Void, Never> {
        let previous = alertsTask
        let task = Task {
            await previous?.value
            await NotificationManager.process(snapshot)
        }
        alertsTask = task
        return task
    }

    private func fetchClients() async -> String? {
        isLoading = true
        defer { isLoading = false }
        let requested = clients
        let result = await ClientMerge.refresh(requested)
        // A pairing may have changed while requests were in flight.
        guard requested.map(\.id) == clients.map(\.id),
              zip(requested, clients).allSatisfy({ pair in pair.0.config == pair.1.config }) else { return nil }
        // Owner access may have been added or dropped while the requests were in flight.
        clients = result.clients.map { fetched in
            var client = fetched
            if let now = clients.first(where: { $0.id == fetched.id }) {
                client.ownerDeviceID = now.ownerDeviceID
                client.usageDeviceID = now.usageDeviceID
            }
            return client
        }
        clientErrors = result.errors
        persistClients()
        publishMerged()
        if let snapshot {
            if let adopted = settings.addingNewProviders(from: snapshot) { updateSettings(adopted) }
            if result.didFetch { await processAlerts(snapshot).value }
        }
        lastError = result.didFetch ? nil : result.errors.values.first
        if result.didFetch { await refreshMachineInfo(missingOnly: true) }
        return lastError
    }
}
