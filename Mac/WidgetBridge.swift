import Foundation
import WidgetKit

/// Shares this Mac's companion with the widget extension through the App
/// Group: a single client on 127.0.0.1 with the token from config.json (the
/// sandboxed widget can't read that file), the latest snapshot as a
/// fallback, and the app's display settings.
enum WidgetBridge {
    /// The same id every time, so the widgets keep one client for this Mac.
    private static let clientID = UUID(uuidString: "6D61632D-0000-4000-8000-000000000001")!

    @MainActor
    static func publish(_ snapshot: UsageSnapshot, settings: CompanionSettings) {
        let config = CompanionConfig(localURL: "http://127.0.0.1:\(settings.port)", remoteURL: nil, token: settings.token)
        var changed = SharedStore.clients.first?.config != config
            || signature(SharedStore.lastSnapshot) != signature(snapshot)
        SharedStore.clients = [PairedClient(id: clientID, name: snapshot.host ?? "This Mac", config: config,
                                            snapshot: snapshot, lastRoute: config.routes.first)]
        SharedStore.lastSnapshot = snapshot

        let defaults = UserDefaults.standard
        var usage = SharedStore.usageSettings
        let barMode = BarMode(rawValue: defaults.string(forKey: Prefs.barMode) ?? "") ?? .used
        let style = UsageStyle(rawValue: defaults.string(forKey: Prefs.panelStyle) ?? "") ?? .bars
        if usage.barMode != barMode || usage.usageStyle != style {
            usage.barMode = barMode
            usage.usageStyle = style
            SharedStore.usageSettings = usage
            changed = true
        }
        // Every fetch has a new timestamp; only reload when something shown changed.
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    private static func signature(_ snapshot: UsageSnapshot?) -> [String] {
        (snapshot?.providers ?? []).map { provider in
            let windows = provider.windows.map { "\($0.id)=\(Int($0.percent.rounded()))@\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }
            return "\(provider.id):\(provider.status):\(windows.joined(separator: ","))"
        }
    }
}
