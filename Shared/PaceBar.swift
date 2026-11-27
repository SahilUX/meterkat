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

    init(fill: Double, marker: Double?, tint: Color, height: CGFloat = 8, style: MarkerStyle = .prominent) {
        self.fill = fill
        self.marker = marker
        self.tint = tint
        self.height = height
        self.style = style
    }

    /// Bar for a usage window in the given mode.
    init(window: UsageWindow, mode: BarMode, tint: Color, at date: Date = .now,
         height: CGFloat = 8, style: MarkerStyle = .prominent) {
        let values = window.barValues(mode: mode, at: date)
        self.init(fill: values.fill, marker: values.marker, tint: tint, height: height, style: style)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = width * CGFloat(min(max(fill, 0), 100) / 100)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(height: height)
                Capsule()
                    .fill(tint)
                    .frame(width: fill > 0 ? max(filled, height) : 0, height: height)
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
        .accessibilityLabel("\(Int(fill.rounded())) percent")
        .accessibilityValue(marker.map { "Time marker at \(Int(($0 * 100).rounded())) percent" } ?? "")
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
    }
    .padding()
    .background(Color.black)
}
