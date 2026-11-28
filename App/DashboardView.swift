import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    /// The window whose chart and stats sheet is open (bars style).
    @State private var detail: WindowDetail?
    /// The `identityKey` of the provider whose page is showing.
    @AppStorage("dashboardProvider") private var selectedKey = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.isPaired {
                    content
                } else {
                    NotPairedView()
                }
            }
            .navigationTitle("Meterkat")
            .toolbar {
                if store.isPaired {
                    ToolbarItem(placement: .topBarTrailing) {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("Refresh")
                        }
                    }
                }
            }
            .sheet(item: $detail) { detail in
                WindowDetailSheet(detail: detail)
                    .environmentObject(store)
            }
        }
    }

    private var content: some View {
        let providers = store.visibleProviders
        let selected = providers.first { $0.identityKey == selectedKey } ?? providers.first
        return ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 16) {
                    if let error = store.lastError {
                        ErrorBanner(message: error)
                    }
                    if let snapshot = store.snapshot {
                        if let limit = nextLimit(in: providers, selected: selected, now: context.date) {
                            NextLimitBanner(limit: limit) {
                                detail = WindowDetail(providerKey: limit.providerKey, windowID: limit.windowID)
                            }
                        }
                        if let selected {
                            ProviderPage(
                                provider: selected,
                                now: context.date,
                                style: store.settings.usageStyle,
                                barMode: store.settings.barMode,
                                history: store.history
                            ) { window in
                                detail = WindowDetail(providerKey: selected.identityKey, windowID: window.id)
                            }
                        } else {
                            NoProvidersView(allOff: store.settings.enabledProviders.isEmpty)
                        }
                        footer(snapshot)
                    } else if store.settings.enabledProviders.isEmpty {
                        NoProvidersView(allOff: true)
                    } else if store.lastError == nil {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting to your companion…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding()
            }
        }
        // A new page starts at the top.
        .id(selected?.identityKey)
        .background(Color(.systemGroupedBackground))
        .refreshable { await store.refresh() }
        // Sits just above the tab bar and stays put while the page scrolls.
        .safeAreaInset(edge: .bottom) {
            if store.snapshot != nil, !providers.isEmpty {
                ProviderBar(providers: providers, selection: selected?.identityKey ?? "") { key in
                    selectedKey = key
                }
            }
        }
    }

    /// The visible window projected to run out soonest, across every shown provider.
    private func nextLimit(in providers: [ProviderUsage], selected: ProviderUsage?, now: Date) -> NextLimit? {
        struct Key { var provider: ProviderUsage; var window: UsageWindow }
        var items: [(id: Key, projection: UsageProjection?)] = []
        for provider in providers where provider.isOK {
            for window in provider.windows {
                let series = store.history?.series(provider: provider.identityKey, window: window.id)
                let projection = UsageProjection.resolve(window: window, samples: series?.samples ?? [],
                                                         data: series?.prediction, now: now)
                items.append((Key(provider: provider, window: window), projection))
            }
        }
        guard let best = UsageProjection.earliestRunOut(items) else { return nil }
        let title = WindowRow.title(for: best.id.window)
        // Name the provider when the window isn't on the page below.
        let isSelected = best.id.provider.identityKey == selected?.identityKey
        let lines = best.projection.bannerLines(
            title: isSelected ? title : "\(best.id.provider.name) · \(title)",
            windowSeconds: best.id.window.windowSeconds)
        return lines.map {
            NextLimit(providerKey: best.id.provider.identityKey, windowID: best.id.window.id,
                      headline: $0.headline, detail: $0.detail)
        }
    }

    private func footer(_ snapshot: UsageSnapshot) -> some View {
        if store.clients.count > 1 {
            return Text("Updated \(snapshot.generatedAt, format: .relative(presentation: .named)) from \(store.clients.count) clients")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        let host = snapshot.host ?? "companion"
        var text = Text("Updated \(snapshot.generatedAt, format: .relative(presentation: .named)) from \(host)")
        if let route = store.route {
            text = text + Text(" via \(Image(systemName: route.kind.systemImage)) \(route.kind.label)")
        }
        return text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

/// Identifies the window shown in `WindowDetailSheet`. The sheet looks the
/// window up in the store so it stays current across refreshes.
struct WindowDetail: Identifiable, Hashable {
    var providerKey: String
    var windowID: String

    var id: String { "\(providerKey)|\(windowID)" }
}

// MARK: - Provider card

struct ProviderCard: View {
    let provider: ProviderUsage
    let now: Date
    var style: UsageStyle = .bars
    var barMode: BarMode = .used
    var history: UsageHistory?
    /// Opens a window's chart and stats. Rows are tappable in the bars style only.
    var onSelectWindow: ((UsageWindow) -> Void)?

    /// Collapsed by default; kept per card, so per provider, across refreshes.
    @State private var showsDetails = false
    @ScaledMetric(relativeTo: .title3) private var logoSize: CGFloat = 20

    private var tint: Color { UsageFormat.providerTint(provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if provider.sourceIsStale == true {
                Label("Last saved from \(provider.sourceClientName ?? "client")", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if provider.isOK, provider.stale == true {
                StaleNote(provider: provider)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if provider.isNoPlan {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if !provider.isOK {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ForEach(Array(provider.windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 { Divider() }
                WindowRow(
                    window: window,
                    providerID: provider.id,
                    now: now,
                    style: style,
                    barMode: barMode,
                    samples: history?.series(provider: provider.identityKey, window: window.id)?.samples ?? [],
                    predictionData: history?.series(provider: provider.identityKey, window: window.id)?.prediction,
                    onSelect: onSelectWindow.map { select in { select(window) } }
                )
            }

            if provider.windows.isEmpty && provider.isOK {
                Text("No usage windows reported.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let details = provider.details, !details.isEmpty {
                if !provider.windows.isEmpty { Divider() }
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            DetailRow(detail: detail)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .tint(tint)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Logo, name, plan and account on one row when they fit; otherwise the
    /// account, then the plan, move to a line of their own so the name never
    /// breaks mid-word.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                logo
                name(lineLimit: 1)
                planBadge
                Spacer(minLength: 8)
                accountText
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    logo
                    name(lineLimit: 1)
                    planBadge
                }
                accountText
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    logo
                    name(lineLimit: 2)
                }
                HStack(spacing: 8) {
                    planBadge
                    accountText
                }
            }
        }
    }

    private var logo: some View {
        ProviderLogo(providerID: provider.id)
            .frame(width: logoSize, height: logoSize)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private func name(lineLimit: Int) -> some View {
        Text(provider.name)
            .font(.title3.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(lineLimit)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var planBadge: some View {
        if let plan = provider.plan, !plan.isEmpty {
            Text(plan.capitalized)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(tint)
                .background(tint.opacity(0.15), in: Capsule())
                .fixedSize()
        }
    }

    @ViewBuilder
    private var accountText: some View {
        if let account = provider.account {
            Text(account)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let source = provider.sourceClientName {
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusMessage: String {
        if let error = provider.error, !error.isEmpty { return error }
        switch provider.status {
        case "not_signed_in": return "Not signed in on the companion machine."
        case "no_plan": return "No plan with usage limits on this account."
        default: return "Couldn't fetch usage."
        }
    }
}

// MARK: - Next limit banner

/// The window that will run out first, ready to open its detail sheet.
struct NextLimit: Equatable {
    var providerKey: String
    var windowID: String
    var headline: String
    var detail: String
}

/// Shown above the provider page only when a window is projected to run out
/// before its reset. Tapping opens that window's chart and stats.
struct NextLimitBanner: View {
    let limit: NextLimit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(limit.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next limit. \(limit.headline). \(limit.detail)")
        .accessibilityHint("Shows a graph and projection")
    }
}

// MARK: - Window row

struct WindowRow: View {
    let window: UsageWindow
    let providerID: String
    let now: Date
    var style: UsageStyle = .bars
    var barMode: BarMode = .used
    /// Recorded samples for the graph style.
    var samples: [UsageSample] = []
    var predictionData: UsagePredictionData?
    var onSelect: (() -> Void)?

    var body: some View {
        if style == .bars, let onSelect {
            Button(action: onSelect) { rowContent }
                .buttonStyle(.plain)
                .accessibilityHint("Shows a graph and projection")
        } else {
            rowContent
                .accessibilityElement(children: style == .bars ? .combine : .contain)
        }
    }

    private var projection: UsageProjection? {
        UsageProjection.resolve(window: window, samples: samples, data: predictionData, now: now)
    }

    @ViewBuilder
    private var rowContent: some View {
        let percent = window.effectivePercent(at: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.title(for: window))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if style == .bars, onSelect != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if style == .bars, let summary = projection?.resetSummary(mode: barMode) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UsageReadout(used: percent, mode: barMode)
                        Spacer(minLength: 8)
                        ProjectionLabel(summary: summary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        UsageReadout(used: percent, mode: barMode)
                        ProjectionLabel(summary: summary)
                    }
                }
            } else {
                UsageReadout(used: percent, mode: barMode)
            }
            if style == .graph {
                UsageChartView(window: window, providerID: providerID, mode: barMode, samples: samples, now: now,
                               predictionData: predictionData, isCompact: true)
            } else {
                PaceBar(window: window, mode: barMode, tint: UsageFormat.providerTint(providerID), at: now,
                        projection: projection)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormat.resetTextDetailed(window, now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let delta = window.paceDelta(at: now) {
                    PaceHint(delta: delta)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// "Current session", "Weekly limit", "Monthly limit", "Free requests today",
    /// "Key credit limit", "<model> session" or "<model> weekly".
    static func title(for window: UsageWindow) -> String {
        switch window.id {
        case WindowSlot.fiveHour.windowID: return "Current session"
        case WindowSlot.weekly.windowID: return "Weekly limit"
        case WindowSlot.monthly.windowID: return "Monthly limit"
        case WindowSlot.daily.windowID: return "Free requests today"
        case "key_limit": return "Key credit limit"
        default:
            if window.id.hasPrefix("five_hour_") { return "\(window.label) session" }
            if window.kind == "model" || window.id.hasPrefix("weekly_") { return "\(window.label) weekly" }
            return window.label
        }
    }
}

/// "About 61% at reset", or "Runs out early" in orange.
private struct ProjectionLabel: View {
    let summary: UsageProjection.ResetSummary

    var body: some View {
        Text(summary.text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(summary.warns ? Color.orange : Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// "68%" with a smaller "left" (or "used") after it.
private struct UsageReadout: View {
    /// Percent used, 0...100.
    let used: Double
    let mode: BarMode
    var font: Font = .title

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(UsageFormat.percent(mode.value(used: used)))
                .font(font.weight(.bold))
                .monospacedDigit()
            Text(mode == .used ? "used" : "left")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of a provider's extra facts: label and value side by side, stacked
/// at accessibility text sizes.
private struct DetailRow: View {
    let detail: ProviderDetail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(detail.label)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(detail.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Window detail sheet

/// Large graph and pace stats for one window, opened from the bars style.
struct WindowDetailSheet: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    let detail: WindowDetail

    private var provider: ProviderUsage? {
        store.visibleProviders.first { $0.identityKey == detail.providerKey }
    }

    private var window: UsageWindow? {
        provider?.windows.first { $0.id == detail.windowID }
    }

    @ScaledMetric(relativeTo: .subheadline) private var logoSize: CGFloat = 15

    private var mode: BarMode { store.settings.barMode }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let provider, let window {
                    ScrollView {
                        content(provider: provider, window: window, now: context.date)
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "No longer reported",
                        systemImage: "chart.xyaxis.line",
                        description: Text("The companion isn't reporting this window right now.")
                    )
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(window.map(WindowRow.title(for:)) ?? "Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func content(provider: ProviderUsage, window: UsageWindow, now: Date) -> some View {
        let samples = store.history?.series(provider: provider.identityKey, window: window.id)?.samples ?? []
        let predictionData = store.history?.series(provider: provider.identityKey, window: window.id)?.prediction
        let projection = UsageProjection.resolve(window: window, samples: samples, data: predictionData, now: now)
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProviderLogo(providerID: provider.id)
                        .frame(width: logoSize, height: logoSize)
                        .accessibilityHidden(true)
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(UsageFormat.providerTint(provider.id))
                UsageReadout(used: window.effectivePercent(at: now), mode: mode, font: .largeTitle)
                Text(UsageFormat.resetTextDetailed(window, now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            UsageChartView(window: window, providerID: provider.id, mode: mode, samples: samples, now: now,
                           predictionData: predictionData)

            stats(window: window, projection: projection, now: now)
        }
    }

    private func stats(window: UsageWindow, projection: UsageProjection?, now: Date) -> some View {
        let current = window.effectivePercent(at: now)
        return VStack(spacing: 0) {
            StatRow(title: mode == .used ? "Used now" : "Left now") {
                Text(UsageFormat.percent(mode.value(used: current)))
            }
            Divider()
            StatRow(title: "Even pace now") {
                Text(window.elapsedFraction(at: now).map { UsageFormat.percent(mode.value(used: $0 * 100)) } ?? "—")
            }
            Divider()
            StatRow(title: "Current vs even pace") {
                paceText(window.paceDelta(at: now))
            }
            Divider()
            StatRow(title: "Rate") {
                Text(projection.map { "\($0.ratePerHour.formatted(.number.precision(.fractionLength(1)))) pts / hr" } ?? "—")
            }
            Divider()
            StatRow(title: mode == .used ? "Projected at reset" : "Projected left at reset") {
                Text(projection.map { UsageFormat.percent(mode.value(used: min($0.projectedAtReset, 100))) } ?? "—")
            }
            Divider()
            StatRow(title: "Budget to make it") {
                Text(projection?.budget(windowSeconds: window.windowSeconds)?.statText ?? "—")
            }
            if let projection {
                Divider()
                outlook(projection, window: window, current: current)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func outlook(_ projection: UsageProjection, window: UsageWindow, current: Double) -> some View {
        if current >= 100 {
            Label("Limit reached until the reset", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else if let lines = projection.detailOutlook(windowSeconds: window.windowSeconds) {
            Label {
                (Text(lines.headline).fontWeight(.semibold) + Text(" " + lines.detail).fontWeight(.regular))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else if !projection.isEstablished {
            Label(projection.outlookText, systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            Label(projection.outlookText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func paceText(_ delta: Double?) -> some View {
        if let delta {
            let points = Int(abs(delta).rounded())
            if delta > PaceHint.tolerance {
                Text("\(points) pts ahead").foregroundStyle(.orange)
            } else if delta < -PaceHint.tolerance {
                Text("\(points) pts under").foregroundStyle(.green)
            } else if points == 0 {
                Text("On pace")
            } else {
                Text("\(points) pts \(delta > 0 ? "ahead" : "under")")
            }
        } else {
            Text("—")
        }
    }
}

private struct StatRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            value
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }
}

// MARK: - Banners and empty states

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message).lineLimit(3)
        } icon: {
            Image(systemName: "wifi.exclamationmark")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shown when there's nothing to list because providers are turned off.
struct NoProvidersView: View {
    @EnvironmentObject private var store: UsageStore
    /// Every provider is off, rather than none of the enabled ones being reported.
    let allOff: Bool

    var body: some View {
        ContentUnavailableView {
            Label(allOff ? "All providers are off" : "No providers to show",
                  systemImage: allOff ? "eye.slash" : "questionmark.circle")
        } description: {
            Text(allOff
                 ? "Turn a provider back on in Settings → Providers."
                 : "The companion isn't reporting any of the providers turned on here. Check Settings → Providers.")
        } actions: {
            Button("Open Settings") {
                store.selectedTab = .settings
            }
        }
        .padding(.top, 40)
    }
}

struct NotPairedView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var showScanner = false

    var body: some View {
        ContentUnavailableView {
            Label("Pair your computer", systemImage: "laptopcomputer.and.iphone")
        } description: {
            Text("Meterkat reads your Claude, OpenAI, Copilot, Gemini, Cursor and other AI plan limits from a small companion running on your Mac or Linux machine.\n\nOn a Mac, open the Meterkat menu bar app to show its pairing QR code. On Linux, run `meterkat pair`. You can also enter the addresses and token in Settings.")
        } actions: {
            Button("Scan pairing code", systemImage: "qrcode.viewfinder") {
                showScanner = true
            }
            .buttonStyle(.borderedProminent)

            Button("Open setup guide") {
                store.showOnboarding = true
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { config in
                Task { await store.connect(config) }
            }
        }
    }
}
