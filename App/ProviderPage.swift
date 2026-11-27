import SwiftUI

/// Everything for one provider account: current limits, then the split by
/// product, cost at API rates and token stats.
struct ProviderPage: View {
    let provider: ProviderUsage
    let now: Date
    var style: UsageStyle = .bars
    var barMode: BarMode = .used
    var history: UsageHistory?
    var onSelectWindow: ((UsageWindow) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ProviderCard(provider: provider, now: now, style: style, barMode: barMode,
                         history: history, onSelectWindow: onSelectWindow)
            ProviderInsightSections(provider: provider)
        }
    }
}
