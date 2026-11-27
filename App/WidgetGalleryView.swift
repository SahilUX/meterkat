import SwiftUI
import UIKit

/// DEBUG-only screen that renders the widget layouts at iPhone 13 Lock Screen
/// and Home Screen sizes, so they can be checked in the simulator without
/// adding widgets. Uses the latest snapshot, or sample data before the first
/// fetch, and the app's settings (bar mode, provider switches).
struct WidgetGalleryView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        let snapshot = store.snapshot ?? WidgetSampleData.snapshot()
        let settings = store.settings
        let date = Date.now
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("\(store.snapshot == nil ? "Sample data" : "Latest snapshot") · bars show \(settings.barMode.label.lowercased())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(ProviderID.allCases) { provider in
                    providerSection(provider, snapshot: snapshot, settings: settings, date: date)
                }
                GallerySection(title: "All providers") {
                    GalleryTile(family: .medium, title: "Usage Overview") {
                        OverviewWidgetLayout(snapshot: snapshot, date: date, settings: settings, isStale: false)
                    }
                    GalleryTile(family: .large, title: "All Limits") {
                        AllLimitsWidgetLayout(snapshot: snapshot, date: date, settings: settings, isStale: false)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical)
        }
        .navigationTitle("Widget Gallery")
    }

    private func providerSection(_ provider: ProviderID, snapshot: UsageSnapshot,
                                 settings: UsageSettings, date: Date) -> some View {
        let slots = provider.knownSlots
        let firstSlot = slots.first ?? .fiveHour
        func single(_ family: WidgetLayoutFamily, _ slot: WindowSlot) -> SingleLimitWidgetLayout {
            SingleLimitWidgetLayout(family: family, snapshot: snapshot, provider: provider, slot: slot,
                                    date: date, settings: settings, isStale: false)
        }
        func limits(_ family: WidgetLayoutFamily) -> ProviderLimitsWidgetLayout {
            ProviderLimitsWidgetLayout(family: family, snapshot: snapshot, provider: provider,
                                       date: date, settings: settings, isStale: false)
        }
        return GallerySection(title: provider.displayName) {
            LockScreenPanel {
                HStack(alignment: .top, spacing: 12) {
                    GalleryTile(family: .accessoryRectangular, title: "Provider Limits") {
                        limits(.accessoryRectangular)
                    }
                    GalleryTile(family: .accessoryRectangular, title: "Usage Limit") {
                        single(.accessoryRectangular, firstSlot)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(slots) { slot in
                        GalleryTile(family: .accessoryCircular, title: slot.shortLabel) {
                            single(.accessoryCircular, slot)
                        }
                    }
                }
                GalleryTile(family: .accessoryInline, title: "Usage Limit · inline") {
                    single(.accessoryInline, firstSlot)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                GalleryTile(family: .small, title: "Provider Limits") {
                    limits(.small)
                }
                GalleryTile(family: .small, title: "Usage Limit · \(firstSlot.shortLabel)") {
                    single(.small, firstSlot)
                }
            }
        }
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
            content
        }
    }
}

/// A dark, wallpaper-like backdrop for the Lock Screen families.
private struct LockScreenPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.28),
                                    Color(red: 0.32, green: 0.18, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// One layout at its iPhone 13 size. Lock Screen families get a simulated
/// vibrant look (monochrome, dark) and are clipped to their bounds like the
/// system clips them; Home Screen families get the widget background and
/// content margins.
private struct GalleryTile<Content: View>: View {
    let family: WidgetLayoutFamily
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let size = family.size
        VStack(alignment: .leading, spacing: 4) {
            if family.isAccessory {
                content
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .dark)
                    .grayscale(1)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: family == .accessoryCircular ? size.width / 2 : 6)
                            .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    )
            } else {
                content
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            Text("\(title) · \(family.label) \(Int(size.width))×\(Int(size.height))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: size.width, alignment: .leading)
        }
    }
}
