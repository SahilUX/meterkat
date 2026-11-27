import SwiftUI

/// Provider logo drawn from SVG path data, so it scales crisply, tints like
/// text (`foregroundStyle`) and works as a template on the Lock Screen and in
/// the macOS menu bar. Unknown providers fall back to an SF Symbol.
///
/// Also compiled into the macOS menu bar app, so this file must stay
/// self-contained: SwiftUI and CoreGraphics only, no UIKit/AppKit and no
/// types from the other Shared files.
struct ProviderLogo: View {
    var providerID: String

    var body: some View {
        if let name = ProviderLogoShape.name(for: providerID) {
            ProviderLogoShape(providerID: providerID)
                .fill(style: FillStyle(eoFill: false))
                .aspectRatio(1, contentMode: .fit)
                .accessibilityElement()
                .accessibilityLabel(name)
        } else {
            Image(systemName: "sparkle")
                .resizable()
                .scaledToFit()
                .accessibilityLabel(providerID)
        }
    }
}

/// The logo as a `Shape`, for drawing into paths (e.g. menu bar images).
/// The 24×24 artwork is scaled to fit the rect and centered. Fill it with the
/// default non-zero rule. Unknown providers draw a circle.
struct ProviderLogoShape: Shape {
    var providerID: String

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }
        guard let logo = Self.paths[providerID.lowercased()] else {
            return Path(ellipseIn: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                          width: side, height: side))
        }
        let scale = side / Self.viewBoxSize
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return logo.applying(transform)
    }

    /// Display name for a provider that has a logo, nil otherwise.
    static func name(for providerID: String) -> String? {
        artwork[providerID.lowercased()]?.name
    }

    private static let viewBoxSize: CGFloat = 24

    /// Parsed once, in 24×24 viewBox coordinates.
    private static let paths: [String: Path] = artwork.mapValues { SVGPathParser.path(from: $0.pathData) }

    /// Brand marks from simple-icons (CC0), keyed by provider id; Z.ai isn't
    /// there, so it gets a lettermark. Each is the single `<path d>` of a
    /// `viewBox="0 0 24 24"` icon.
    private static let artwork: [String: (name: String, pathData: String)] = [
        "claude": ("Claude", """
            m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971\
            -2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514\
            .0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714\
            -.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893\
             1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194\
            c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282\
             1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589\
            .3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429\
            -.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625\
             1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157\
            .8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618\
            .0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279\
            h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575\
            -.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679\
            -.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071\
            -.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182\
            -1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357\
             1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307\
            -.2429 1.9064-1.3114Z
            """),
        "openai": ("OpenAI", """
            M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0\
             4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511\
             4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718\
            -4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755\
             4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02\
             1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708\
             0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804\
             0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1\
             2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071\
             0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757\
             0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107\
            -3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1\
             .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1\
            -.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927\
            .6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z
            """),
        "opencode": ("OpenCode", "M22 24H2V0h20zM17 4.8H7v14.4h10z"),
        "openrouter": ("OpenRouter", """
            M16.778 1.844v1.919q-.569-.026-1.138-.032-.708-.008-1.415.037c-1.93.126-4.023.728-6.149 2.237-2.911\
             2.066-2.731 1.95-4.14 2.75-.396.223-1.342.574-2.185.798-.841.225-1.753.333-1.751.333v4.229s.768.108\
             1.61.333c.842.224 1.789.575 2.185.799 1.41.798 1.228.683 4.14 2.75 2.126 1.509 4.22 2.11 6.148 2.236\
            .88.058 1.716.041 2.555.005v1.918l7.222-4.168-7.222-4.17v2.176c-.86.038-1.611.065-2.278.021-1.364-.09\
            -2.417-.357-3.979-1.465-2.244-1.593-2.866-2.027-3.68-2.508.889-.518 1.449-.906 3.822-2.59 1.56-1.109\
             2.614-1.377 3.978-1.466.667-.044 1.418-.017 2.278.02v2.176L24 6.014Z
            """),
        "copilot": ("Copilot", """
            M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1\
             0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644\
            -1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255\
             2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132\
             2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605\
             2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1\
            -.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104\
            L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045\
            -.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508\
            Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549\
             0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403\
             1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558\
            -2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529\
            -.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02\
            c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462\
            .472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394\
             2.344-.938.475-.584.742-1.44.878-2.497Z
            """),
        "gemini": ("Gemini", """
            M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68\
            -.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55\
             3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81
            """),
        "cursor": ("Cursor", """
            M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998\
             0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996\
             0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59\
             0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23
            """),
        // Not in simple-icons: a bold "Z" lettermark drawn to the same box.
        "zai": ("Z.ai", "M3 2.5h18v3.9L9.3 17.6H21v3.9H3v-3.9L14.7 6.4H3Z"),
        // Lettermark fallback for Kimi.
        "kimi": ("Moonshot Kimi", "M3 3h4v7l6-7h6l-8 9 8 9h-6l-6-7v7H3Z"),
        "minimax": ("MiniMax", "M2 4h4l3 8 3-8h4v16h-4v-8l-3 7-3-7v8H2Zm16 0h4v16h-4Z"),
        "bailian": ("Alibaba Coding Plan", "M12 2 2 22h5l5-11 5 11h5Z"),
        "deepseek": ("DeepSeek API", "M12 2 2 22h4l6-10 6 10h4L12 2Zm0 8 3 5h-6Z"),
    ]
}

/// Converts SVG path data (the `d` attribute) to a `Path`. Supports every
/// command, absolute and relative, with the compact number syntax SVG allows
/// ("-.5.5", "1e-3", packed arc flags like "a1 1 0 00-1 1"). Elliptical arcs
/// become cubic Béziers. Parsing stops at the first malformed token and keeps
/// what was drawn so far, as the SVG spec's error handling does.
private struct SVGPathParser {
    private let bytes: [UInt8]
    private var index = 0

    private var path = Path()
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    /// Set after `Z`: the next drawing command starts a new subpath there.
    private var needsMove = false
    /// Second control point of the previous C/S, for reflecting in S.
    private var lastCubicControl: CGPoint?
    /// Control point of the previous Q/T, for reflecting in T.
    private var lastQuadControl: CGPoint?

    static func path(from data: String) -> Path {
        var parser = SVGPathParser(bytes: Array(data.utf8))
        parser.parse()
        return parser.path
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Commands

    private mutating func parse() {
        var command: UInt8?
        while true {
            skipSeparators()
            guard index < bytes.count else { return }
            if isLetter(bytes[index]) {
                command = bytes[index]
                index += 1
            } else if command == nil || !atNumber() {
                return
            }
            guard let active = command, perform(active) else { return }
            switch active {
            // Coordinates after a moveto are implicit linetos.
            case UInt8(ascii: "M"): command = UInt8(ascii: "L")
            case UInt8(ascii: "m"): command = UInt8(ascii: "l")
            // Closepath takes no arguments, so a number after it is an error.
            case UInt8(ascii: "Z"), UInt8(ascii: "z"): command = nil
            default: break
            }
        }
    }

    /// Reads one command's arguments and draws it. False on malformed data.
    private mutating func perform(_ command: UInt8) -> Bool {
        let relative = command >= UInt8(ascii: "a")
        let origin = relative ? current : .zero
        var cubicControl: CGPoint?
        var quadControl: CGPoint?

        switch command | 0x20 { // lowercased
        case UInt8(ascii: "m"):
            guard let point = point(relativeTo: origin) else { return false }
            path.move(to: point)
            current = point
            subpathStart = point
            needsMove = false

        case UInt8(ascii: "l"):
            guard let point = point(relativeTo: origin) else { return false }
            line(to: point)

        case UInt8(ascii: "h"):
            guard let x = number() else { return false }
            line(to: CGPoint(x: origin.x + x, y: current.y))

        case UInt8(ascii: "v"):
            guard let y = number() else { return false }
            line(to: CGPoint(x: current.x, y: origin.y + y))

        case UInt8(ascii: "c"):
            guard let control1 = point(relativeTo: origin),
                  let control2 = point(relativeTo: origin),
                  let end = point(relativeTo: origin) else { return false }
            curve(to: end, control1: control1, control2: control2)
            cubicControl = control2

        case UInt8(ascii: "s"):
            guard let control2 = point(relativeTo: origin),
                  let end = point(relativeTo: origin) else { return false }
            let control1 = reflected(lastCubicControl)
            curve(to: end, control1: control1, control2: control2)
            cubicControl = control2

        case UInt8(ascii: "q"):
            guard let control = point(relativeTo: origin),
                  let end = point(relativeTo: origin) else { return false }
            quadCurve(to: end, control: control)
            quadControl = control

        case UInt8(ascii: "t"):
            guard let end = point(relativeTo: origin) else { return false }
            let control = reflected(lastQuadControl)
            quadCurve(to: end, control: control)
            quadControl = control

        case UInt8(ascii: "a"):
            guard let rx = number(), let ry = number(), let rotation = number(),
                  let largeArc = flag(), let sweep = flag(),
                  let end = point(relativeTo: origin) else { return false }
            arc(to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)

        case UInt8(ascii: "z"):
            path.closeSubpath()
            current = subpathStart
            needsMove = true

        default:
            return false
        }

        lastCubicControl = cubicControl
        lastQuadControl = quadControl
        return true
    }

    private func reflected(_ control: CGPoint?) -> CGPoint {
        guard let control else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    // MARK: Drawing

    private mutating func startSubpathIfNeeded() {
        if needsMove {
            path.move(to: current)
            needsMove = false
        }
    }

    private mutating func line(to point: CGPoint) {
        startSubpathIfNeeded()
        path.addLine(to: point)
        current = point
    }

    private mutating func curve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        startSubpathIfNeeded()
        path.addCurve(to: end, control1: control1, control2: control2)
        current = end
    }

    private mutating func quadCurve(to end: CGPoint, control: CGPoint) {
        startSubpathIfNeeded()
        path.addQuadCurve(to: end, control: control)
        current = end
    }

    /// Elliptical arc as cubic Béziers, via the endpoint-to-center conversion
    /// in SVG 1.1 appendix F.6.5, with out-of-range radii scaled up (F.6.6).
    private mutating func arc(to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                              largeArc: Bool, sweep: Bool) {
        let start = current
        if start == end { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else {
            line(to: end)
            return
        }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // Step 1: the start point in the ellipse's rotated frame, relative to the chord midpoint.
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Radii too small to reach the end point grow until they just do.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }

        // Step 2: the center in the rotated frame.
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let coefficient = sign * max(numerator / denominator, 0).squareRoot()
        let cxPrime = coefficient * rx * y1 / ry
        let cyPrime = -coefficient * ry * x1 / rx

        // Step 3: the center in user space.
        let center = CGPoint(x: cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2,
                             y: sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2)

        // Step 4: start angle and sweep on the unit circle.
        let startAngle = atan2((y1 - cyPrime) / ry, (x1 - cxPrime) / rx)
        let endAngle = atan2((-y1 - cyPrime) / ry, (-x1 - cxPrime) / rx)
        var delta = endAngle - startAngle
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }

        // At most a quarter turn per Bézier keeps the approximation tight.
        let segments = max(Int((abs(delta) / (.pi / 2)).rounded(.up)), 1)
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)

        func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * x - ry * sinPhi * y,
                    y: center.y + rx * sinPhi * x + ry * cosPhi * y)
        }

        var angle = startAngle
        for segment in 1...segments {
            let next = angle + step
            let control1 = mapped(cos(angle) - handle * sin(angle), sin(angle) + handle * cos(angle))
            let control2 = mapped(cos(next) + handle * sin(next), sin(next) - handle * cos(next))
            let point = segment == segments ? end : mapped(cos(next), sin(next))
            curve(to: point, control1: control1, control2: control2)
            angle = next
        }
    }

    // MARK: Tokens

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
            && (byte | 0x20) != UInt8(ascii: "e")
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func skipSeparators() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: ","), UInt8(ascii: "\t"),
                 UInt8(ascii: "\n"), UInt8(ascii: "\r"), 0x0C:
                index += 1
            default:
                return
            }
        }
    }

    private func atNumber() -> Bool {
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        return isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
    }

    private mutating func point(relativeTo origin: CGPoint) -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }

    /// One number: optional sign, digits with at most one point, optional
    /// exponent. A second point or a sign ends it, so "-.5.5" is two numbers.
    private mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        var digits = 0
        while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
        }
        guard digits > 0 else {
            index = start
            return nil
        }
        if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
            var exponentEnd = index + 1
            if exponentEnd < bytes.count, bytes[exponentEnd] == UInt8(ascii: "-") || bytes[exponentEnd] == UInt8(ascii: "+") {
                exponentEnd += 1
            }
            if exponentEnd < bytes.count, isDigit(bytes[exponentEnd]) {
                index = exponentEnd
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .ascii),
              let value = Double(text) else {
            index = start
            return nil
        }
        return CGFloat(value)
    }

    /// An arc flag: a single "0" or "1", which may touch the next token.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }
}
