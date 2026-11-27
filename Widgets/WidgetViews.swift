import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

// Entry views: each maps the widget family and timeline entry onto a layout
// from Shared/WidgetLayouts.swift, which the app's widget gallery also renders.

private let openURL = URL(string: "meterkat://open")

extension WidgetLayoutFamily {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .accessoryRectangular: self = .accessoryRectangular
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryInline: self = .accessoryInline
        // systemLarge, and the extra-large sizes this widget doesn't offer.
        default: self = .large
        }
    }
}

extension View {
    /// System background on the Home Screen; the Lock Screen draws its own
    /// (vibrant) backdrop, so accessory widgets stay clear.
    func usageWidgetBackground(_ family: WidgetLayoutFamily) -> some View {
        containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                #if os(macOS)
                Color(nsColor: .windowBackgroundColor)
                #else
                Color(UIColor.systemBackground)
                #endif
            }
        }
    }
}

struct SingleLimitView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: UsageEntry

    var body: some View {
        let family = WidgetLayoutFamily(widgetFamily)
        SingleLimitWidgetLayout(family: family, snapshot: entry.snapshot, provider: entry.provider,
                                slot: entry.slot, date: entry.date, settings: entry.settings,
                                isStale: entry.isStale, isPaired: entry.isPaired)
            .usageWidgetBackground(family)
            .widgetURL(openURL)
    }
}

struct ProviderLimitsView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: UsageEntry

    var body: some View {
        let family = WidgetLayoutFamily(widgetFamily)
        ProviderLimitsWidgetLayout(family: family, snapshot: entry.snapshot, provider: entry.provider,
                                   date: entry.date, settings: entry.settings,
                                   isStale: entry.isStale, isPaired: entry.isPaired)
            .usageWidgetBackground(family)
            .widgetURL(openURL)
    }
}

struct OverviewView: View {
    let entry: UsageEntry

    var body: some View {
        OverviewWidgetLayout(snapshot: entry.snapshot, date: entry.date, settings: entry.settings,
                             isStale: entry.isStale, isPaired: entry.isPaired)
            .usageWidgetBackground(.medium)
            .widgetURL(openURL)
    }
}

struct LargeUsageView: View {
    let entry: UsageEntry

    var body: some View {
        AllLimitsWidgetLayout(snapshot: entry.snapshot, date: entry.date, settings: entry.settings,
                              isStale: entry.isStale, isPaired: entry.isPaired)
            .usageWidgetBackground(.large)
            .widgetURL(openURL)
    }
}
