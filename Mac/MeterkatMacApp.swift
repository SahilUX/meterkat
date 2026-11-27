// Meterkat for Mac: shows the local companion's usage snapshot in a window,
// and as stacked bars in the menu bar with per-window bars or graphs in its
// popover. Settings holds the menu bar options and the iPhone pairing QR code. The Xcode target MeterkatMac builds it
// from Mac/ and Shared/.

import AppKit
import SwiftUI

/// Handles the `--render-icon`, `--render-panel`, `--render-window` and `--render-machines`
/// preview modes (see RenderPreviews.swift) before starting the app.
/// `--background` (the login item) starts without opening the window.
@main
@MainActor
enum Launcher {
    static func main() {
        Prefs.register()
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let scale = CGFloat(value(after: "--scale").flatMap(Double.init) ?? 2)
        if let path = value(after: "--render-icon") {
            IconPreview.run(path: path, scale: scale)
        }
        if let path = value(after: "--render-panel") {
            PanelPreview.run(path: path, scale: scale, graph: arguments.contains("--graph"),
                             dark: arguments.contains("--dark"), expand: value(after: "--expand"))
        }
        if let path = value(after: "--render-window") {
            PanelPreview.run(path: path, scale: scale, graph: arguments.contains("--graph"),
                             dark: arguments.contains("--dark"), expand: value(after: "--expand"), window: true)
        }
        if let path = value(after: "--render-setup") {
            SetupPreview.run(path: path, step: value(after: path) ?? "welcome", scale: scale)
        }
        if let path = value(after: "--render-machines") {
            MachinesPreview.run(path: path, machine: value(after: "--machine"), scale: scale,
                                dark: arguments.contains("--dark"))
        }
        AppDelegate.launchedInBackground = arguments.contains("--background")
        MeterkatMacApp.main()
    }
}

struct MeterkatMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionModel()
    @StateObject private var machines = MachinesModel()
    @AppStorage(Prefs.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @AppStorage(Prefs.iconStyle) private var iconStyle = IconStyle.combined
    @AppStorage(Prefs.showLogos) private var showLogos = true
    @AppStorage(Prefs.colored) private var colored = false
    @AppStorage(Prefs.barMode) private var barMode = BarMode.used
    @AppStorage(Prefs.hiddenProviders) private var hiddenProviders = ""

    var body: some Scene {
        Window("Meterkat", id: MainWindow.id) {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 760, height: 680)
        // Opening the app shows the window (and setup, until it's done); a
        // login launch (`--background`) stays in the menu bar and Dock.
        .defaultLaunchBehavior(AppDelegate.launchedInBackground ? .suppressed : .presented)
        // Restoring an open window would override the login launch's .suppressed.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(before: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Divider()
            }
        }
        .onChange(of: showInDock) { AppDelegate.applyActivationPolicy() }

        Settings {
            SettingsView().environmentObject(model).environmentObject(machines)
        }

        // Every provider when Combined, the first one when Separate, or a
        // placeholder when there's nothing to show.
        MenuBarExtra(isInserted: mainItemInserted) {
            PanelView().environmentObject(model)
        } label: {
            label(for: mainStacks)
        }
        .menuBarExtraStyle(.window)

        // Separate mode gives the other providers items of their own. Scenes
        // can't be generated from data, so there's one per known provider
        // (ProviderUsage.order).
        providerItem("claude")
        providerItem("openai")
        providerItem("opencode")
        providerItem("openrouter")
        providerItem("copilot")
        providerItem("gemini")
        providerItem("cursor")
        providerItem("zai")
        providerItem("kimi")
        providerItem("minimax")
        providerItem("bailian")
        providerItem("deepseek")
    }

    /// Command-dragging the item out of the menu bar turns "Show in menu
    /// bar" off, and the Dock icon back on so the app stays reachable.
    private var mainItemInserted: Binding<Bool> {
        Binding(
            get: { showInMenuBar },
            set: { inserted in
                guard !inserted, showInMenuBar else { return }
                showInMenuBar = false
                showInDock = true
            }
        )
    }

    private var stacks: [IconStack] {
        model.iconStacks(mode: barMode, hidden: Prefs.ids(hiddenProviders))
    }

    /// Everything when Combined; when Separate, the first provider plus any
    /// a newer companion added that have no item of their own.
    private var mainStacks: [IconStack] {
        guard iconStyle == .separate else { return stacks }
        let separate = separateIDs
        return stacks.filter { !separate.contains($0.providerID) }
    }

    private var options: IconOptions {
        IconOptions(showLogos: showLogos, colored: colored, dimmed: model.state != .online)
    }

    /// Providers shown as a menu bar item of their own: all but the first,
    /// which the main item shows.
    private var separateIDs: Set<String> {
        guard showInMenuBar, iconStyle == .separate else { return [] }
        return Set(stacks.dropFirst().map(\.providerID)).intersection(ProviderUsage.order)
    }

    private func providerItem(_ id: String) -> some Scene {
        let isInserted = Binding(
            get: { separateIDs.contains(id) },
            set: { inserted in
                // The user Command-dragged it out of the menu bar.
                if !inserted, separateIDs.contains(id) {
                    hiddenProviders = Prefs.raw(Prefs.ids(hiddenProviders).union([id]))
                }
            }
        )
        return MenuBarExtra(isInserted: isInserted) {
            PanelView().environmentObject(model)
        } label: {
            label(for: stacks.filter { $0.providerID == id })
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private func label(for stacks: [IconStack]) -> some View {
        if let image = MenuBarIcon.image(for: stacks, options: options) {
            Image(nsImage: image)
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from `--background` before the app starts.
    static var launchedInBackground = false

    /// A Dock icon and app menu, or only the menu bar item.
    @MainActor
    static func applyActivationPolicy() {
        let showInDock = UserDefaults.standard.bool(forKey: Prefs.showInDock)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Leaving the Dock deactivates the app; keep Settings in front.
        NSApp.activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Installed before the app had setup (by install.sh): nothing to set up.
        if Launchd.isInstalled, !UserDefaults.standard.bool(forKey: Prefs.setupDone) {
            UserDefaults.standard.set(true, forKey: Prefs.setupDone)
        }
        let showInDock = UserDefaults.standard.bool(forKey: Prefs.showInDock)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// Closing the window leaves the app in the menu bar or the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
