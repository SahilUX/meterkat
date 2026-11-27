import Foundation

enum CompanionError: LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case http(Int)
    case decoding(String)
    case unreachable([String])

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Companion not paired yet."
        case .badURL: return "Companion URL is invalid."
        case .unauthorized: return "Companion rejected the pairing token."
        case .http(let code): return "Companion returned HTTP \(code)."
        case .decoding(let detail): return "Unexpected response: \(detail)"
        case .unreachable(let failures): return "Couldn't reach the companion. " + failures.joined(separator: " ")
        }
    }
}

enum CompanionClient {
    /// A LAN address that isn't reachable (away from home) usually hangs
    /// rather than failing fast, so it gets a short leash.
    static let localTimeout: TimeInterval = 3

    /// Exchanges a one-use pairing code for the companion's saved bearer token.
    static func redeemPairingCode(_ code: String, routes: [CompanionRoute]) async throws -> String {
        for route in routes {
            guard let url = URL(string: route.baseURL + "/v1/pair") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401 { throw CompanionError.unauthorized }
                    throw CompanionError.http(http.statusCode)
                }
                return try JSONDecoder.usage.decode(PairingToken.self, from: data).token
            } catch let error as CompanionError {
                throw error
            } catch {
                continue
            }
        }
        throw CompanionError.unreachable(["Could not redeem the pairing code. Check the address and try again."])
    }

    private struct PairingToken: Decodable { var token: String }

    /// Fetch one client without changing the shared widget cache. Routes are
    /// fallback addresses for this client, never another client's address.
    static func fetchClient(_ client: PairedClient, timeout: TimeInterval = 12) async throws -> PairedClient {
        var updated = client
        let (snapshot, route): (UsageSnapshot, CompanionRoute) = try await requestClient(
            "/v1/usage", config: client.config, preferredRoute: client.lastRoute, timeout: timeout)
        updated.snapshot = snapshot
        updated.lastRoute = route
        let historyResult: (UsageHistory, CompanionRoute)? = try? await requestClient(
            "/v1/history", config: client.config, preferredRoute: route, timeout: timeout)
        if let historyResult { updated.history = historyResult.0 }
        return updated
    }

    private static func requestClient<T: Decodable>(
        _ path: String, config: CompanionConfig, preferredRoute: CompanionRoute?, timeout: TimeInterval
    ) async throws -> (T, CompanionRoute) {
        guard config.isComplete else { throw CompanionError.notConfigured }
        var routes = config.routes
        if let preferredRoute, let index = routes.firstIndex(of: preferredRoute) {
            routes.insert(routes.remove(at: index), at: 0)
        }
        var failures: [String] = []
        for (index, route) in routes.enumerated() {
            let limit = route.kind == .local && index < routes.count - 1 ? min(localTimeout, timeout) : timeout
            do {
                let value: T = try await get(path, as: T.self, route: route, token: config.token, timeout: limit)
                return (value, route)
            } catch let error as CompanionError {
                switch error {
                case .unauthorized, .http: throw error
                default: failures.append("\(route.kind.label): \(error.localizedDescription)")
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                failures.append("\(route.kind.label): \(error.localizedDescription)")
            }
        }
        throw CompanionError.unreachable(failures)
    }

    /// Fetches the latest usage, trying the last route that worked first,
    /// then the rest (local before remote). Caches the snapshot and the
    /// winning route in the App Group.
    static func fetch(config: CompanionConfig? = SharedStore.config, timeout: TimeInterval = 12) async throws -> UsageSnapshot {
        let snapshot: UsageSnapshot = try await request("/v1/usage", as: UsageSnapshot.self, config: config, timeout: timeout)
        SharedStore.lastSnapshot = snapshot
        return snapshot
    }

    /// Fetches the recorded usage samples for each window's current cycle
    /// and caches them in the App Group. Companions older than 1.2 answer 404.
    static func fetchHistory(config: CompanionConfig? = SharedStore.config, timeout: TimeInterval = 12) async throws -> UsageHistory {
        let history: UsageHistory = try await request("/v1/history", as: UsageHistory.self, config: config, timeout: timeout)
        SharedStore.lastHistory = history
        return history
    }

    private static func request<T: Decodable>(_ path: String, as type: T.Type, config: CompanionConfig?, timeout: TimeInterval) async throws -> T {
        guard let config, config.isComplete else { throw CompanionError.notConfigured }

        var routes = config.routes
        if let last = SharedStore.lastRoute, let index = routes.firstIndex(of: last) {
            routes.insert(routes.remove(at: index), at: 0)
        }

        var failures: [String] = []
        for (index, route) in routes.enumerated() {
            let isLast = index == routes.count - 1
            let limit = route.kind == .local && !isLast ? min(localTimeout, timeout) : timeout
            do {
                let value = try await get(path, as: T.self, route: route, token: config.token, timeout: limit)
                SharedStore.lastRoute = route
                return value
            } catch let error as CompanionError {
                // The companion answered, and every route reaches the same one
                // with the same token, so a rejection or error status (e.g. 404
                // from a companion without /v1/history) won't go differently elsewhere.
                switch error {
                case .unauthorized, .http: throw error
                default: failures.append("\(route.kind.label): \(error.localizedDescription)")
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                failures.append("\(route.kind.label): \(error.localizedDescription)")
            }
        }
        throw CompanionError.unreachable(failures)
    }

    /// Tests a single route without touching the cache. Used by onboarding
    /// and Settings to show per-route status.
    static func probe(route: CompanionRoute, token: String, timeout: TimeInterval = 6) async -> Result<UsageSnapshot, Error> {
        do {
            return .success(try await get("/v1/usage", as: UsageSnapshot.self, route: route, token: token, timeout: timeout))
        } catch {
            return .failure(error)
        }
    }

    private static func get<T: Decodable>(_ path: String, as type: T.Type, route: CompanionRoute, token: String, timeout: TimeInterval) async throws -> T {
        guard let url = URL(string: route.baseURL + path) else { throw CompanionError.badURL }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw CompanionError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw CompanionError.http(http.statusCode) }
        }
        do {
            return try JSONDecoder.usage.decode(T.self, from: data)
        } catch {
            throw CompanionError.decoding(String(describing: error))
        }
    }
}
