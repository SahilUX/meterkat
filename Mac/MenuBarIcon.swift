import AppKit
import SwiftUI

// MARK: - Preferences

/// One menu bar item for all providers, or one per provider.
enum IconStyle: String, CaseIterable, Identifiable {
    case combined
    case separate

    var id: String { rawValue }
    var label: String { self == .combined ? "Combined" : "Separate" }
}

/// UserDefaults keys for the app's settings.
enum Prefs {
    /// Where the app shows up. Settings keeps at least one of them on.
    static let showInMenuBar = "showInMenuBar"
    static let showInDock = "showInDock"
    /// Setup (installing the companion, choosing providers) has finished
    /// or was put off.
    static let setupDone = "setupDone"
    static let iconStyle = "menuBarIconStyle"
    static let showLogos = "menuBarShowLogos"
    static let colored = "menuBarColored"
    static let barMode = "barMode"
    static let panelStyle = "panelStyle"
    /// Comma-separated ids of providers left out of the menu bar, so
    /// providers added by a newer companion show up by default.
    static let hiddenProviders = "menuBarHiddenProviders"

    /// The swiftc-built "AI Usage Companion" app (up to 1.4) kept these
    /// settings under its own bundle id.
    private static let legacyDomain = "com.sahil627y9r.aiusage.companion"
    private static let migratedKey = "migratedLegacyPrefs"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showInMenuBar: true,
            showInDock: true,
            iconStyle: IconStyle.combined.rawValue,
            showLogos: true,
            colored: false,
            barMode: BarMode.used.rawValue,
            panelStyle: UsageStyle.bars.rawValue,
            hiddenProviders: "",
        ])
        migrateLegacy()
    }

    /// Copies the old app's menu bar settings once, so they survive the move.
    private static func migrateLegacy() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else { return }
        for key in [iconStyle, showLogos, colored, barMode, panelStyle, hiddenProviders] {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
    }

    static func ids(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func raw(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}

// MARK: - Menu bar icon

/// One provider's bars in the menu bar icon, top to bottom.
struct IconStack {
    struct Bar {
        var fill: Double      // 0...1, already adjusted for the bar mode
        var marker: Double?   // 0...1, already adjusted for the bar mode
    }

    var providerID: String
    var bars: [Bar]
}

struct IconOptions {
    var showLogos: Bool
    var colored: Bool
    /// Data is stale (companion offline or failing).
    var dimmed: Bool
}

/// Draws the menu bar icon: for each provider an optional logo and a stack
/// of thin bars, one per window. The time marker is a 1pt notch through the
/// fill, or a solid tick when it sits on the track past the fill.
enum MenuBarIcon {
    static let height: CGFloat = 18
    static let barWidth: CGFloat = 26
    static let barGap: CGFloat = 2
    static let logoSize: CGFloat = 12
    static let logoGap: CGFloat = 3
    static let stackGap: CGFloat = 8
    static let trackAlpha: CGFloat = 0.3

    static func width(of stacks: [IconStack], options: IconOptions) -> CGFloat {
        let stackWidth = barWidth + (options.showLogos ? logoSize + logoGap : 0)
        return CGFloat(stacks.count) * stackWidth + CGFloat(max(stacks.count - 1, 0)) * stackGap
    }

    /// A template image (it follows the menu bar's light/dark appearance)
    /// unless `options.colored`; nil when there's nothing to show.
    static func image(for stacks: [IconStack], options: IconOptions) -> NSImage? {
        guard !stacks.isEmpty else { return nil }
        let size = NSSize(width: width(of: stacks, options: options), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(stacks, options: options, ink: .black, in: context)
            return true
        }
        image.isTemplate = !options.colored
        image.accessibilityDescription = "Meterkat"
        return image
    }

    /// Draws at the origin of a y-down context. `ink` is the color of an
    /// uncolored (template) icon.
    static func draw(_ stacks: [IconStack], options: IconOptions, ink: NSColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if options.dimmed { context.setAlpha(0.5) }
        var x: CGFloat = 0
        for stack in stacks {
            let color = (options.colored ? NSColor(UsageFormat.providerTint(stack.providerID)) : ink).cgColor
            if options.showLogos {
                let rect = CGRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize)
                context.addPath(ProviderLogoShape(providerID: stack.providerID).path(in: rect).cgPath)
                context.setFillColor(color)
                context.fillPath()
                x += logoSize + logoGap
            }
            drawStack(stack.bars, x: x, color: color, in: context)
            x += barWidth + stackGap
        }
    }

    private static func drawStack(_ bars: [IconStack.Bar], x: CGFloat, color: CGColor, in context: CGContext) {
        // Fewer bars get a little thicker; whole points keep them crisp at 1x.
        let barHeight: CGFloat = bars.count > 2 ? 3 : 4
        let total = CGFloat(bars.count) * barHeight + CGFloat(bars.count - 1) * barGap
        var y = ((height - total) / 2).rounded(.down)
        for bar in bars {
            drawBar(bar, in: CGRect(x: x, y: y, width: barWidth, height: barHeight), color: color, context: context)
            y += barHeight + barGap
        }
    }

    private static func drawBar(_ bar: IconStack.Bar, in rect: CGRect, color: CGColor, context: CGContext) {
        let fill = min(max(bar.fill, 0), 1)
        let fillWidth = fill > 0 ? max((rect.width * fill).rounded(), 2) : 0
        let fillEnd = rect.minX + fillWidth
        let marker = bar.marker.map { position -> CGRect in
            let x = markerOffset(position, fillWidth: fillWidth, barWidth: rect.width)
            return CGRect(x: rect.minX + x, y: rect.minY, width: 1, height: rect.height)
        }

        context.saveGState()
        defer { context.restoreGState() }
        let radius = rect.height / 2
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        if let marker, marker.minX < fillEnd {
            let notched = CGMutablePath()
            notched.addRect(rect)
            notched.addRect(marker)
            context.addPath(notched)
            context.clip(using: .evenOdd)
        }
        context.setFillColor(color.copy(alpha: color.alpha * trackAlpha) ?? color)
        context.fill(rect)
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: fillEnd - rect.minX, height: rect.height))
        if let marker, marker.minX >= fillEnd {
            context.fill(marker)
        }
    }

    /// The marker's x in points from the bar's left edge. On the fill's last
    /// point or the track's first it would merge into the end of the fill,
    /// so it moves a point to keep fill (notch) or track (tick) on both sides.
    private static func markerOffset(_ position: Double, fillWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        let x = min(max((barWidth * position).rounded(.down), 1), barWidth - 2)
        let notch = fillWidth - 2, tick = fillWidth + 1
        guard x > notch, x < tick else { return x }
        if x == fillWidth - 1 {
            return notch >= 1 ? notch : tick
        }
        return tick <= barWidth - 2 ? tick : notch
    }
}
