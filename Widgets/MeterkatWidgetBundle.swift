import SwiftUI
import WidgetKit

@main
struct MeterkatWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageSingleWidget()
        ProviderLimitsWidget()
        UsageOverviewWidget()
        UsageLargeWidget()
    }
}

/// The Mac has no Lock Screen, so it gets the system sizes only.
enum WidgetFamilies {
    static var singleLimit: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall]
        #else
        [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }

    static var providerLimits: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall]
        #else
        [.accessoryRectangular, .systemSmall]
        #endif
    }
}

struct UsageSingleWidget: Widget {
    let kind = "UsageSingleWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: UsageLimitIntent.self, provider: SingleLimitProvider()) { entry in
            SingleLimitView(entry: entry)
        }
        .configurationDisplayName("Usage Limit")
        .description("One usage limit of any provider, with its reset countdown. The wide Lock Screen size shows all of the provider's limits.")
        .supportedFamilies(WidgetFamilies.singleLimit)
    }
}

struct ProviderLimitsWidget: Widget {
    let kind = "ProviderLimitsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ProviderLimitsIntent.self, provider: ProviderLimitsProvider()) { entry in
            ProviderLimitsView(entry: entry)
        }
        .configurationDisplayName("Provider Limits")
        .description("Every limit of one provider as bars, with where you are in each window.")
        .supportedFamilies(WidgetFamilies.providerLimits)
    }
}

struct UsageOverviewWidget: Widget {
    let kind = "UsageOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            OverviewView(entry: entry)
        }
        .configurationDisplayName("Usage Overview")
        .description("Your providers' limits side by side.")
        .supportedFamilies([.systemMedium])
    }
}

struct UsageLargeWidget: Widget {
    let kind = "UsageLargeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            LargeUsageView(entry: entry)
        }
        .configurationDisplayName("All Limits")
        .description("Every provider and limit with reset times.")
        .supportedFamilies([.systemLarge])
    }
}
