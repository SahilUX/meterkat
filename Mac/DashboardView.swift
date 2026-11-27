import AppKit
import SwiftUI

enum MainWindow {
    static let id = "main"
}

/// The main window: one page per provider account, picked from a bar of
/// provider icons along the bottom. Each page has the limits, then the
/// split by product, cost at API rates and token stats.
struct DashboardView: View {
    @EnvironmentObject private var model: CompanionModel
    @AppStorage(Prefs.barMode) private var barMode = BarMode.used
    @AppStorage(Prefs.panelStyle) private var panelStyle = UsageStyle.bars
    @AppStorage(Prefs.setupDone) private var setupDone = false
    /// The `identityKey` of the provider whose page is showing.
    @AppStorage("dashboardProvider") private var selectedKey = ""
    @State private var showsPairing = false
    /// For `--render-window`: no scroll view and a fixed clock.
    var snapshotDate: Date?

    private let spacing: CGFloat = 16

    var body: some View {
        Group {
            if !setupDone && snapshotDate == nil {
                SetupView()
            } else if snapshotDate != nil {
                content
            } else {
                ScrollView { content }
                    // A new page starts at the top.
                    .id(selected?.identityKey)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if setupDone || snapshotDate != nil, model.snapshot != nil, !model.providers.isEmpty {
                ProviderBar(providers: model.providers, selection: selected?.identityKey ?? "") { key in
                    selectedKey = key
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle("Meterkat")
        .navigationSubtitle(model.host ?? "This Mac")
        .toolbar {
            ToolbarItem(placement: .navigation) { StatusIndicator().padding(.horizontal, 6) }
            if setupDone { toolbarButtons }
        }
        .onAppear { Task { await model.refresh() } }
        .onChange(of: panelStyle) { Task { await model.loadHistoryIfStale() } }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
            ToolbarItemGroup {
                UsageStylePicker()
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(model.isRefreshing)
                Button { showsPairing.toggle() } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                }
                .help("Pair iPhone")
                .popover(isPresented: $showsPairing, arrowEdge: .bottom) {
                    PairingSection().padding(16).frame(width: 300)
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: spacing) {
            StatusBanner()
            if model.snapshot != nil {
                if let snapshotDate {
                    providers(now: snapshotDate)
                } else {
                    TimelineView(.everyMinute) { providers(now: $0.date) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var selected: ProviderUsage? {
        model.providers.first { $0.identityKey == selectedKey } ?? model.providers.first
    }

    private func providers(now: Date) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let provider = selected {
                card {
                    ProviderSection(provider: provider, mode: barMode, style: panelStyle, now: now,
                                    showsBreakdown: false)
                }
                ProviderInsightSections(provider: provider)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}
