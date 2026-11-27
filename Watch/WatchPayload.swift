import Foundation

struct WatchUsage: Codable {
    var updatedAt: Date
    var providers: [WatchProvider]
}

struct WatchProvider: Codable, Identifiable {
    var id: String
    var name: String
    var status: String
    var windows: [WatchWindow]
}

struct WatchWindow: Codable, Identifiable {
    var id: String
    var label: String
    var percent: Double
    var resetsAt: Date?
}

#if os(iOS)
extension WatchUsage {
    init(snapshot: UsageSnapshot) {
        updatedAt = snapshot.generatedAt
        providers = snapshot.providers.map { provider in
            WatchProvider(id: provider.id, name: provider.name, status: provider.status,
                          windows: provider.windows.map {
                WatchWindow(id: $0.id, label: $0.label, percent: $0.effectivePercent(), resetsAt: $0.resetsAt)
            })
        }
    }
}
#endif
