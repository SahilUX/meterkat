import Foundation

enum AppConstants {
    #if os(macOS)
    /// Team-prefixed: a Developer ID app can use it without a provisioning profile.
    static let appGroup = "627Y9R25T5.com.sahil.meterkat"
    static let appName = "Meterkat"
    #else
    static let appGroup = "group.com.sahil.meterkat"
    static let appName = "Meterkat"
    #endif
    static let backgroundRefreshID = "com.sahil.meterkat.refresh"
    static let urlScheme = "meterkat"
    static let defaultPort = 47300
}

/// Where the companion can be reached. The phone tries the local (LAN)
/// address first because it's fastest at home, then the remote one
/// (Tailscale or any other address reachable away from home).
struct CompanionConfig: Codable, Equatable {
    /// e.g. "http://192.168.1.20:47300"
    var localURL: String?
    /// e.g. "http://100.64.0.10:47300" or "http://my-mac.tailnet.ts.net:47300"
    var remoteURL: String?
    var token: String
    var pairingCode: String? = nil
    /// The companion machine's hostname from a pairing link, used to name a
    /// new client. Not saved, and not part of equality: it doesn't change
    /// where the companion is.
    var name: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localURL == rhs.localURL && lhs.remoteURL == rhs.remoteURL && lhs.token == rhs.token && lhs.pairingCode == rhs.pairingCode
    }

    init(localURL: String?, remoteURL: String?, token: String, pairingCode: String? = nil) {
        self.localURL = Self.normalized(localURL)
        self.remoteURL = Self.normalized(remoteURL)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pairingCode = pairingCode
    }

    /// Parses a one-time `code=` pairing link, or an older `token=` link.
    /// The older single-address form `?url=<url>&token=<token>` is sorted
    /// into local or remote by looking at the host.
    init?(pairingURL: URL) {
        guard pairingURL.scheme == AppConstants.urlScheme,
              let items = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "code" || $0.name == "token" }).count == 1,
              let credential = items.first(where: { $0.name == "code" || $0.name == "token" }),
              let credentialValue = credential.value, !credentialValue.isEmpty
        else { return nil }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        var local = value("local")
        var remote = value("remote")
        if let legacy = value("url") {
            if Self.isRemoteAddress(legacy) { remote = remote ?? legacy } else { local = local ?? legacy }
        }
        self.init(localURL: local, remoteURL: remote,
                  token: credential.name == "token" ? credentialValue : "",
                  pairingCode: credential.name == "code" ? credentialValue : nil)
        guard isComplete else { return nil }
        if let host = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty { name = host }
    }

    /// Accepts the pairing link as a string, e.g. from a QR code or the clipboard.
    init?(pairingString: String) {
        guard let url = URL(string: pairingString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(pairingURL: url)
    }

    var routes: [CompanionRoute] {
        var result: [CompanionRoute] = []
        if let localURL { result.append(CompanionRoute(kind: .local, baseURL: localURL)) }
        if let remoteURL { result.append(CompanionRoute(kind: .remote, baseURL: remoteURL)) }
        return result
    }

    var isComplete: Bool { (!token.isEmpty || pairingCode != nil) && !routes.isEmpty }

    /// Adds a scheme and strips trailing slashes; empty input becomes nil.
    static func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Tailscale (100.64.0.0/10, *.ts.net) and public hosts count as remote;
    /// private ranges, *.local and bare hostnames count as local.
    static func isRemoteAddress(_ raw: String) -> Bool {
        guard let host = URL(string: normalized(raw) ?? "")?.host?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        if host.hasSuffix(".local") || !host.contains(".") { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return true }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (127, _), (169, 254): return false
        case (172, 16...31): return false
        default: return true
        }
    }

    // Configs saved by 1.0 had a single `baseURL`.
    private enum CodingKeys: String, CodingKey { case localURL, remoteURL, token, baseURL }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let token = try c.decode(String.self, forKey: .token)
        var local = try c.decodeIfPresent(String.self, forKey: .localURL)
        var remote = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        if local == nil, remote == nil, let legacy = try c.decodeIfPresent(String.self, forKey: .baseURL) {
            if Self.isRemoteAddress(legacy) { remote = legacy } else { local = legacy }
        }
        self.init(localURL: local, remoteURL: remote, token: token)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(localURL, forKey: .localURL)
        try c.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try c.encode(token, forKey: .token)
    }
}

struct CompanionRoute: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case local
        case remote

        var label: String { self == .local ? "Local network" : "Remote" }
        var systemImage: String { self == .local ? "wifi" : "globe" }
    }

    var kind: Kind
    var baseURL: String
}

/// One installation of the companion. The first saved client is the default.
struct PairedClient: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var config: CompanionConfig
    var snapshot: UsageSnapshot?
    var history: UsageHistory?
    var lastRoute: CompanionRoute?
    /// This iPhone's owner device on the machine (iPhone app only). The owner token
    /// itself is in the Keychain, never here.
    var ownerDeviceID: String?
    /// The viewer device made for widgets and background refresh next to the owner one.
    var usageDeviceID: String?

    init(id: UUID = UUID(), name: String, config: CompanionConfig,
         snapshot: UsageSnapshot? = nil, history: UsageHistory? = nil,
         lastRoute: CompanionRoute? = nil, ownerDeviceID: String? = nil, usageDeviceID: String? = nil) {
        self.id = id
        self.name = name
        self.config = config
        self.snapshot = snapshot
        self.history = history
        self.lastRoute = lastRoute
        self.ownerDeviceID = ownerDeviceID
        self.usageDeviceID = usageDeviceID
    }

    /// The name used when a client is added without one.
    static let defaultName = "Default companion"

    /// True for a name the app made up ("Default companion", "Client 2"),
    /// which the companion's hostname may replace. A name the user typed is kept.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultName { return true }
        guard trimmed.hasPrefix("Client ") else { return false }
        let number = trimmed.dropFirst("Client ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    /// Replaces a placeholder name with `host`, if there is one.
    mutating func adoptHostName(_ host: String?) {
        guard Self.isPlaceholderName(name),
              let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty
        else { return }
        name = host
    }
}

enum ClientMerge {
    static func refresh(_ clients: [PairedClient], timeout: TimeInterval = 12) async -> (clients: [PairedClient], errors: [UUID: String], didFetch: Bool) {
        var refreshed = clients
        var errors: [UUID: String] = [:]
        var didFetch = false
        await withTaskGroup(of: (UUID, Result<PairedClient, Error>).self) { group in
            for client in clients {
                group.addTask {
                    do { return (client.id, .success(try await CompanionClient.fetchClient(client, timeout: timeout))) }
                    catch { return (client.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard let index = refreshed.firstIndex(where: { $0.id == id }) else { continue }
                switch result {
                case .success(var client):
                    client.adoptHostName(client.snapshot?.host)
                    refreshed[index] = client
                    didFetch = true
                case .failure(let error): errors[id] = error.localizedDescription
                }
            }
        }
        return (refreshed, errors, didFetch)
    }

    /// Default client wins ties. An online result replaces a failed result
    /// for the same account; different known accounts remain separate.
    static func snapshot(_ clients: [PairedClient], unavailable: Set<UUID> = []) -> UsageSnapshot? {
        let snapshots = clients.compactMap(\.snapshot)
        guard !snapshots.isEmpty else { return nil }
        var providers: [ProviderUsage] = []
        var indexes: [String: Int] = [:]
        var costs: [String: APICost] = [:]
        var breakdowns: [String: UsageBreakdown] = [:]
        // A machine whose provider errored may not report the account. If
        // every other machine agrees on one account, it's the same login.
        var accounts: [String: Set<String>] = [:]
        for usage in snapshots.flatMap(\.providers) {
            if let account = usage.account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
                accounts[usage.id, default: []].insert(account.lowercased())
            }
        }
        for client in clients {
            guard let snapshot = client.snapshot else { continue }
            for var usage in snapshot.providers {
                usage.sourceClientID = client.id
                usage.sourceClientName = client.name
                usage.sourceIsStale = unavailable.contains(client.id)
                if usage.identityKey.hasSuffix("|unknown"), usage.status != "not_signed_in",
                   let known = accounts[usage.id], known.count == 1 {
                    usage.account = known.first
                }
                let key = usage.identityKey
                if var cost = usage.apiCost {
                    cost.machines = 1
                    costs[key] = costs[key].map { $0.adding(cost) } ?? cost
                }
                // The split is account-wide, so any computer's will do; keep the newest.
                if let split = usage.breakdown, (split.asOf ?? .distantPast) > (breakdowns[key]?.asOf ?? .distantPast) {
                    breakdowns[key] = split
                }
                if let index = indexes[key] {
                    let current = providers[index]
                    let currentOnline = current.sourceClientID.map { !unavailable.contains($0) } ?? false
                    let currentScore = (current.isOK ? 4 : 0) + (current.stale == true ? 0 : 2) + (currentOnline ? 1 : 0)
                    let newScore = (usage.isOK ? 4 : 0) + (usage.stale == true ? 0 : 2) + (unavailable.contains(client.id) ? 0 : 1)
                    if newScore > currentScore { providers[index] = usage }
                } else {
                    indexes[key] = providers.count
                    providers.append(usage)
                }
            }
        }
        // A signed-in account makes a not-signed-in report from another
        // machine irrelevant for that provider.
        let signedIn = Set(providers.filter { $0.status != "not_signed_in" }.map(\.id))
        providers.removeAll { $0.status == "not_signed_in" && signedIn.contains($0.id) }
        for index in providers.indices {
            let key = providers[index].identityKey
            providers[index].apiCost = costs[key]
            providers[index].breakdown = breakdowns[key] ?? providers[index].breakdown
        }
        return UsageSnapshot(generatedAt: snapshots.map(\.generatedAt).max() ?? .now,
                             host: clients.first?.snapshot?.host,
                             companionVersion: clients.first?.snapshot?.companionVersion,
                             providers: providers)
    }

    static func history(_ clients: [PairedClient], snapshot: UsageSnapshot?) -> UsageHistory? {
        guard let snapshot else { return nil }
        var series: [UsageSeries] = []
        for provider in snapshot.providers {
            guard let client = clients.first(where: { $0.id == provider.sourceClientID }),
                  let history = client.history else { continue }
            for item in history.series where item.provider == provider.id {
                var chosen = item
                chosen.provider = provider.identityKey
                series.append(chosen)
            }
        }
        return UsageHistory(generatedAt: snapshot.generatedAt, series: series)
    }
}

/// Per-provider preferences. Decoding tolerates missing keys so fields can
/// be added without wiping saved settings.
struct ProviderSettings: Codable, Equatable {
    /// Off hides the provider everywhere (dashboard, widgets, alerts).
    var enabled = true
    var limitAlerts = true
    /// Alert once per window cycle when usage reaches this percent.
    var limitThreshold: Double = 80
    /// Window ids (`WindowSlot.windowID`) whose resets are announced.
    var resetAlertWindows: Set<String> = [WindowSlot.fiveHour.windowID]

    static let thresholdRange: ClosedRange<Double> = 50...100
    static let thresholdStep: Double = 5
    /// Only announce a reset if the window had at least this much usage.
    static let resetMinimumPercent: Double = 1

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProviderSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        limitAlerts = try c.decodeIfPresent(Bool.self, forKey: .limitAlerts) ?? defaults.limitAlerts
        limitThreshold = try c.decodeIfPresent(Double.self, forKey: .limitThreshold) ?? defaults.limitThreshold
        resetAlertWindows = try c.decodeIfPresent(Set<String>.self, forKey: .resetAlertWindows) ?? defaults.resetAlertWindows
    }

    func announcesReset(of windowID: String) -> Bool {
        resetAlertWindows.contains(windowID)
    }
}

enum UsageStyle: String, Codable, CaseIterable, Identifiable {
    /// Progress bar with a marker for how much of the window has elapsed.
    case bars
    /// Chart of usage so far against an even pace, with a projection.
    case graph

    var id: String { rawValue }
    var label: String { self == .bars ? "Bars" : "Graph" }
}

/// Whether bars and percentages show what's been used or what's left.
enum BarMode: String, Codable, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }
    var label: String { self == .used ? "Used" : "Remaining" }

    /// "32% used" / "68% left".
    func percentText(used: Double) -> String {
        switch self {
        case .used: return "\(UsageFormat.percent(used)) used"
        case .remaining: return "\(UsageFormat.percent(100 - used)) left"
        }
    }

    /// The number alone, for tight spaces: 32 or 68.
    func value(used: Double) -> Double {
        self == .used ? used : 100 - used
    }
}

struct UsageSettings: Codable, Equatable {
    var providers: [String: ProviderSettings] = [:]
    var usageStyle: UsageStyle = .bars
    var barMode: BarMode = .used

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([String: ProviderSettings].self, forKey: .providers) ?? [:]
        usageStyle = try c.decodeIfPresent(UsageStyle.self, forKey: .usageStyle) ?? .bars
        barMode = try c.decodeIfPresent(BarMode.self, forKey: .barMode) ?? .used
    }

    subscript(provider: ProviderID) -> ProviderSettings {
        get { providers[provider.rawValue] ?? ProviderSettings() }
        set { providers[provider.rawValue] = newValue }
    }

    /// Unknown provider ids (from a newer companion) count as enabled.
    func isEnabled(_ providerID: String) -> Bool {
        providers[providerID]?.enabled ?? true
    }

    var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { isEnabled($0.rawValue) }
    }

    /// Settings saved before a provider existed (OpenRouter, added in v4)
    /// have no entry for it, which would count as on. This turns such a
    /// provider on only if the companion reports usage for it, so an update
    /// doesn't add a "not signed in" provider everywhere. Nil when nothing
    /// changes, including before any provider setting was saved: onboarding
    /// presets those.
    func addingNewProviders(from snapshot: UsageSnapshot) -> UsageSettings? {
        guard !providers.isEmpty else { return nil }
        var settings = self
        for provider in ProviderID.allCases where providers[provider.rawValue] == nil {
            guard let usage = snapshot.provider(provider) else { continue }
            settings[provider].enabled = usage.isOK
        }
        return settings == self ? nil : settings
    }
}

/// Settings saved by 1.x, read once to seed `UsageSettings`.
private struct LegacyNotificationSettings: Decodable {
    var resetAlerts: Bool?
    var thresholdAlerts: Bool?
    var thresholds: [Double]?
}

/// App Group backed storage shared by the app and the widget extension.
enum SharedStore {
    private static let configKey = "companionConfig"
    private static let clientsKey = "pairedClients"
    private static let snapshotKey = "lastSnapshot"
    private static let legacyNotificationSettingsKey = "notificationSettings"
    private static let usageSettingsKey = "usageSettings"
    private static let historyKey = "lastHistory"
    private static let firedThresholdsKey = "firedThresholds"
    private static let lastRouteKey = "lastRoute"
    private static let onboardingKey = "hasCompletedOnboarding"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConstants.appGroup) ?? .standard
    }

    static var config: CompanionConfig? {
        get { decode(CompanionConfig.self, key: configKey) }
        set { encode(newValue, key: configKey) }
    }

    static var clients: [PairedClient] {
        get {
            if let saved = decode([PairedClient].self, key: clientsKey) { return saved }
            guard let config else { return [] }
            let migrated = [PairedClient(name: lastSnapshot?.host ?? PairedClient.defaultName,
                                         config: config, snapshot: lastSnapshot,
                                         history: lastHistory, lastRoute: lastRoute)]
            encode(migrated, key: clientsKey)
            return migrated
        }
        set {
            encode(newValue, key: clientsKey)
            // Keep the original key for old app builds and onboarding.
            config = newValue.first?.config
        }
    }

    static var lastSnapshot: UsageSnapshot? {
        get { decode(UsageSnapshot.self, key: snapshotKey) }
        set { encode(newValue, key: snapshotKey) }
    }

    static var usageSettings: UsageSettings {
        get {
            if let settings = decode(UsageSettings.self, key: usageSettingsKey) { return settings }
            // Saved right away: the migration looks at the cached snapshot,
            // which the next fetch replaces.
            let settings = migratedSettings()
            encode(settings, key: usageSettingsKey)
            return settings
        }
        set { encode(newValue, key: usageSettingsKey) }
    }

    /// Carries over 1.x alert preferences. Providers an older companion never
    /// reported (OpenCode) start off, so upgrading doesn't add a "not signed
    /// in" provider everywhere; they can be turned on in Settings.
    private static func migratedSettings() -> UsageSettings {
        var settings = UsageSettings()
        let legacy = decode(LegacyNotificationSettings.self, key: legacyNotificationSettingsKey)
        let snapshot = lastSnapshot
        guard legacy != nil || snapshot != nil else { return settings }
        for provider in ProviderID.allCases {
            var p = ProviderSettings()
            if let legacy {
                p.limitAlerts = legacy.thresholdAlerts ?? p.limitAlerts
                p.limitThreshold = legacy.thresholds?.min() ?? p.limitThreshold
                p.resetAlertWindows = legacy.resetAlerts == false ? [] : [WindowSlot.fiveHour.windowID, WindowSlot.weekly.windowID]
            }
            if let snapshot {
                p.enabled = snapshot.provider(provider) != nil
            }
            settings[provider] = p
        }
        return settings
    }

    /// The route the last successful fetch used; tried first next time.
    static var lastRoute: CompanionRoute? {
        get { decode(CompanionRoute.self, key: lastRouteKey) }
        set { encode(newValue, key: lastRouteKey) }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: onboardingKey) }
        set { defaults.set(newValue, forKey: onboardingKey) }
    }

    static var lastHistory: UsageHistory? {
        get { decode(UsageHistory.self, key: historyKey) }
        set { encode(newValue, key: historyKey) }
    }

    /// Keys of limit alerts already delivered, e.g. "claude|five_hour|<resetEpoch>|80".
    static var firedThresholds: Set<String> {
        get { Set(defaults.stringArray(forKey: firedThresholdsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: firedThresholdsKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder.usage.decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T?, key: String) {
        guard let value, let data = try? JSONEncoder.usage.encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
