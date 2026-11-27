import Foundation
import UserNotifications

/// Shows notifications as banners while the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

enum NotificationManager {
    static let resetPrefix = "reset."

    private static var center: UNUserNotificationCenter { .current() }

    static func installDelegate() {
        center.delegate = NotificationDelegate.shared
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Drops scheduled reset alerts and threshold history, e.g. after forgetting the companion.
    static func clearAlerts() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(resetPrefix) })
        SharedStore.firedThresholds = []
    }

    /// Schedules reset alerts and delivers limit alerts for a fresh snapshot,
    /// following each provider's settings. Safe to call from the app or from
    /// a background task.
    static func process(_ snapshot: UsageSnapshot, now: Date = .now) async {
        let settings = SharedStore.usageSettings
        await scheduleResetAlerts(snapshot, settings: settings, now: now)
        await deliverLimitAlerts(snapshot, settings: settings, now: now)
    }

    /// Enabled providers that reported usage, with their settings.
    private static func alertingProviders(_ snapshot: UsageSnapshot, settings: UsageSettings) -> [(ProviderUsage, ProviderSettings)] {
        snapshot.providers.compactMap { provider in
            guard provider.isOK, !provider.isStale,
                  settings.isEnabled(provider.id), let id = provider.providerID else { return nil }
            return (provider, settings[id])
        }
    }

    // MARK: Reset alerts

    private static func scheduleResetAlerts(_ snapshot: UsageSnapshot, settings: UsageSettings, now: Date) async {
        var wanted = Set<String>()
        for (provider, providerSettings) in alertingProviders(snapshot, settings: settings) {
            for window in provider.windows where providerSettings.announcesReset(of: window.id) {
                guard let resetsAt = window.resetsAt else { continue }
                let interval = resetsAt.timeIntervalSince(now)
                guard interval > 1, window.percent >= ProviderSettings.resetMinimumPercent else { continue }

                let identifier = "\(resetPrefix)\(provider.alertID).\(window.id)"
                wanted.insert(identifier)

                let content = UNMutableNotificationContent()
                content.title = "\(provider.name) \(limitName(window)) reset"
                if let account = provider.account { content.subtitle = account }
                content.body = "Your \(windowName(window)) is fresh — 100% available."
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        }

        // Providers that failed this fetch keep whatever was scheduled before,
        // as long as they and the window are still turned on.
        let unknownProviders = Set(snapshot.providers.filter { !$0.isOK || $0.isStale }.map(\.alertID))
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { identifier in
            guard identifier.hasPrefix(resetPrefix), !wanted.contains(identifier) else { return false }
            let parts = identifier.dropFirst(resetPrefix.count).split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, unknownProviders.contains(parts[0]),
                  let id = ProviderID(rawValue: String(parts[0].split(separator: "_").first ?? "")) else { return true }
            return !(settings.isEnabled(id.rawValue) && settings[id].announcesReset(of: parts[1]))
        }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    // MARK: Limit alerts

    private static func deliverLimitAlerts(_ snapshot: UsageSnapshot, settings: UsageSettings, now: Date) async {
        let nowEpoch = Int(now.timeIntervalSince1970)
        // Prune keys for cycles that have already reset.
        var fired = SharedStore.firedThresholds.filter { key in
            guard let parsed = parse(key) else { return false }
            return parsed.epoch == 0 || parsed.epoch > nowEpoch
        }

        for (provider, providerSettings) in alertingProviders(snapshot, settings: settings) where providerSettings.limitAlerts {
            let threshold = providerSettings.limitThreshold
            for window in provider.windows {
                let percent = window.effectivePercent(at: now)
                guard percent >= threshold else { continue }
                let epoch = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)

                if !alreadyFired(fired, provider: provider.alertID, window: window.id, threshold: threshold, epoch: epoch) {
                    let content = UNMutableNotificationContent()
                    content.title = "\(provider.name) is nearing a limit"
                    if let account = provider.account { content.subtitle = account }
                    content.body = limitBody(provider: provider, window: window, percent: percent, mode: settings.barMode, now: now)
                    content.sound = .default
                    let identifier = "threshold.\(provider.alertID).\(window.id).\(Int(threshold))"
                    try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                }
                fired.insert(key(provider: provider.alertID, window: window.id, epoch: epoch, threshold: threshold))
            }
        }

        SharedStore.firedThresholds = fired
    }

    private static func key(provider: String, window: String, epoch: Int, threshold: Double) -> String {
        "\(provider)|\(window)|\(epoch)|\(Int(threshold))"
    }

    private static func parse(_ key: String) -> (provider: String, window: String, epoch: Int, threshold: Int)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let epoch = Int(parts[2]), let threshold = Int(parts[3]) else { return nil }
        return (parts[0], parts[1], epoch, threshold)
    }

    /// An alert at this threshold or a higher one already covers the cycle,
    /// so lowering the slider doesn't alert again. Reset timestamps can
    /// jitter by a few seconds between fetches; treat anything within
    /// 5 minutes as the same cycle.
    private static func alreadyFired(_ fired: Set<String>, provider: String, window: String, threshold: Double, epoch: Int) -> Bool {
        fired.contains { existing in
            guard let parsed = parse(existing) else { return false }
            return parsed.provider == provider
                && parsed.window == window
                && parsed.threshold >= Int(threshold)
                && abs(parsed.epoch - epoch) <= 300
        }
    }

    // MARK: Wording

    /// "Claude 5-hour limit at 82% used — resets in 1 hr 12 min (Sat, 3:09 AM)",
    /// or "… at 18% left" when bars show what's remaining.
    private static func limitBody(provider: ProviderUsage, window: UsageWindow, percent: Double, mode: BarMode, now: Date) -> String {
        let usage = "\(provider.name) \(limitName(window)) at \(mode.percentText(used: percent))"
        guard let resetsAt = window.resetsAt, resetsAt > now else { return usage + "." }
        let reset = UsageFormat.resetTextDetailed(window, now: now)
        return "\(usage) — \(reset.prefix(1).lowercased())\(reset.dropFirst())"
    }

    /// "5-hour limit", "weekly limit", "Fable weekly limit", "monthly limit",
    /// "daily limit", "key credit limit".
    private static func limitName(_ window: UsageWindow) -> String {
        // Credit windows are labelled as limits already ("Key credit limit").
        if window.kind == "credit" { return window.label.prefix(1).lowercased() + window.label.dropFirst() }
        return "\(windowName(window).replacingOccurrences(of: " window", with: "")) limit"
    }

    /// "5-hour window", "weekly window", "Fable weekly window", "monthly window",
    /// "daily window", "<model> 5-hour window".
    private static func windowName(_ window: UsageWindow) -> String {
        if window.id.hasPrefix("five_hour_") { return "\(window.label) 5-hour window" }
        switch window.kind {
        case "weekly": return "weekly window"
        case "monthly": return "monthly window"
        case "daily": return "daily window"
        case "model": return "\(window.label) weekly window"
        default: return "\(window.label) window"
        }
    }
}
