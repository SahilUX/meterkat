import SwiftUI

// MARK: - Provider bar

/// One icon per provider account on a Liquid Glass capsule, floating over
/// the bottom of the dashboard. Like the system tab bar, pressing it lifts
/// a clear glass lens that follows the finger across the icons and settles
/// on the one under it when let go. A provider with several accounts shows
/// a number on each icon.
struct ProviderBar: View {
    let providers: [ProviderUsage]
    let selection: String
    let onSelect: (String) -> Void

    /// Where the finger is along the bar while it's pressed.
    @State private var dragX: CGFloat?
    @Namespace private var namespace

    #if os(iOS)
    @ScaledMetric(relativeTo: .body) private var itemSize: CGFloat = 40
    #else
    private let itemSize: CGFloat = 34
    #endif
    private let spacing: CGFloat = 2
    private let inset: CGFloat = 5

    private var selectedIndex: Int? {
        providers.firstIndex { $0.identityKey == selection }
    }

    /// The icon under the finger while pressed, else the selected one.
    private var focusedIndex: Int? {
        dragX.map(index(at:)) ?? selectedIndex
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(scrubs: true)
            // Too many accounts for the width: scroll, and tap to pick.
            ScrollView(.horizontal, showsIndicators: false) { bar(scrubs: false) }
                .clipShape(Capsule())
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: focusedIndex)
        #endif
    }

    private func bar(scrubs: Bool) -> some View {
        let width = CGFloat(providers.count) * itemSize + CGFloat(max(providers.count - 1, 0)) * spacing
        return HStack(spacing: spacing) {
            ForEach(Array(providers.enumerated()), id: \.element.identityKey) { index, provider in
                ProviderBarItem(provider: provider, number: accountNumber(at: index),
                                isFocused: index == focusedIndex, size: itemSize)
                    .onTapGesture { select(index) }
                    .accessibilityAction { select(index) }
            }
        }
        .frame(width: width, height: itemSize)
        .background(alignment: .leading) { lens }
        .padding(inset)
        .contentShape(Capsule())
        .gesture(scrubs ? scrub : nil)
        .modifier(GlassCapsule())
        .scaleEffect(dragX == nil ? 1 : 1.03)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragX == nil)
    }

    /// The highlight behind the focused icon: tinted at rest, a larger clear
    /// lens that tracks the finger while pressed.
    @ViewBuilder
    private var lens: some View {
        if let index = focusedIndex {
            let tint = UsageFormat.providerTint(providers[index].id)
            let pressed = dragX != nil
            let x = pressed
                ? min(max((dragX ?? 0) - inset - itemSize / 2, 0), CGFloat(providers.count - 1) * (itemSize + spacing))
                : CGFloat(index) * (itemSize + spacing)
            LensShape(tint: tint, pressed: pressed, namespace: namespace)
                .frame(width: itemSize, height: itemSize)
                .scaleEffect(pressed ? 1.25 : 1)
                .offset(x: x)
                .animation(pressed ? .interactiveSpring(response: 0.2, dampingFraction: 0.8)
                                   : .spring(response: 0.35, dampingFraction: 0.75), value: x)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { dragX = $0.location.x }
            .onEnded { value in
                select(index(at: value.location.x))
                dragX = nil
            }
    }

    private func index(at x: CGFloat) -> Int {
        let position = (x - inset) / (itemSize + spacing)
        return min(max(Int(position.rounded(.down)), 0), providers.count - 1)
    }

    private func select(_ index: Int) {
        guard providers.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            onSelect(providers[index].identityKey)
        }
    }

    /// 1, 2, 3… among the accounts of this one's provider; nil when it has only one.
    private func accountNumber(at index: Int) -> Int? {
        let id = providers[index].id
        guard providers.filter({ $0.id == id }).count > 1 else { return nil }
        return providers[...index].filter { $0.id == id }.count
    }
}

/// The selection highlight. On OS 26 it's glass itself, tinted at rest and
/// clear while pressed, so it refracts the icons it passes over.
private struct LensShape: View {
    let tint: Color
    let pressed: Bool
    let namespace: Namespace.ID

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Color.clear
                .glassEffect(pressed ? .clear.interactive() : .regular.tint(tint.opacity(0.35)).interactive(),
                             in: Circle())
                .glassEffectID("lens", in: namespace)
        } else {
            Circle().fill(tint.opacity(pressed ? 0.12 : 0.2))
        }
    }
}

private struct ProviderBarItem: View {
    let provider: ProviderUsage
    let number: Int?
    let isFocused: Bool
    let size: CGFloat

    private var tint: Color { UsageFormat.providerTint(provider.id) }
    private var hasProblem: Bool { !provider.isOK && !provider.isNoPlan }

    var body: some View {
        ProviderLogo(providerID: provider.id)
            .frame(width: size * 0.52, height: size * 0.52)
            .foregroundStyle(isFocused ? tint : .secondary)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let number {
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(tint, in: Circle())
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasProblem {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .help(accessibilityLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var parts = [provider.name]
        if let number { parts.append("account \(number)") }
        if let account = provider.account { parts.append(account) }
        if hasProblem { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}

/// Interactive Liquid Glass from iOS and macOS 26, inside a container so the
/// lens and the bar blend; a material capsule before that.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

// MARK: - Sections below the limits

/// The split by product, cost at API rates and token stats for one
/// provider account, each in its own card.
struct ProviderInsightSections: View {
    let provider: ProviderUsage

    private var tint: Color { UsageFormat.providerTint(provider.id) }

    var body: some View {
        if let weekly = provider.breakdown, weekly.rows.contains(where: { $0.percent > 0 }) {
            DashboardSection(title: "Usage by product") {
                BreakdownView(breakdown: weekly, tint: tint, title: "This week")
            }
        }
        if let cost = provider.apiCost {
            APICostSection(cost: cost, tint: tint)
            TokenStatsSection(cost: cost, tint: tint)
        }
    }
}

/// A titled card, with an optional control (a range picker) under the title.
struct DashboardSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            accessory
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

extension DashboardSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// The card behind each dashboard section.
    func dashboardCard() -> some View {
        #if os(iOS)
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #else
        background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        #endif
    }
}

private struct RangePicker: View {
    @Binding var range: APICostRange

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(APICostRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Usage by product

/// Where a window's usage went, e.g. Claude's week split across Claude Code,
/// Chats and Cowork: one segmented bar, largest share first, with a legend.
struct BreakdownView: View {
    let breakdown: UsageBreakdown
    let tint: Color
    /// Replaces the breakdown's own title, e.g. "This week" under a section heading.
    var title: String?

    private var rows: [BreakdownRow] {
        breakdown.rows
            .filter { $0.percent > 0 }
            .sorted { $0.percent > $1.percent }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 8) {
            Text(title ?? breakdown.title)
                .font(.subheadline.weight(.semibold))
            segments(rows)
            legend(rows)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let asOf = breakdown.asOf {
                Text("As of \(asOf, format: .relative(presentation: .named))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? breakdown.title)
        .accessibilityValue(rows.map { "\($0.label) \(UsageFormat.percent($0.percent))" }.joined(separator: ", "))
    }

    private static let gap: CGFloat = 2

    private func segments(_ rows: [BreakdownRow]) -> some View {
        let total = rows.reduce(0) { $0 + $1.percent }
        return GeometryReader { geo in
            let available = max(geo.size.width - Self.gap * CGFloat(rows.count - 1), 0)
            HStack(spacing: Self.gap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle()
                        .fill(tint.opacity(Self.opacity(at: index)))
                        .frame(width: max(available * CGFloat(row.percent / total), 2))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    /// "● Claude Code 93%   ● Cowork 7%", each dot matching its segment.
    private func legend(_ rows: [BreakdownRow]) -> Text {
        rows.enumerated().reduce(Text(verbatim: "")) { legend, item in
            let (index, row) = item
            let entry = Text(Image(systemName: "circle.fill"))
                .font(.caption2)
                .foregroundStyle(tint.opacity(Self.opacity(at: index)))
                + Text(verbatim: "\u{00A0}\(row.label) \(UsageFormat.percent(row.percent))")
            return index == 0 ? entry : legend + Text(verbatim: "   ") + entry
        }
    }

    /// Full tint for the largest share, fading for the rest.
    private static func opacity(at index: Int) -> Double {
        max(1 - Double(index) * 0.3, 0.2)
    }
}

// MARK: - API cost

private struct APICostSection: View {
    let cost: APICost
    let tint: Color

    @AppStorage("dashboardCostRange") private var range: APICostRange = .week

    var body: some View {
        DashboardSection(title: "At standard API rates") {
            RangePicker(range: $range)
        } content: {
            if let period = cost.period(range) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(period.priced > 0 || period.usd > 0 ? UsageFormat.usd(period.usd) : "—")
                            .font(.largeTitle.weight(.bold))
                            .monospacedDigit()
                        Text(cost.rangeText(range))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    let priced = (period.models ?? []).filter { ($0.usd ?? 0) > 0 }.sorted { ($0.usd ?? 0) > ($1.usd ?? 0) }
                    if !priced.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(priced.prefix(5)) { model in
                                ShareRow(label: model.model, value: UsageFormat.usd(model.usd ?? 0),
                                         share: (model.usd ?? 0) / max(period.usd, .ulpOfOne), tint: tint)
                            }
                        }
                    }
                    Text(caption(period))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                UpdateCompanionNote(range: range)
            }
        }
    }

    private func caption(_ period: APICostPeriod) -> String {
        let machines = cost.machines ?? 1
        let source = machines > 1 ? "CLI tokens from \(machines) computers" : "Local CLI tokens"
        var text = "\(source), priced at standard API rates (October 2026). Not a bill."
        if period.unpriced > 0 {
            text += " \(period.unpriced.formatted()) requests use models without listed prices."
        }
        if let note = cost.estimatedNote(range) { text += " " + note }
        return text
    }
}

// MARK: - Token stats

private struct TokenStatsSection: View {
    let cost: APICost
    let tint: Color

    @AppStorage("dashboardStatsRange") private var range: APICostRange = .week

    var body: some View {
        DashboardSection(title: "Token stats") {
            RangePicker(range: $range)
        } content: {
            if let period = cost.period(range), let tokens = period.tokens {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(UsageFormat.tokens(tokens))
                                .font(.largeTitle.weight(.bold))
                                .monospacedDigit()
                            Text("tokens")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(cost.rangeText(range))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    if let kinds = kinds(period) {
                        grid {
                            ForEach(kinds, id: \.label) { kind in
                                Stat(label: kind.label, value: UsageFormat.tokens(kind.value),
                                     detail: tokens > 0 ? UsageFormat.percent(Double(kind.value) / Double(tokens) * 100) : nil)
                            }
                        }
                    }

                    if period.requests > 0 {
                        grid {
                            Stat(label: "Requests", value: period.requests.formatted(), detail: nil)
                            Stat(label: "Per request", value: UsageFormat.tokens(tokens / period.requests), detail: nil)
                        }
                    }

                    if let models = period.models, !models.isEmpty {
                        Divider()
                        Text("By model")
                            .font(.subheadline.weight(.semibold))
                        VStack(spacing: 8) {
                            ForEach(models.prefix(5)) { model in
                                ShareRow(label: model.model, value: UsageFormat.tokens(model.tokens),
                                         share: Double(model.tokens) / Double(max(tokens, 1)), tint: tint)
                            }
                        }
                    }

                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                UpdateCompanionNote(range: range)
            }
        }
    }

    private var caption: String {
        let machines = cost.machines ?? 1
        var text = machines > 1 ? "Summed across \(machines) computers." : "From this account's local CLI logs."
        if let note = cost.estimatedNote(range) {
            text += " " + note + " Requests count only days with logs."
        }
        return text
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)], spacing: 12, content: content)
    }

    private func kinds(_ period: APICostPeriod) -> [(label: String, value: Int)]? {
        guard let input = period.input, let output = period.output,
              let read = period.cacheRead, let write = period.cacheWrite else { return nil }
        return [("Input", input), ("Output", output), ("Cache read", read), ("Cache write", write)]
    }
}

private extension APICost {
    /// "Last 7 days", or "Since 15 Jul 2026" for all time.
    func rangeText(_ range: APICostRange) -> String {
        if range == .all, let since {
            return "Since \(since.formatted(date: .abbreviated, time: .omitted))"
        }
        return range.longLabel.prefix(1).uppercased() + range.longLabel.dropFirst()
    }

    /// Days before the oldest surviving Claude Code log come from its /stats
    /// history, which keeps one total per model per day.
    func estimatedNote(_ range: APICostRange) -> String? {
        guard range == .all, let estimatedThrough else { return nil }
        let date = estimatedThrough.formatted(date: .abbreviated, time: .omitted)
        return "Through \(date), from Claude Code's /stats history, with the token-type split estimated."
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A label and value over a thin bar showing its share of the total.
private struct ShareRow: View {
    let label: String
    let value: String
    /// 0...1
    let share: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.subheadline)
            GeometryReader { geo in
                Capsule()
                    .fill(tint.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(geo.size.width * min(max(share, 0), 1), 3))
                    }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value), \(UsageFormat.percent(share * 100))")
    }
}

private struct UpdateCompanionNote: View {
    let range: APICostRange

    var body: some View {
        Label("Update the companion on your computers to 2.2 or later to see the \(range.longLabel).",
              systemImage: "arrow.down.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
