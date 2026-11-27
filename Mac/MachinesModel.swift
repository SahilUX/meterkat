import AppKit
import CoreImage
import Security

// MARK: - Wire types (companion 2.5.0+)

/// One paired device, from GET /v1/devices.
struct DeviceEntry: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var role: String
    var createdAt: Date?
    var lastUsedAt: Date?
    var hint: String?
    /// The caller's own device ("this device").
    var current: Bool

    var isOwner: Bool { role == "owner" }
}

/// The older shared token's row: shown, never revocable here.
struct SharedTokenEntry: Decodable, Equatable {
    var label: String
    var lastUsedAt: Date?
    var current: Bool
}

struct DeviceList: Decodable, Equatable {
    struct You: Decodable, Equatable {
        var role: String
        var deviceId: String?
    }

    var host: String?
    var companionVersion: String?
    var devices: [DeviceEntry]
    var sharedToken: SharedTokenEntry?
    var you: You?
}

/// GET /v1/me.
struct MachineMe: Decodable, Equatable {
    var role: String
    var kind: String?
    var deviceId: String?
    var name: String?
    var host: String?
    var companionVersion: String?
    var platform: String?
    var headless: Bool?

    /// "Linux, headless", "macOS".
    var systemLabel: String? {
        guard let platform else { return nil }
        let os = platform == "macos" ? "macOS" : platform == "linux" ? "Linux" : platform.capitalized
        return headless == true ? "\(os), headless" : os
    }
}

private struct PairResponse: Decodable {
    var token: String
    var deviceId: String?
    var role: String?
}

private struct ErrorBody: Decodable {
    var error: String?
    var message: String?
}

enum MachineError: LocalizedError, Equatable {
    case unreachable
    case unauthorized
    case forbidden
    case notOwner
    case pairingFailed
    case lastOwner(String)
    case notFound
    case invalidLink
    case http(Int, String?)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Couldn't reach the machine. Check the address and that its companion is running."
        case .unauthorized: return "This Mac's access was revoked or isn't accepted. Add the machine again with a new owner link."
        case .forbidden: return "This device can't manage devices on that machine."
        case .notOwner: return "That is a viewer link. Run `meterkat pair --owner` on the machine to make an owner link."
        case .pairingFailed: return "The link has expired or was already used. Run `meterkat pair --owner` again."
        case .lastOwner(let message): return message
        case .notFound: return "That device is already gone."
        case .invalidLink: return "That isn't a Meterkat pairing link. It starts with meterkat://pair."
        case .http(let code, let message): return message ?? "The companion answered HTTP \(code)."
        case .decoding: return "The companion's answer wasn't what this version expects. Update the companion."
        }
    }
}

// MARK: - API

/// Where a machine's companion is and the token to use there.
struct MachineEndpoint: Equatable {
    var routes: [CompanionRoute]
    var token: String
}

enum MachineAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let decoder = JSONDecoder.usage

    /// Tries each address in turn: a LAN address that isn't reachable (away from home)
    /// hangs, so it gets a short leash when another address is left to try.
    private static func send(
        _ method: String, _ path: String, to endpoint: MachineEndpoint, body: Data? = nil, token: String? = nil
    ) async throws -> (Data, Int) {
        var lastError: Error = MachineError.unreachable
        for (index, route) in endpoint.routes.enumerated() {
            guard let url = URL(string: route.baseURL + path) else { continue }
            let last = index == endpoint.routes.count - 1
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: route.kind == .local && !last ? 3 : 12)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token = token ?? (endpoint.token.isEmpty ? nil : endpoint.token) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            do {
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
        }
        _ = lastError
        throw MachineError.unreachable
    }

    private static func fail(_ code: Int, _ data: Data) -> MachineError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch code {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409 where body?.error == "last_owner": return .lastOwner(body?.message ?? "This is the last owner device.")
        default: return .http(code, body?.message)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw MachineError.decoding }
    }

    static func me(_ endpoint: MachineEndpoint) async throws -> MachineMe {
        let (data, code) = try await send("GET", "/v1/me", to: endpoint)
        guard code == 200 else { throw fail(code, data) }
        return try decode(MachineMe.self, data)
    }

    static func devices(_ endpoint: MachineEndpoint) async throws -> DeviceList {
        let (data, code) = try await send("GET", "/v1/devices", to: endpoint)
        guard code == 200 else { throw fail(code, data) }
        return try decode(DeviceList.self, data)
    }

    static func usage(_ endpoint: MachineEndpoint) async throws -> UsageSnapshot {
        let (data, code) = try await send("GET", "/v1/usage", to: endpoint)
        guard code == 200 else { throw fail(code, data) }
        return try decode(UsageSnapshot.self, data)
    }

    static func revoke(_ deviceID: String, on endpoint: MachineEndpoint) async throws {
        let escaped = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        let (data, code) = try await send("DELETE", "/v1/devices/\(escaped)", to: endpoint)
        guard code == 200 else { throw fail(code, data) }
    }

    /// Trades an owner pairing code for this Mac's own token on that machine.
    static func redeem(code: String, name: String, routes: [CompanionRoute]) async throws -> (token: String, deviceID: String?, role: String) {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        let (data, status) = try await send("POST", "/v1/pair", to: MachineEndpoint(routes: routes, token: ""), body: body)
        switch status {
        case 200:
            let pair = try decode(PairResponse.self, data)
            // An older companion hands back its shared token, which has no role.
            return (pair.token, pair.deviceId, pair.role ?? "shared")
        case 400, 401: throw MachineError.pairingFailed
        default: throw fail(status, data)
        }
    }
}

// MARK: - Keychain

/// Tokens of remote machines live in the login keychain, never in preferences.
enum MachineKeychain {
    private static let service = "com.sahil.meterkat.machines"

    static func token(for id: UUID) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ token: String, for id: UUID) -> Bool {
        delete(id)
        var query = base(id)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ id: UUID) {
        SecItemDelete(base(id) as CFDictionary)
    }

    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

// MARK: - Model

/// "This Mac" (the local companion, over 127.0.0.1 with the token from its config.json)
/// and the remote machines added with an owner pairing link. Each companion is the
/// authority for its own devices; nothing is shared between machines.
@MainActor
final class MachinesModel: ObservableObject {
    static let localID = "local"
    private static let defaultsKey = "remoteMachines"

    struct Machine: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var localURL: String?
        var remoteURL: String?
        /// This Mac's own device id on that machine.
        var deviceID: String?
        var addedAt: Date

        var routes: [CompanionRoute] {
            var routes: [CompanionRoute] = []
            if let localURL { routes.append(CompanionRoute(kind: .local, baseURL: localURL)) }
            if let remoteURL { routes.append(CompanionRoute(kind: .remote, baseURL: remoteURL)) }
            return routes
        }
    }

    enum Link: Equatable {
        case checking
        case online
        case offline
        case rejected
        case failed(String)
    }

    struct Status: Equatable {
        var link: Link = .checking
        var me: MachineMe?
        var devices: DeviceList?
        var providers: [ProviderUsage] = []
        var version: String?
        var host: String?
        var checkedAt: Date?
        /// Why the device list couldn't be loaded, when the machine itself is up.
        var devicesIssue: String?
    }

    @Published private(set) var machines: [Machine] = []
    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var isAdding = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder.usage.decode([Machine].self, from: data) {
            machines = saved
        }
    }

    // MARK: Endpoints

    func endpoint(for id: String) -> MachineEndpoint? {
        if id == Self.localID {
            guard let settings = CompanionSettings.load() else { return nil }
            return MachineEndpoint(
                routes: [CompanionRoute(kind: .local, baseURL: "http://127.0.0.1:\(settings.port)")],
                token: settings.token)
        }
        guard let uuid = UUID(uuidString: id), let machine = machines.first(where: { $0.id == uuid }),
              let token = MachineKeychain.token(for: uuid) else { return nil }
        return MachineEndpoint(routes: machine.routes, token: token)
    }

    func name(for id: String) -> String {
        if id == Self.localID { return "This Mac" }
        return UUID(uuidString: id).flatMap { uuid in machines.first { $0.id == uuid }?.name } ?? "Machine"
    }

    func status(for id: String) -> Status { statuses[id] ?? Status() }

    // MARK: Loading

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refresh(Self.localID) }
            for machine in machines {
                group.addTask { await self.refresh(machine.id.uuidString) }
            }
        }
    }

    func refresh(_ id: String) async {
        guard let endpoint = endpoint(for: id) else {
            statuses[id] = Status(link: id == Self.localID ? .offline : .rejected, checkedAt: .now)
            return
        }
        var status = statuses[id] ?? Status()
        if status.checkedAt == nil { status.link = .checking }
        do {
            let snapshot = try await MachineAPI.usage(endpoint)
            status.providers = ProviderUsage.sorted(snapshot.providers)
            status.version = snapshot.companionVersion
            status.host = snapshot.host
            status.link = .online
        } catch MachineError.unauthorized {
            status.link = .rejected
        } catch MachineError.unreachable {
            status.link = .offline
        } catch {
            status.link = .failed(error.localizedDescription)
        }
        if status.link == .online {
            status.me = try? await MachineAPI.me(endpoint)
            do {
                status.devices = try await MachineAPI.devices(endpoint)
                status.devicesIssue = nil
            } catch MachineError.notFound {
                status.devices = nil
                status.devicesIssue = "This companion is older than 2.5.0. Update it (meterkat update) to list devices."
            } catch {
                status.devices = nil
                status.devicesIssue = error.localizedDescription
            }
        }
        status.checkedAt = .now
        statuses[id] = status
    }

    // MARK: Adding and removing

    /// Adds a machine from an owner pairing link (pasted text, or a QR code's contents).
    func add(link text: String) async throws {
        isAdding = true
        defer { isAdding = false }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let config = CompanionConfig(pairingURL: url), let code = config.pairingCode
        else { throw MachineError.invalidLink }
        let routes = config.routes
        let result = try await MachineAPI.redeem(code: code, name: Self.thisMacName, routes: routes)
        // Only an owner token can manage devices; a viewer link would add a machine that can't.
        guard result.role == "owner" else {
            // The code is used up either way. Revoke what was just made, so the machine doesn't keep a stray device.
            if let id = result.deviceID {
                try? await MachineAPI.revoke(id, on: MachineEndpoint(routes: routes, token: result.token))
            }
            throw MachineError.notOwner
        }
        let machine = Machine(
            id: UUID(), name: config.name ?? URL(string: routes.first?.baseURL ?? "")?.host ?? "Machine",
            localURL: config.localURL, remoteURL: config.remoteURL, deviceID: result.deviceID, addedAt: .now)
        guard MachineKeychain.set(result.token, for: machine.id) else {
            throw MachineError.http(0, "Couldn't save the token in the keychain.")
        }
        machines.append(machine)
        save()
        await refresh(machine.id.uuidString)
        if let host = statuses[machine.id.uuidString]?.host ?? statuses[machine.id.uuidString]?.me?.host,
           let index = machines.firstIndex(of: machine), machines[index].name != host {
            machines[index].name = host
            save()
        }
    }

    /// Forgets a machine on this Mac. Its device list there still holds this Mac's device until it's revoked.
    func remove(_ machine: Machine) {
        MachineKeychain.delete(machine.id)
        machines.removeAll { $0.id == machine.id }
        statuses[machine.id.uuidString] = nil
        save()
    }

    func revoke(_ device: DeviceEntry, on id: String) async throws {
        guard let endpoint = endpoint(for: id) else { throw MachineError.unauthorized }
        try await MachineAPI.revoke(device.id, on: endpoint)
        await refresh(id)
    }

    private func save() {
        if let data = try? JSONEncoder.usage.encode(machines) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// What this Mac is called in a machine's device list.
    static var thisMacName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

// MARK: - QR images

enum QRImageReader {
    /// The text of the first QR code in an image file, if there is one.
    static func text(in url: URL) -> String? {
        guard let image = CIImage(contentsOf: url),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
