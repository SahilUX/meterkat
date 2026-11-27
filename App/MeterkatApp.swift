import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        WatchSync.shared.activate()
        // Both must happen before launch finishes.
        NotificationManager.installDelegate()
        BackgroundRefresh.register()
        return true
    }
}

@main
struct MeterkatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Before `store` is created, so the onboarding cover never shows.
        DebugLaunch.prepare()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in
                    store.handleOpenURL(url)
                }
                .task {
                    // First run asks for permission on the onboarding Notifications
                    // step instead. Afterwards this is a no-op once decided.
                    if asksForNotifications {
                        await NotificationManager.requestAuthorization()
                    }
                    BackgroundRefresh.schedule()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                store.startAutoRefresh()
            case .background:
                store.stopAutoRefresh()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }

    private var asksForNotifications: Bool {
        #if DEBUG
        // Visual QA runs shouldn't stop at the permission prompt.
        if DebugLaunch.screen != nil { return false }
        #endif
        return SharedStore.hasCompletedOnboarding
    }
}

struct RootView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            DashboardView()
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(AppTab.dashboard)
            settings
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        #if DEBUG
        .modifier(DebugScreenRouter())
        #endif
        .alert(
            "Pairing",
            isPresented: Binding(
                // During onboarding the Pair step shows the result instead.
                get: { store.pairingMessage != nil && !store.showOnboarding },
                set: { if !$0 { store.pairingMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(store.pairingMessage ?? "") }
        )
        .confirmsPairingAddition(store, isEnabled: !store.showOnboarding)
        .fullScreenCover(isPresented: $store.showOnboarding) {
            OnboardingView()
                .environmentObject(store)
        }
    }
}

extension View {
    /// A link opened from another app must not add a client silently.
    func confirmsPairingAddition(_ store: UsageStore, isEnabled: Bool = true) -> some View {
        alert(
            "Add client?",
            isPresented: Binding(
                get: { isEnabled && store.pendingPairing != nil },
                set: { if !$0 { store.pendingPairing = nil } }
            ),
            presenting: store.pendingPairing,
            actions: { config in
                Button("Add client") { store.acceptPairing(config) }
                Button("Cancel", role: .cancel) {}
            },
            message: { config in
                Text("Pair with \(config.routes.first?.baseURL ?? "another computer")?")
            }
        )
    }
}

extension RootView {
    private var settings: SettingsView {
        #if DEBUG
        return SettingsView(initialPath: DebugLaunch.settingsPath, scrollTo: DebugLaunch.settingsAnchor)
        #else
        return SettingsView()
        #endif
    }
}

#if DEBUG
/// Launch arguments for visual QA, e.g.
/// `-MeterkatDebugScreen settings.companion -MeterkatSkipOnboarding YES`.
/// Read once from the argument domain of `UserDefaults.standard`.
enum DebugLaunch {
    /// dashboard, settings, settings.companion, settings.display,
    /// settings.providers, settings.provider.<id>, settings.client, settings.devices, onboarding, widgets.
    /// `-MeterkatDebugPairLinkFile PATH` opens the pairing link stored in that file;
    /// `-MeterkatDebugConfirmPairing YES` accepts the "Add client?" question for it.
    static let screen = UserDefaults.standard.string(forKey: "MeterkatDebugScreen")
    static let skipsOnboarding = UserDefaults.standard.bool(forKey: "MeterkatSkipOnboarding")
    static let usageStyle = UserDefaults.standard.string(forKey: "MeterkatDebugUsageStyle").flatMap(UsageStyle.init(rawValue:))
    static let barMode = UserDefaults.standard.string(forKey: "MeterkatDebugBarMode").flatMap(BarMode.init(rawValue:))

    @MainActor private static var didApply = false

    /// Runs before the store exists.
    static func prepare() {
        if skipsOnboarding { SharedStore.hasCompletedOnboarding = true }
    }

    static var tab: AppTab? {
        guard let screen else { return nil }
        if screen == "dashboard" { return .dashboard }
        if screen == "settings" || screen.hasPrefix("settings.") { return .settings }
        return nil
    }

    static var settingsPath: [SettingsPage] {
        switch screen {
        case "settings.companion", "settings.clients": return [.clients]
        case "settings.addClient": return [.clients, .addClient]
        case "settings.client": return SharedStore.clients.first.map { [.clients, .client($0.id)] } ?? [.clients]
        case "settings.devices": return SharedStore.clients.first.map { [.clients, .client($0.id), .devices($0.id)] } ?? [.clients]
        case "settings.display": return [.display]
        default:
            let prefix = "settings.provider."
            guard let screen, screen.hasPrefix(prefix),
                  let provider = ProviderID(rawValue: String(screen.dropFirst(prefix.count)))
            else { return [] }
            return [.provider(provider)]
        }
    }

    static var settingsAnchor: SettingsView.Anchor? {
        screen == "settings.providers" ? .providers : nil
    }

    /// Selects the tab, forces the onboarding cover and applies display
    /// overrides. Once per launch.
    @MainActor
    static func apply(to store: UsageStore) {
        guard !didApply else { return }
        didApply = true
        if let tab { store.selectedTab = tab }
        if screen == "onboarding" { store.showOnboarding = true }
        // The system asks before opening a meterkat:// link in the simulator, and nothing can tap it.
        if let file = UserDefaults.standard.string(forKey: "MeterkatDebugPairLinkFile"),
           let link = try? String(contentsOfFile: file, encoding: .utf8),
           let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
            store.handleOpenURL(url)
            // Skips the "Add client?" alert that nothing can tap.
            if UserDefaults.standard.bool(forKey: "MeterkatDebugConfirmPairing"), let pending = store.pendingPairing {
                store.acceptPairing(pending)
            }
        }
        if usageStyle != nil || barMode != nil {
            var settings = store.settings
            if let usageStyle { settings.usageStyle = usageStyle }
            if let barMode { settings.barMode = barMode }
            store.updateSettings(settings)
        }
    }
}

/// Applies `DebugLaunch` to the root view and presents the widget gallery.
private struct DebugScreenRouter: ViewModifier {
    @EnvironmentObject private var store: UsageStore
    @State private var showWidgetGallery = DebugLaunch.screen == "widgets"

    func body(content: Content) -> some View {
        content
            .onAppear { DebugLaunch.apply(to: store) }
            .fullScreenCover(isPresented: $showWidgetGallery) {
                WidgetGalleryView()
                    .environmentObject(store)
            }
    }
}
#endif
