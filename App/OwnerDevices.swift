import Foundation
import LocalAuthentication
import Security
import UIKit

// MARK: - Wire types (companion 2.5.0+)
//
// The Mac app has its own copies in Mac/MachinesModel.swift. The Mac target and
// this one don't share them yet, so keep the two in step.

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
    var host: String?
    var companionVersion: String?
    var devices: [DeviceEntry]
    var sharedToken: SharedTokenEntry?
}

/// GET /v1/me.
struct MachineMe: Decodable, Equatable {
    var role: String
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

// MARK: - Errors

enum OwnerError: LocalizedError, Equatable {
    case unreachable
    case unauthorized
    case forbidden
    case nameRequired
    case pairingFailed
    case notOwnerLink
    case lastOwner(String)
    case notFound
    case tooManyAttempts(Int?)
    case http(Int, String?)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach the machine. Check the address and that its companion is running."
        case .unauthorized:
            return "The machine no longer accepts this iPhone. Pair it again."
        case .forbidden:
            return "This iPhone doesn't have owner access to that machine."
        case .nameRequired:
            return "This owner link needs a newer Meterkat app."
        case .pairingFailed:
            return "The pairing code has expired or was already used. Show a fresh one and try again."
        case .notOwnerLink:
            return "That is a viewer link. Run `meterkat pair --owner` on the machine to make an owner link."
        case .lastOwner(let message):
            return "\(message) Use `meterkat devices revoke` on the machine itself."
        case .notFound:
            return "That device is already gone."
        case .tooManyAttempts(let seconds):
            let wait = seconds.map { " Try again in \(max(1, ($0 + 59) / 60)) min." } ?? ""
            return "The machine is blocking this address after too many failed attempts." + wait
        case .http(let code, let message):
            return message ?? "The companion answered HTTP \(code)."
        case .decoding:
            return "The companion's answer wasn't what this version expects. Update the companion."
        }
    }
}

// MARK: - API

enum OwnerAPI {
    struct PairReply: Decodable {
        var token: String
        var deviceId: String?
        var role: String?
    }

    private struct ErrorBody: Decodable {
        var error: String?
        var message: String?
    }

    private struct PairingCodePayload: Decodable { var link: String }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Tries each address in turn. A LAN address that isn't reachable (away from home)
    /// hangs, so it gets a short leash while another address is left to try.
    private static func send(
        _ method: String, _ path: String, routes: [CompanionRoute], token: String?, body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        for (index, route) in routes.enumerated() {
            guard let url = URL(string: route.baseURL + path) else { continue }
            let last = index == routes.count - 1
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: route.kind == .local && !last ? 3 : 12)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse { return (data, http) }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        throw OwnerError.unreachable
    }

    private static func failure(_ http: HTTPURLResponse, _ data: Data) -> OwnerError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch http.statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409 where body?.error == "last_owner": return .lastOwner(body?.message ?? "This is the last owner device.")
        case 429: return .tooManyAttempts(http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: return .http(http.statusCode, body?.message)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder.usage.decode(T.self, from: data) } catch { throw OwnerError.decoding }
    }

    static func me(routes: [CompanionRoute], token: String) async throws -> MachineMe {
        let (data, http) = try await send("GET", "/v1/me", routes: routes, token: token)
        guard http.statusCode == 200 else { throw failure(http, data) }
        return try decode(MachineMe.self, data)
    }

    static func devices(routes: [CompanionRoute], token: String) async throws -> DeviceList {
        let (data, http) = try await send("GET", "/v1/devices", routes: routes, token: token)
        guard http.statusCode == 200 else { throw failure(http, data) }
        return try decode(DeviceList.self, data)
    }

    static func revoke(_ deviceID: String, routes: [CompanionRoute], token: String) async throws {
        let escaped = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        let (data, http) = try await send("DELETE", "/v1/devices/\(escaped)", routes: routes, token: token)
        guard http.statusCode == 200 else { throw failure(http, data) }
    }

    /// Redeems a pairing code. Without a name, an older or viewer code returns the shared token,
    /// and an owner code answers 400 `name_required` (the code is not used up).
    static func pair(code: String, name: String?, routes: [CompanionRoute]) async throws -> PairReply {
        var payload: [String: String] = ["code": code]
        if let name { payload["name"] = name }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await send("POST", "/v1/pair", routes: routes, token: nil, body: body)
        switch http.statusCode {
        case 200: return try decode(PairReply.self, data)
        case 400:
            let reply = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw reply?.error == "name_required" ? OwnerError.nameRequired : OwnerError.pairingFailed
        case 401: throw OwnerError.pairingFailed
        default: throw failure(http, data)
        }
    }

    /// An owner asks for a viewer pairing code; returns the code from the link.
    static func viewerPairingCode(routes: [CompanionRoute], ownerToken: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["role": "viewer"])
        let (data, http) = try await send("POST", "/v1/devices/pairing-codes", routes: routes, token: ownerToken, body: body)
        guard http.statusCode == 200 else { throw failure(http, data) }
        let payload = try decode(PairingCodePayload.self, data)
        guard let code = CompanionConfig(pairingString: payload.link)?.pairingCode else { throw OwnerError.decoding }
        return code
    }
}

// MARK: - Owner access

/// What an owner pairing gave this iPhone on one machine.
struct OwnerGrant: Equatable {
    var token: String
    var deviceID: String
    /// The viewer device made for widgets and background refresh, which can't reach the Keychain item.
    var usageDeviceID: String?
}

/// Owner tokens live in the Keychain, on this iPhone only, and never in the App Group
/// preferences that widgets and the Watch can read.
enum OwnerKeychain {
    private static let service = "com.sahil.meterkat.owner"

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
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ id: UUID) {
        SecItemDelete(base(id) as CFDictionary)
    }

    /// Whether the Keychain takes a write. Checked before an owner code is redeemed, so a failure
    /// can't leave an owner device on the machine that this iPhone then can't use.
    static func isWritable() -> Bool {
        let probe = UUID()
        defer { delete(probe) }
        return set("probe", for: probe) && token(for: probe) == "probe"
    }

    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

// MARK: - Biometrics

enum BiometricGate {
    #if DEBUG
    /// Screenshots and simulator runs without an enrolled face.
    static let skipped = UserDefaults.standard.bool(forKey: "MeterkatSkipBiometrics")
    #endif

    /// Face ID or Touch ID, with the device passcode as the fallback. Throws if the user
    /// cancels or the phone has no passcode.
    static func confirm(reason: String) async throws {
        #if DEBUG
        if skipped { return }
        #endif
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            throw BiometricError.unavailable
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw BiometricError.denied
            }
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel || error.code == .appCancel {
            throw BiometricError.cancelled
        } catch {
            throw BiometricError.denied
        }
    }

    enum BiometricError: LocalizedError {
        case unavailable
        case denied
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Set a passcode on this iPhone, then try again. Revoking needs Face ID, Touch ID or the passcode."
            case .denied: return "Couldn't confirm it's you. The device was not revoked."
            case .cancelled: return nil
            }
        }
    }
}

// MARK: - Times

enum DeviceTime {
    /// "just now", "3 minutes ago", "yesterday".
    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The exact local time, for a tap.
    static func exact(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Devices screen model

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var list: DeviceList?
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// Set when the machine stopped accepting our owner token.
    @Published private(set) var lostAccess = false

    func load(routes: [CompanionRoute], token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            list = try await OwnerAPI.devices(routes: routes, token: token)
            error = nil
            lostAccess = false
        } catch OwnerError.unauthorized {
            lostAccess = true
            error = OwnerError.unauthorized.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
