import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Local companion install

/// Token and port from ~/.config/meterkat/config.json.
struct CompanionSettings {
    var token: String
    var port: Int

    static let path = NSHomeDirectory() + "/.config/meterkat/config.json"

    static func load() -> CompanionSettings? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else { return nil }
        return CompanionSettings(token: token, port: (json["port"] as? Int) ?? AppConstants.defaultPort)
    }
}

enum Launchd {
    static let label = "com.sahil.meterkat.companion"
    static let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    static let log = NSHomeDirectory() + "/Library/Logs/meterkat.log"

    /// The service's LaunchAgent exists (`meterkat install` has run).
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist) }

    /// Kickstarts the companion LaunchAgent, bootstrapping it first if it isn't loaded.
    static func start() -> Bool {
        let domain = "gui/\(getuid())"
        if run(["kickstart", "\(domain)/\(label)"]) { return true }
        guard FileManager.default.fileExists(atPath: plist) else { return false }
        _ = run(["bootstrap", domain, plist])
        return run(["kickstart", "\(domain)/\(label)"])
    }

    /// The LaunchAgent that opens this app at login. `meterkat install` writes the same one.
    enum LoginItem {
        static let label = "com.sahil.meterkat.menubar"
        static let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"

        static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist) }

        /// Writes or removes the agent. launchd reads it at the next login.
        static func setEnabled(_ enabled: Bool) throws {
            if enabled {
                let agent: [String: Any] = [
                    "Label": label,
                    // --background: start in the menu bar and Dock without opening the window.
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--background"],
                    "RunAtLoad": true,
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try FileManager.default.createDirectory(
                    atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: plist), options: .atomic)
            } else {
                _ = run(["bootout", "gui/\(getuid())/\(label)"])
                if isEnabled { try FileManager.default.removeItem(atPath: plist) }
            }
        }
    }

    fileprivate static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

enum QRCode {
    /// One pixel per module; scale it up with `.interpolation(.none)`.
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

// MARK: - Model

/// Polls the companion on this Mac over 127.0.0.1 with the token from its
/// config.json, so the Mac never needs pairing.
@MainActor
final class CompanionModel: ObservableObject {
    enum LinkState: Equatable {
        case connecting
        case online
        case offline
        case notInstalled
        case failed(String)
    }

    @Published private(set) var state: LinkState = .connecting
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var pairing: PairingInfo?
    @Published private(set) var pairingIssue: String?
    @Published private(set) var qrCode: NSImage?
    @Published private(set) var isRefreshing = false
    @Published private(set) var startMessage: String?
    /// Samples per window, keyed by `historyKey`; empty until graphs are
    /// wanted, or when the companion doesn't record history.
    @Published private(set) var history: [String: [UsageSample]] = [:]
    /// Rows whose graph is open in Bars mode, keyed by `historyKey`.
    @Published private(set) var expandedRows: Set<String> = []
    private var historyFetchedAt: Date?
    private var isLoadingHistory = false

    private var poller: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config)
    }()

    /// Off for the render previews, which shouldn't touch the widgets.
    private let publishesToWidgets: Bool

    /// `polling: false` fetches only on demand (used by `--render-icon`).
    init(polling: Bool = true) {
        publishesToWidgets = polling
        guard polling else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(includePairing: self.pairing == nil)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    var host: String? { pairing?.host ?? snapshot?.host }

    /// Providers in display order: Claude, OpenAI, OpenCode, OpenRouter,
    /// Copilot, Gemini, Cursor, Z.ai, Kimi, MiniMax, Alibaba, DeepSeek, then any others.
    var providers: [ProviderUsage] { ProviderUsage.sorted(snapshot?.providers ?? []) }

    /// Menu bar stacks for the providers that have limits to show and aren't hidden.
    func iconStacks(mode: BarMode, hidden: Set<String>, at date: Date = .now) -> [IconStack] {
        providers.compactMap { provider in
            let windows = provider.menuBarWindows
            guard !hidden.contains(provider.id), !windows.isEmpty else { return nil }
            let bars = windows.map { window in
                let values = window.barValues(mode: mode, at: date)
                return IconStack.Bar(fill: values.fill / 100, marker: values.marker)
            }
            return IconStack(providerID: provider.id, bars: bars)
        }
    }

    static func historyKey(provider: String, window: String) -> String { "\(provider)/\(window)" }

    func samples(provider: String, window: String) -> [UsageSample] {
        history[Self.historyKey(provider: provider, window: window)] ?? []
    }

    /// History is only fetched while a graph is on screen.
    var wantsHistory: Bool { UsageStyle.saved == .graph || !expandedRows.isEmpty }

    func toggleExpanded(_ key: String) {
        if expandedRows.remove(key) == nil { expandedRows.insert(key) }
        Task { await loadHistoryIfStale() }
    }

    /// Fetches history when a graph appears, unless the last fetch is recent.
    func loadHistoryIfStale() async {
        guard wantsHistory, state == .online, let settings = CompanionSettings.load() else { return }
        if let fetched = historyFetchedAt, Date.now.timeIntervalSince(fetched) < 30 { return }
        await loadHistory(settings)
    }

    /// `force` asks the companion for a fresh snapshot (it allows one every
    /// 15 s), e.g. after a provider is turned on.
    func refresh(includePairing: Bool = true, force: Bool = false) async {
        guard !isRefreshing else { return }
        guard let settings = CompanionSettings.load() else {
            state = .notInstalled
            snapshot = nil
            pairing = nil
            qrCode = nil
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        await loadUsage(settings, force: force)
        if wantsHistory, state == .online { await loadHistory(settings) }
        if includePairing, state == .online { await loadPairing(settings) }
    }

    func startCompanion() {
        startMessage = "Starting…"
        Task {
            let started = await Task.detached { Launchd.start() }.value
            guard started else {
                startMessage = "Couldn't start the service — run meterkat install"
                return
            }
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            startMessage = state == .online ? nil : "Started, but not responding yet — check the log"
        }
    }

    private func loadUsage(_ settings: CompanionSettings, force: Bool = false) async {
        do {
            // A cold snapshot waits on the providers (keychain + HTTP), which can take ~25 s.
            let (data, code) = try await get(force ? "/v1/usage?refresh=1" : "/v1/usage", settings, timeout: 30)
            switch code {
            case 200:
                let decoded = try JSONDecoder.usage.decode(UsageSnapshot.self, from: data)
                snapshot = decoded
                lastUpdated = .now
                if publishesToWidgets { WidgetBridge.publish(decoded, settings: settings) }
                state = .online
                startMessage = nil
            case 401:
                state = .failed("Token rejected — check config.json")
            default:
                state = .failed("Companion returned HTTP \(code)")
            }
        } catch let error as URLError where error.code == .timedOut {
            // The service is up but still waiting on a provider — don't offer Start.
            state = .failed("Companion is slow to respond")
        } catch is URLError {
            state = .offline
        } catch {
            state = .failed("Unexpected response from the companion")
        }
    }

    /// Failures keep the last history; a companion without /v1/history (404)
    /// just means no history, and the graphs fall back to averages.
    private func loadHistory(_ settings: CompanionSettings) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let (data, code) = try await get("/v1/history", settings, timeout: 10)
            switch code {
            case 200:
                let decoded = try JSONDecoder.usage.decode(UsageHistory.self, from: data)
                var byWindow: [String: [UsageSample]] = [:]
                for series in decoded.series {
                    byWindow[Self.historyKey(provider: series.provider, window: series.window)] =
                        series.samples.sorted { $0.date < $1.date }
                }
                history = byWindow
                historyFetchedAt = .now
            case 404:
                history = [:]
                historyFetchedAt = .now
            default:
                break
            }
        } catch {
            // Keep what we had; the next poll retries.
        }
    }

    private func loadPairing(_ settings: CompanionSettings) async {
        do {
            let (data, code) = try await get("/v1/pairing", settings, timeout: 4)
            switch code {
            case 200:
                let info = try JSONDecoder.usage.decode(PairingInfo.self, from: data)
                if info.link != pairing?.link { qrCode = QRCode.image(for: info.link) }
                pairing = info
                pairingIssue = nil
            case 404:
                // v1 companions don't serve /v1/pairing.
                pairing = nil
                qrCode = nil
                pairingIssue = "Update the companion (meterkat install)"
            default:
                if pairing == nil { pairingIssue = "Pairing info unavailable (HTTP \(code))" }
            }
        } catch {
            if pairing == nil { pairingIssue = "Pairing info unavailable" }
        }
    }

    private func get(_ path: String, _ settings: CompanionSettings, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)\(path)")!, timeoutInterval: timeout)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
