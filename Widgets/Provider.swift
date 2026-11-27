import Foundation
import WidgetKit

struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot?
    /// True when the live fetch failed and `snapshot` came from the App Group cache.
    var isStale: Bool
    var isPaired: Bool
    /// The app's provider switches and bar mode, read when the timeline was built.
    var settings = UsageSettings()
    /// Only used by the configurable widgets; `slot` only by "Usage Limit".
    var provider: ProviderID = .claude
    var slot: WindowSlot = .fiveHour

    static func sample(provider: ProviderID = .claude, slot: WindowSlot = .fiveHour) -> UsageEntry {
        UsageEntry(date: .now, snapshot: WidgetSampleData.snapshot(), isStale: false, isPaired: true,
                   settings: SharedStore.usageSettings, provider: provider, slot: slot)
    }
}

enum UsageLoader {
    struct Result {
        var snapshot: UsageSnapshot?
        var isStale: Bool
        var isPaired: Bool
    }

    /// Live fetch (8s timeout) with fallback to the cached snapshot.
    static func load() async -> Result {
        let clients = SharedStore.clients
        guard !clients.isEmpty else {
            return Result(snapshot: nil, isStale: false, isPaired: false)
        }
        let result = await ClientMerge.refresh(clients, timeout: 8)
        let current = SharedStore.clients
        guard current.map(\.id) == clients.map(\.id),
              zip(current, clients).allSatisfy({ $0.0.config == $0.1.config }) else {
            return Result(snapshot: SharedStore.lastSnapshot, isStale: true, isPaired: true)
        }
        SharedStore.clients = result.clients
        let snapshot = ClientMerge.snapshot(result.clients, unavailable: Set(result.errors.keys)) ?? SharedStore.lastSnapshot
        if result.didFetch { SharedStore.lastSnapshot = snapshot }
        return Result(snapshot: snapshot,
                      isStale: !result.didFetch || snapshot?.providers.contains(where: \.isStale) == true,
                      isPaired: true)
    }

    /// Cheap variant for widget-gallery snapshots: cached data if we have it, else a live fetch.
    static func quick() async -> Result {
        if !SharedStore.clients.isEmpty, let cached = SharedStore.lastSnapshot {
            return Result(snapshot: cached, isStale: false, isPaired: true)
        }
        return await load()
    }

    static func entry(_ result: Result, provider: ProviderID = .claude, slot: WindowSlot = .fiveHour,
                      date: Date = .now) -> UsageEntry {
        var settings = SharedStore.usageSettings
        if let snapshot = result.snapshot, let adopted = settings.addingNewProviders(from: snapshot) {
            SharedStore.usageSettings = adopted
            settings = adopted
        }
        return UsageEntry(date: date, snapshot: result.snapshot, isStale: result.isStale,
                          isPaired: result.isPaired, settings: settings,
                          provider: provider, slot: slot)
    }

    /// Entries at now, every 15 minutes for the next hour (countdown text and the
    /// elapsed-time marker), and at each reset within the next 6 hours (so the gauge
    /// drops to 0% on time).
    static func timeline(base: UsageEntry, now: Date = .now) -> Timeline<UsageEntry> {
        var dates: Set<Date> = [now]
        for step in 1...4 {
            dates.insert(now.addingTimeInterval(Double(step) * 15 * 60))
        }
        let horizon = now.addingTimeInterval(6 * 3600)
        for provider in base.snapshot?.providers ?? [] {
            for window in provider.windows {
                if let reset = window.resetsAt, reset > now, reset <= horizon {
                    dates.insert(reset)
                }
            }
        }
        let entries = dates.sorted().map { date -> UsageEntry in
            var entry = base
            entry.date = date
            return entry
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }
}

/// Timeline provider for the static (non-configurable) widgets.
struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(.sample())
            return
        }
        Task {
            completion(UsageLoader.entry(await UsageLoader.quick()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let result = await UsageLoader.load()
            completion(UsageLoader.timeline(base: UsageLoader.entry(result)))
        }
    }
}

/// Timeline provider for the configurable single-limit widget.
struct SingleLimitProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: UsageLimitIntent, in context: Context) async -> UsageEntry {
        let provider = configuration.provider.providerID
        let slot = configuration.slot
        if context.isPreview {
            return .sample(provider: provider, slot: slot)
        }
        return UsageLoader.entry(await UsageLoader.quick(), provider: provider, slot: slot)
    }

    func timeline(for configuration: UsageLimitIntent, in context: Context) async -> Timeline<UsageEntry> {
        let result = await UsageLoader.load()
        let base = UsageLoader.entry(result, provider: configuration.provider.providerID,
                                     slot: configuration.slot)
        return UsageLoader.timeline(base: base)
    }
}

/// Timeline provider for the configurable "Provider Limits" widget.
struct ProviderLimitsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: ProviderLimitsIntent, in context: Context) async -> UsageEntry {
        let provider = configuration.provider.providerID
        if context.isPreview {
            return .sample(provider: provider)
        }
        return UsageLoader.entry(await UsageLoader.quick(), provider: provider)
    }

    func timeline(for configuration: ProviderLimitsIntent, in context: Context) async -> Timeline<UsageEntry> {
        let result = await UsageLoader.load()
        let base = UsageLoader.entry(result, provider: configuration.provider.providerID)
        return UsageLoader.timeline(base: base)
    }
}
