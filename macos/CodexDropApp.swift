import AppKit
import ApplicationServices
import ServiceManagement
import Carbon

@MainActor final class CodexDropDelegate: NSObject, NSApplicationDelegate {
    private var controller: ReceiverController?
    private var window: NSWindow!
    private let accessibility = NSTextField(labelWithString: "Accessibility: checking…")
    private let status = NSTextField(wrappingLabelWithString: "Starting…")
    private let start = NSButton(title: "Start Receiver", target: nil, action: #selector(startReceiver))
    private let stop = NSButton(title: "Stop Receiver", target: nil, action: #selector(stopReceiver))
    private let pair = NSButton(title: "Pair iPhone…", target: nil, action: #selector(pairPhone))
    private let login = NSButton(checkboxWithTitle: "Open at Login", target: nil, action: #selector(toggleLogin))
    private var lastLoginRefresh = Date.distantPast
    private var timer: Timer?
    private var pairingProcess: Process?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication &&
            (event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem ||
             event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil)
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Show Codex Drop", action: #selector(showWindow), keyEquivalent: "0").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Codex Drop", action: #selector(quit), keyEquivalent: "q").target = self
        let applicationItem = NSMenuItem(); applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem); NSApp.mainMenu = menu
        do {
            guard let resources = Bundle.main.resourceURL,
                  let projectPath = Bundle.main.object(forInfoDictionaryKey: "CodexDropProjectRoot") as? String,
                  let pythonPath = Bundle.main.object(forInfoDictionaryKey: "CodexDropPythonExecutable") as? String else { throw ReceiverError.resources }
            let project = URL(fileURLWithPath: projectPath, isDirectory: true)
            controller = try ReceiverController(configuration: ReceiverConfiguration(project: project, resources: resources,
                python: URL(fileURLWithPath: pythonPath), data: project.appendingPathComponent("receiver-data")))
        } catch ReceiverError.duplicate {
            NSApp.terminate(nil); return
        } catch {
            status.stringValue = "Receiver unavailable"
            alert(error.localizedDescription)
        }
        startReceiver()
        // Quit waits inside an AppKit modal run loop. Default-mode-only polling
        // would strand the app after its receiver has already exited.
        let refreshTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        RunLoop.main.add(refreshTimer, forMode: .modalPanel)
        timer = refreshTimer
        if !UserDefaults.standard.bool(forKey: "LoginItemConfigured") {
            setLoginEnabled(true) // Requested by the user for this installed utility.
        }
        refreshLogin()
        if !loginLaunch && !ProcessInfo.processInfo.arguments.contains("--background") { showWindow() }
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 455),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex Drop"; window.isReleasedWhenClosed = false
        window.center()
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 52), icon.heightAnchor.constraint(equalToConstant: 52)])
        let title = NSTextField(labelWithString: "Codex Drop"); title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "iPhone screenshots → Codex draft")
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 3
        let header = NSStackView(views: [icon, heading]); header.spacing = 12
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        accessibility.font = .systemFont(ofSize: 12); accessibility.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: "Same Wi-Fi. Sharing brings Codex forward and attaches to its last active thread. No need to click its message box. Nothing is sent.")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let settings = NSButton(title: "Accessibility Settings…", target: self, action: #selector(accessibilitySettings))
        let project = NSButton(title: "Reveal Project", target: self, action: #selector(revealProject))
        let log = NSButton(title: "Reveal Receiver Log", target: self, action: #selector(revealLog))
        let quit = NSButton(title: "Quit Codex Drop", target: self, action: #selector(quit))
        for button in [start, stop, pair, settings, project, log, quit] { button.target = self; button.bezelStyle = .rounded }
        login.target = self
        let loginSettings = NSButton(title: "Login Items Settings…", target: self, action: #selector(loginItemSettings))
        loginSettings.bezelStyle = .rounded
        func row(_ buttons: [NSButton]) -> NSStackView {
            let row = NSStackView(views: buttons); row.distribution = .fillEqually; row.spacing = 8
            return row
        }
        let first = row([start, stop]), second = row([pair, settings]), third = row([project, log])
        let startup = NSStackView(views: [login, loginSettings]); startup.spacing = 12
        let background = NSTextField(wrappingLabelWithString: "Closing this window keeps the receiver running. Reopen Codex Drop from Finder or Spotlight. Quit stops the receiver.")
        background.font = .systemFont(ofSize: 11); background.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, status, accessibility, note, first, second, third, startup, background, quit])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(18, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in [status, note, first, second, third, background] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func startReceiver() {
        guard !quitting, let controller else { return }
        do { try controller.start() } catch { alert(error.localizedDescription) }
        refresh()
    }
    @objc private func stopReceiver() {
        pairingProcess?.terminate(); pairingProcess = nil
        controller?.stop(); refresh()
    }
    private func refresh() {
        if Date().timeIntervalSince(lastLoginRefresh) > 2 { refreshLogin() }
        accessibility.stringValue = AXIsProcessTrusted() ? "Accessibility: allowed" : "Accessibility: permission needed"
        guard let controller else { start.isEnabled = false; stop.isEnabled = false; pair.isEnabled = false; return }
        let state = controller.state
        status.stringValue = controller.detail
        start.isEnabled = !controller.isRunning && !quitting
        stop.isEnabled = controller.isRunning && state != .stopping && !quitting
        pair.isEnabled = state == .running && !quitting
        login.isEnabled = !quitting
        status.textColor = state == .running ? .labelColor : .secondaryLabelColor
        if quitting && !controller.isRunning {
            timer?.invalidate(); NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    private func setLoginEnabled(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled && service.status != .enabled { try service.register() }
            if !enabled && service.status != .notRegistered { try service.unregister() }
            UserDefaults.standard.set(true, forKey: "LoginItemConfigured")
        } catch { alert("Could not update Open at Login: \(error.localizedDescription)") }
        refreshLogin()
    }
    @objc private func toggleLogin() { setLoginEnabled(login.state == .on) }
    @objc private func loginItemSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func refreshLogin() {
        lastLoginRefresh = Date()
        let state = SMAppService.mainApp.status
        login.state = state == .enabled ? .on : state == .requiresApproval ? .mixed : .off
        login.title = state == .requiresApproval ? "Login approval needed" : "Open at Login"
        guard let data = controller?.configuration.data else { return }
        let status: String
        switch state {
        case .enabled: status = "enabled"
        case .requiresApproval: status = "requires_approval"
        case .notRegistered: status = "not_registered"
        case .notFound: status = "not_found"
        @unknown default: status = "unknown"
        }
        let report: [String: Any] = ["status": status, "bundle": Bundle.main.bundleURL.path]
        let path = data.appendingPathComponent("login-item-status.json")
        if let encoded = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           (try? Data(contentsOf: path)) != encoded {
            try? encoded.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    @objc private func pairPhone() {
        guard let controller, controller.isReady else { return }
        if let pairingProcess, pairingProcess.isRunning { return }
        let path = controller.configuration.pairing
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ReceiverError.unsafeFile }
            let child = Process()
            child.executableURL = controller.configuration.resources.appendingPathComponent("ReceiverPairing")
            child.arguments = [path.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            child.standardInput = FileHandle.nullDevice
            try child.run(); pairingProcess = child
        } catch { alert("Pairing QR is unavailable. Check that the receiver is running, then reopen the log or rebuild the app.") }
    }
    @objc private func accessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func revealProject() {
        guard let project = controller?.configuration.project else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }
    @objc private func revealLog() {
        guard let log = controller?.configuration.log else { return }
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pairingProcess?.terminate(); pairingProcess = nil
        guard controller?.isRunning == true else { return .terminateNow }
        quitting = true; controller?.stop()
        // Reply from the next timer tick, after AppKit receives terminateLater.
        return .terminateLater
    }
    private func alert(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Codex Drop"; alert.informativeText = text
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}

@main struct CodexDropApp {
    @MainActor static func main() {
        let delegate = CodexDropDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
