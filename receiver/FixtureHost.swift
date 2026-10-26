import AppKit
import Foundation
import Darwin

private var hideApplicationFocus = false

@objc(FixtureApplication) final class FixtureApplication: NSApplication {
    override var accessibilityFocusedUIElement: Any? {
        hideApplicationFocus ? nil : super.accessibilityFocusedUIElement
    }
}

final class FixtureTextView: NSTextView {
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if hideApplicationFocus && focused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        } else { super.setAccessibilityFocused(focused) }
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: NSTextView!
    var stack: NSStackView!
    var otherWindow: NSWindow?
    var otherEditor: NSTextView?
    var searchField: NSTextField!
    var extraComposer: NSStackView?
    var configuration: [String: String] = [:]
    var pasteCount = 0
    var attachmentCount = 0
    var timer: Timer?
    var started = Date()
    var lastHeartbeat = Date()
    var maxHeartbeatGapMS = 0

    var board: NSPasteboard { NSPasteboard(name: .init(configuration["pasteboard"]!)) }
    var reportURL: URL { URL(fileURLWithPath: configuration["report"]!) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            configuration = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent(".codex-artifacts/fixture-config.json")))
            guard configuration["pasteboard"]?.hasPrefix("com.example.CodexScreenshotReceiver.Test.") == true else { exit(2) }
            board.clearContents(); board.setString("fixture original clipboard", forType: .string)
            let menu = NSMenu()
            let appItem = NSMenuItem(); menu.addItem(appItem)
            let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Receiver Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(edit)
            let editMenu = NSMenu(title: "Edit")
            let paste = NSMenuItem(title: "Paste", action: #selector(pasteImage(_:)), keyEquivalent: "v"); paste.target = self
            editMenu.addItem(paste); edit.submenu = editMenu
            NSApp.mainMenu = menu

            window = NSWindow(contentRect: NSRect(x: 240, y: 300, width: 650, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Screenshot Receiver — isolated fixture"
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
            stack.setAccessibilityElement(true); stack.setAccessibilityRole(.group)
            let marker = NSButton(title: "Add files and more", target: nil, action: nil)
            marker.setAccessibilityLabel("Add files and more")
            stack.addArrangedSubview(marker)
            let existing = NSButton(title: "Remove existing.pdf", target: nil, action: nil)
            existing.setAccessibilityLabel("Remove existing.pdf"); stack.addArrangedSubview(existing)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true
            editor = FixtureTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
            editor.string = "Existing fixture draft\nsecond line 🧗"
            editor.isRichText = false
            editor.setAccessibilityLabel("Fixture main composer")
            scroll.documentView = editor
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
            stack.addArrangedSubview(scroll)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = window.contentView!
            searchField = NSTextField(frame: NSRect(x: 30, y: 15, width: 300, height: 24))
            searchField.stringValue = "Unrelated search field"
            content.addSubview(searchField)
            content.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30)])
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshAndReport() }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
            // Apply the first requested mode through the same reset path as later cases.
            configuration["runID"] = "initializing"
            writeReport()
        } catch { fputs("Fixture initialization failed\n", stderr); exit(2) }
    }

    @objc func pasteImage(_ sender: Any?) {
        pasteCount += 1
        let mode = configuration["mode"] ?? "standard"
        let runID = configuration["runID"]
        if mode == "activation-required" && !NSApp.isActive { writeReport(); return }
        if mode == "draft-change" { editor.string += "changed by fixture" }
        if mode == "batch-focus-change" || mode == "background-focus-change" { window.makeFirstResponder(searchField) }
        if mode == "clipboard-change" {
            board.clearContents(); board.setString("newer fixture clipboard", forType: .string)
        }
        if mode == "window-change" {
            showOtherWindow(makeKey: true)
        }
        if mode == "no-ack" || mode == "clipboard-change" || mode == "window-change" || (mode == "batch-uncertain" && pasteCount == 2) { writeReport(); return }
        let delay: TimeInterval = mode == "delayed" ? 3.5 : 0
        let attach: () -> Void = { [weak self] in
            guard let self, self.configuration["runID"] == runID, let value = self.board.string(forType: .fileURL),
                  let url = URL(string: value), url.isFileURL,
                  let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let preview = NSImageView(); preview.image = NSImage(named: NSImage.multipleDocumentsName)
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.heightAnchor.constraint(equalToConstant: 70).isActive = true
            preview.widthAnchor.constraint(equalToConstant: 140).isActive = true
            self.stack.addArrangedSubview(preview)
            let label = "Remove " + url.lastPathComponent
            let remove = NSButton(title: label, target: nil, action: nil)
            remove.setAccessibilityLabel(label); self.stack.addArrangedSubview(remove)
            self.attachmentCount += 1
            self.writeReport()
        }
        // Standard must consume bytes inside the synchronous AX menu handler.
        // This is the call ordering that exposed the old lazy-provider deadlock.
        if delay == 0 { attach() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attach) }
        writeReport()
    }

    private func showOtherWindow(makeKey: Bool) {
        let other = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 360, height: 220),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.animationBehavior = .none
        other.title = "Other fixture window"
        let group = NSStackView(frame: NSRect(x: 20, y: 20, width: 320, height: 180))
        group.orientation = .vertical
        group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
        let marker = NSButton(title: "Add files and more", target: nil, action: nil)
        marker.setAccessibilityLabel("Add files and more"); group.addArrangedSubview(marker)
        let alternate = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        alternate.isRichText = false; alternate.string = "Other fixture draft"
        alternate.heightAnchor.constraint(equalToConstant: 100).isActive = true
        alternate.widthAnchor.constraint(equalToConstant: 300).isActive = true
        group.addArrangedSubview(alternate); other.contentView?.addSubview(group)
        otherWindow = other; otherEditor = alternate
        if makeKey { other.makeKeyAndOrderFront(nil); other.makeFirstResponder(alternate) }
        else { other.orderFront(nil) }
    }

    func refreshAndReport() {
        let now = Date()
        maxHeartbeatGapMS = max(maxHeartbeatGapMS, Int(now.timeIntervalSince(lastHeartbeat) * 1000))
        lastHeartbeat = now
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        if let data = try? Data(contentsOf: root.appendingPathComponent(".codex-artifacts/fixture-config.json")),
           let next = try? JSONDecoder().decode([String: String].self, from: data),
           next["runID"] != configuration["runID"],
           next["pasteboard"]?.hasPrefix("com.example.CodexScreenshotReceiver.Test.") == true {
            configuration = next
            pasteCount = 0; attachmentCount = 0; maxHeartbeatGapMS = 0; started = now
            for view in stack.arrangedSubviews.dropFirst(3) { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            otherWindow?.close(); otherWindow = nil; otherEditor = nil
            extraComposer?.removeFromSuperview(); extraComposer = nil
            editor.string = "Existing fixture draft\nsecond line 🧗"
            board.clearContents(); board.setString("fixture original clipboard", forType: .string)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let mode = configuration["mode"] ?? "standard"
            hideApplicationFocus = mode == "background-focus" || mode == "background-focus-change"
            if mode == "selected-text" || mode == "unfocused-selected" { editor.setSelectedRange(NSRange(location: 0, length: 5)) }
            if mode.hasPrefix("unfocused") || mode.hasPrefix("background-focus") || mode == "ambiguous" { window.makeFirstResponder(searchField) }
            if mode.hasPrefix("two-window-") {
                showOtherWindow(makeKey: false)
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
                if mode == "two-window-activation" { NSApp.hide(nil) }
            }
            if mode == "ambiguous" {
                let group = NSStackView(); group.orientation = .vertical
                group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
                let marker = NSButton(title: "Add files and more", target: nil, action: nil)
                marker.setAccessibilityLabel("Add files and more")
                group.addArrangedSubview(marker)
                let otherEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
                otherEditor.string = "Other composer"
                group.addArrangedSubview(otherEditor)
                group.frame = NSRect(x: 400, y: 10, width: 180, height: 60)
                window.contentView?.addSubview(group); extraComposer = group
            }
        }
        if configuration["mode"] == "window-before-paste", otherWindow == nil,
           board.types?.contains(.fileURL) == true {
            showOtherWindow(makeKey: true)
        }
        writeReport()
    }

    func writeReport() {
        let report: [String: Any] = ["mode": configuration["mode"] ?? "standard", "pasteCount": pasteCount,
                                   "attachments": attachmentCount, "draftUnchanged": editor.string == "Existing fixture draft\nsecond line 🧗",
                                   "heartbeatSeconds": Date().timeIntervalSince(started),
                                   "runID": configuration["runID"] ?? "initial",
                                   "maxHeartbeatGapMS": maxHeartbeatGapMS,
                                   "composerFocused": window.firstResponder === editor,
                                   "appActive": NSApp.isActive,
                                   "windowCount": NSApp.windows.filter { $0 === window || $0 === otherWindow }.count,
                                   "otherDraftUnchanged": otherEditor?.string == "Other fixture draft",
                                   "clipboardIsOriginal": board.string(forType: .string) == "fixture original clipboard",
                                   "clipboardIsNewer": board.string(forType: .string) == "newer fixture clipboard"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct FixtureMain {
    static func main() {
        var cutoff: DispatchSourceTimer?
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--exit-after") {
            guard args.indices.contains(index + 1), let seconds = Double(args[index + 1]),
                  seconds.isFinite, (1...120).contains(seconds) else {
                fputs("Fixture cutoff must be between 1 and 120 seconds.\n", stderr); exit(2)
            }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + seconds)
            // This is a disposable test app. Exit from an independent queue so
            // a blocked UI, modal loop or delayed agent response cannot hold it.
            timer.setEventHandler { _exit(124) }
            timer.resume(); cutoff = timer
        }
        defer { cutoff?.cancel() }
        if args.contains("--watchdog-probe") {
            guard cutoff != nil else { exit(2) }
            // Deliberately block the main thread without creating an NSApp or
            // window. The independent cutoff must still end this test process.
            withExtendedLifetime(cutoff) { Thread.sleep(forTimeInterval: 30) }
            exit(3)
        }
        let application = FixtureApplication.shared
        let delegate = FixtureDelegate()
        application.delegate = delegate; application.setActivationPolicy(.regular)
        withExtendedLifetime((delegate, cutoff)) { application.run() }
    }
}
