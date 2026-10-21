import AppKit

/// Offline rendering of the production view. No controller, settings, or runtime data.
@MainActor private final class PreviewActions: NSObject {
    @objc func noAction() {}
}

@main struct StatusWindowPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected artifact directory and DropMark path") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mark = NSImage(contentsOfFile: CommandLine.arguments[2])
        let target = PreviewActions(), noop = #selector(PreviewActions.noAction)
        let actions = StatusWindowView.Actions(start: noop, stop: noop, pair: noop, accessibility: noop,
            project: noop, log: noop, login: noop, loginSettings: noop, close: noop, quit: noop)
        let scenarios: [(String, String, CGFloat, CGFloat, Bool, Bool, CGFloat)] = [
            ("running-light", "light", 440, 550, true, true, 1),
            ("running-dark", "dark", 440, 550, true, true, 1),
            ("stopped-light", "light", 440, 550, false, true, 1),
            ("permission-dark", "dark", 440, 550, true, false, 1),
            ("narrow-light", "light", 410, 550, true, false, 1),
            ("baseline-size-light", "light", 410, 455, true, true, 1),
            ("short-dark", "dark", 410, 350, true, false, 1),
            ("large-light", "light", 510, 640, true, false, 1.35),
            ("large-compact-dark", "dark", 410, 350, false, false, 1.35)
        ]
        var report: [[String: Any]] = []
        for (name, mode, width, height, running, trusted, scale) in scenarios {
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = StatusWindowView(target: target, actions: actions, mark: mark)
            view.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            view.status.stringValue = running ? "Receiver running · same Wi-Fi" : "Receiver stopped"
            view.status.textColor = running ? .labelColor : .secondaryLabelColor
            view.accessibility.stringValue = trusted ? "Accessibility: allowed" : "Accessibility: permission needed"
            view.start.isEnabled = !running; view.stop.isEnabled = running; view.pair.isEnabled = running
            view.login.state = .on
            func descendants(_ current: NSView) -> [NSView] { [current] + current.subviews.flatMap(descendants) }
            if scale != 1 {
                for child in descendants(view) {
                    if let label = child as? NSTextField, let font = label.font {
                        label.font = .systemFont(ofSize: font.pointSize * scale, weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)
                    }
                    if let button = child as? NSButton, let font = button.font {
                        button.font = .systemFont(ofSize: font.pointSize * scale)
                    }
                }
            }
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            func capture(_ suffix: String = "") throws {
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + suffix + ".png"))
            }
            try capture()
            let buttons = descendants(view).compactMap { $0 as? NSButton }
            let scroll = descendants(view).compactMap { $0 as? NSScrollView }.first!
            let document = scroll.documentView!
            var controls: [[String: Any]] = []
            for button in buttons {
                let bounds = button.convert(button.bounds, to: document)
                // The scroll document must include all controls; each native button keeps its intrinsic width.
                precondition(bounds.minX >= -0.5 && bounds.maxX <= document.bounds.width + 0.5, "Clipped control: \(name): \(button.title)")
                precondition(bounds.minY >= -0.5 && bounds.maxY <= document.bounds.height + 0.5, "Unreachable control: \(name): \(button.title)")
                precondition(button.bounds.width + 1 >= button.intrinsicContentSize.width, "Compressed control: \(name): \(button.title)")
                controls.append(["title": button.title, "frame": NSStringFromRect(bounds), "enabled": button.isEnabled])
            }
            precondition(buttons.count == 10, "Expected every production control")
            if document.bounds.height > scroll.contentView.bounds.height {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView); view.displayIfNeeded()
                try capture("-bottom")
            }
            report.append(["scenario": name, "window": "\(width)x\(height)", "fontScale": scale,
                           "document": NSStringFromRect(document.bounds), "controls": controls])
            window.orderOut(nil)
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("layout-report.json"))
        print("Rendered \(scenarios.count) production-view fixture states; all 10 native controls fit the scroll document in every state.")
        withExtendedLifetime(target) {}
    }
}
