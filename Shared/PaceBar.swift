import SwiftUI

/// Usage bar with a line at how much of the window has elapsed: 2.5h into a
/// 5-hour window puts the line halfway. In `.used` mode, fill past the line
/// means usage is running ahead of an even pace. In `.remaining` mode the
/// bar shows what's left and the line shows the time left, so fill short of
/// the line means the same thing.
struct PaceBar: View {
    enum MarkerStyle {
        /// Tall line with a contrasting outline, for the app and menu bar.
        case prominent
        /// Thin line with a 1 pt gap cut on each side, for widgets and other
        /// tight spaces. The gap keeps it visible over a fill of the same
        /// color, as on the Lock Screen.
        case thin
    }

    /// Fill, 0...100, already adjusted for the bar mode.
    var fill: Double
    /// Marker position, 0...1, already adjusted for the bar mode. Nil hides it.
    var marker: Double?
    var tint: Color
    var height: CGFloat = 8
    var style: MarkerStyle = .prominent
    /// Where the fill is projected to end at the reset, 0...100 in the same
    /// scale as `fill`. Set only for a window that will run out early: the
    /// stretch between `fill` and this value is shaded orange. Nil draws nothing.
    var projectedFill: Double?

    init(fill: Double, marker: Double?, tint: Color, height: CGFloat = 8, style: MarkerStyle = .prominent,
         projectedFill: Double? = nil) {
        self.fill = fill
        self.marker = marker
        self.tint = tint
        self.height = height
        self.style = style
        self.projectedFill = projectedFill
    }

    /// Bar for a usage window in the given mode. Pass its projection to
    /// shade the stretch that will be used up before the reset.
    init(window: UsageWindow, mode: BarMode, tint: Color, at date: Date = .now,
         height: CGFloat = 8, style: MarkerStyle = .prominent, projection: UsageProjection? = nil) {
        let values = window.barValues(mode: mode, at: date)
        self.init(fill: values.fill, marker: values.marker, tint: tint, height: height, style: style,
                  projectedFill: projection?.barProjectedFill(mode: mode))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = width * CGFloat(min(max(fill, 0), 100) / 100)
            let projected = projectedSpan(width: width, filled: filled)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(height: height)
                // `.used` grows toward the projection, so the stretch sits
                // behind the fill's rounded end; `.remaining` drains into it,
                // so it tints the part of the fill that will be used up.
                if let projected, projected.behindFill { projectedStretch(projected, width: width) }
                Capsule()
                    .fill(tint)
                    .frame(width: fill > 0 ? max(filled, height) : 0, height: height)
                if let projected, !projected.behindFill { projectedStretch(projected, width: width) }
                if let marker {
                    markerLine
                        .position(x: min(max(width * CGFloat(marker), lineWidth / 2), width - lineWidth / 2),
                                  y: geo.size.height / 2)
                }
            }
            .frame(width: width, height: geo.size.height)
            // Confines the thin marker's cut-out to the bar.
            .compositingGroup()
        }
        .frame(height: lineHeight)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fill.rounded())) percent" + (projectedFill == nil ? "" : ", projected to run out early"))
        .accessibilityValue(marker.map { "Time marker at \(Int(($0 * 100).rounded())) percent" } ?? "")
    }

    private struct ProjectedSpan {
        var start: CGFloat
        var end: CGFloat
        /// Drawn under the fill (it grows toward the stretch) rather than over it.
        var behindFill: Bool
    }

    /// The shaded stretch's horizontal extent, in points.
    private func projectedSpan(width: CGFloat, filled: CGFloat) -> ProjectedSpan? {
        guard let projectedFill else { return nil }
        let end = width * CGFloat(min(max(projectedFill, 0), 100) / 100)
        guard abs(end - filled) > 0.5 else { return nil }
        // Start half a bar under the fill's round cap so no sliver of track shows between them.
        if end > filled { return ProjectedSpan(start: max(filled - height / 2, 0), end: end, behindFill: true) }
        return ProjectedSpan(start: end, end: filled, behindFill: false)
    }

    private func projectedStretch(_ span: ProjectedSpan, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: span.start)
            Color.orange.opacity(0.25).frame(width: span.end - span.start)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
    }

    private var lineWidth: CGFloat { style == .prominent ? 3 : 2 }
    private var lineHeight: CGFloat { style == .prominent ? height * 2.2 : max(height * 1.8, 9) }

    @ViewBuilder
    private var markerLine: some View {
        switch style {
        case .prominent:
            Capsule()
                .fill(Color.primary)
                .overlay(Capsule().stroke(Color(white: 0, opacity: 0.35), lineWidth: 0.5))
                .frame(width: lineWidth, height: lineHeight)
        case .thin:
            Capsule()
                .fill(Color.primary)
                .frame(width: lineWidth, height: lineHeight)
                .background(
                    Capsule()
                        .frame(width: lineWidth + 2, height: lineHeight)
                        .blendMode(.destinationOut)
                )
        }
    }
}

extension PaceBar {
    /// Transitional initializer kept for existing call sites.
    init(percent: Double, elapsed: Double?, tint: Color, height: CGFloat = 8, showsKnob: Bool = true) {
        self.init(fill: percent, marker: elapsed, tint: tint, height: height, style: showsKnob ? .prominent : .thin)
    }
}

#Preview {
    let window = UsageWindow(id: "five_hour", kind: "session", label: "5-hour", percent: 32,
                             resetsAt: .now.addingTimeInterval(3 * 3600), windowSeconds: 18_000)
    return VStack(spacing: 24) {
        PaceBar(window: window, mode: .used, tint: UsageFormat.providerTint("claude"))
        PaceBar(window: window, mode: .remaining, tint: UsageFormat.providerTint("claude"))
        PaceBar(window: window, mode: .used, tint: UsageFormat.providerTint("openai"), height: 5, style: .thin)
        PaceBar(fill: 75, marker: 0.62, tint: UsageFormat.providerTint("claude"), projectedFill: 100)
        PaceBar(fill: 25, marker: 0.38, tint: UsageFormat.providerTint("claude"), projectedFill: 0)
    }
    .padding()
    .background(Color.black)
}
