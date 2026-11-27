import AppKit
import SwiftUI

/// `--render-icon <path.png> [--scale <n>]`: fetches once, writes a preview
/// sheet of the menu bar icon and exits. Rows: template on a light and a
/// dark menu bar, then colored on both; each row has the combined icon
/// followed by the separate per-provider icons. Uses the saved settings,
/// which can be overridden per run (e.g. `-barMode remaining`).
enum IconPreview {
    @MainActor
    static func run(path: String, scale: CGFloat) -> Never {
        Task { @MainActor in
            let model = CompanionModel(polling: false)
            await model.refresh(includePairing: false)
            let defaults = UserDefaults.standard
            let stacks = model.iconStacks(mode: BarMode(rawValue: defaults.string(forKey: Prefs.barMode) ?? "") ?? .used,
                                          hidden: Prefs.ids(defaults.string(forKey: Prefs.hiddenProviders) ?? ""))
            guard !stacks.isEmpty else {
                FileHandle.standardError.write(Data("No usage to draw (companion state: \(model.state))\n".utf8))
                exit(1)
            }
            let options = IconOptions(showLogos: defaults.bool(forKey: Prefs.showLogos), colored: false,
                                      dimmed: model.state != .online)
            guard let png = sheet(stacks, options: options, scale: scale) else {
                FileHandle.standardError.write(Data("Couldn't render the icon\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            print(path)
            exit(0)
        }
        dispatchMain()
    }

    private static func sheet(_ stacks: [IconStack], options: IconOptions, scale: CGFloat) -> Data? {
        let padding: CGFloat = 8, itemGap: CGFloat = 10, rowHeight: CGFloat = 24
        let separate = stacks.map { [$0] }
        let variants: [(background: NSColor, ink: NSColor, colored: Bool)] = [
            (NSColor(white: 0.93, alpha: 1), .black, false),
            (NSColor(white: 0.16, alpha: 1), .white, false),
            (NSColor(white: 0.93, alpha: 1), .black, true),
            (NSColor(white: 0.16, alpha: 1), .white, true),
        ]
        let items = [stacks] + separate
        let width = padding * 2 + items.map { MenuBarIcon.width(of: $0, options: options) }.reduce(0, +)
            + itemGap * CGFloat(separate.count) + itemGap
        let height = rowHeight * CGFloat(variants.count)
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        for (row, variant) in variants.enumerated() {
            let top = rowHeight * CGFloat(row)
            context.setFillColor(variant.background.cgColor)
            context.fill(CGRect(x: 0, y: top, width: width, height: rowHeight))
            var x = padding
            var rowOptions = options
            rowOptions.colored = variant.colored
            for (index, item) in items.enumerated() {
                context.saveGState()
                context.translateBy(x: x, y: top + (rowHeight - MenuBarIcon.height) / 2)
                MenuBarIcon.draw(item, options: rowOptions, ink: variant.ink, in: context)
                context.restoreGState()
                // A wider gap after the combined icon sets it apart from the separate ones.
                x += MenuBarIcon.width(of: item, options: rowOptions) + (index == 0 ? itemGap * 2 : itemGap)
            }
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// `--render-setup <path.png> <step>`: writes one first-run setup step
/// (welcome, companion, providers, iPhone) with this Mac's detected
/// providers, then exits.
enum SetupPreview {
    @MainActor
    static func run(path: String, step: String, scale: CGFloat) -> Never {
        Task { @MainActor in
            let model = CompanionModel(polling: false)
            await model.refresh()
            let providers = (try? await CompanionCLI.detect()) ?? []
            let setupStep = SetupView.Step.allCases.first { "\($0)".lowercased() == step.lowercased() } ?? .welcome
            let view = SetupView(step: setupStep, preview: (providers, .ready))
                .environmentObject(model)
                .frame(width: 760, height: 680)
                .background(Color(white: 0.95))
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                FileHandle.standardError.write(Data("Couldn't render setup\n".utf8))
                exit(1)
            }
            print(path)
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}

/// `--render-panel <path.png> [--graph] [--dark] [--expand <provider/window>]
/// [--scale <n>]`: fetches once and writes the popover as it would look
/// now, then exits. `--render-window` does the same for the main window's
/// content. `--graph` shows every window as a graph for this run
/// only; `--expand` opens one row's graph in Bars mode.
enum PanelPreview {
    @MainActor
    static func run(path: String, scale: CGFloat, graph: Bool, dark: Bool, expand: String?,
                    window: Bool = false) -> Never {
        if graph {
            // The argument domain lasts for this process only.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[Prefs.panelStyle] = UsageStyle.graph.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Task { @MainActor in
            let model = CompanionModel(polling: false)
            if let expand { model.toggleExpanded(expand) }
            await model.refresh()
            let now = Date.now
            let content: AnyView = window
                ? AnyView(DashboardView(snapshotDate: now).frame(width: 760))
                : AnyView(PanelView(snapshotDate: now))
            let panel = content
                .environmentObject(model)
                .background(Color(white: dark ? 0.16 : 0.95))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: panel)
            renderer.scale = scale
            var png: Data?
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                png = renderer.cgImage.flatMap {
                    NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
                }
            }
            guard let png else {
                FileHandle.standardError.write(Data("Couldn't render the panel\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            print(path)
            exit(0)
        }
        // Not dispatchMain(): SwiftUI renders on the main thread itself,
        // which dispatchMain() parks.
        RunLoop.main.run()
        exit(0)
    }
}

/// `--render-machines <path.png> [--machine local|<name>] [--scale <n>] [--dark]`: writes the
/// Settings > Machines page (the list, or one machine's Devices tab) as it looks now, then exits.
/// It draws the real view in an offscreen window, so it works while the screen is locked. With
/// `$METERKAT_OWNER_LINK` set it first adds that machine, as the Add machine sheet would, and with
/// `$METERKAT_REVOKE_DEVICE` (a device name) it revokes that device on `--machine` first, through the
/// same call as the Revoke button. Both exist so the page can be exercised without clicking.
enum MachinesPreview {
    @MainActor
    static func run(path: String, machine: String?, scale: CGFloat, dark: Bool) -> Never {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Task { @MainActor in
            let machines = MachinesModel()
            if let link = ProcessInfo.processInfo.environment["METERKAT_OWNER_LINK"], !link.isEmpty {
                do {
                    try await machines.add(link: link)
                } catch {
                    FileHandle.standardError.write(Data("Couldn't add the machine: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            await machines.refreshAll()
            var selected: String?
            if let machine {
                selected = machine == "local" ? MachinesModel.localID
                    : machines.machines.first { $0.name.lowercased() == machine.lowercased() }?.id.uuidString
                if selected == nil {
                    FileHandle.standardError.write(Data("No machine named \(machine)\n".utf8))
                    exit(1)
                }
            }
            if let name = ProcessInfo.processInfo.environment["METERKAT_REVOKE_DEVICE"], !name.isEmpty {
                guard let selected,
                      let device = machines.status(for: selected).devices?.devices.first(where: { $0.name == name })
                else {
                    FileHandle.standardError.write(Data("No device named \(name) on that machine\n".utf8))
                    exit(1)
                }
                do {
                    try await machines.revoke(device, on: selected)
                    FileHandle.standardError.write(Data("Revoked \(device.name) (\(device.id))\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("Revoke failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            let size = NSSize(width: 540, height: 560)
            let hosting = NSHostingView(rootView: MachinesSettings(selected: selected)
                .environmentObject(machines).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderBack(nil)
            try? await Task.sleep(for: .seconds(2))  // the list and statuses lay out asynchronously
            hosting.layoutSubtreeIfNeeded()
            let pixels = NSSize(width: size.width * scale, height: size.height * scale)
            guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
            rep.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                FileHandle.standardError.write(Data("Couldn't render the machines page\n".utf8))
                exit(1)
            }
            print(path)
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
