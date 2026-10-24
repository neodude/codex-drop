import AppKit
import ApplicationServices
import ServiceManagement
import Carbon

@MainActor final class CodexDropDelegate: NSObject, NSApplicationDelegate {
    private var controller: ReceiverController?
    private var window: NSWindow!
    private var statusView: StatusWindowView!
    private var accessibility: NSTextField { statusView.accessibility }
    private var status: NSTextField { statusView.status }
    private var start: NSButton { statusView.start }
    private var stop: NSButton { statusView.stop }
    private var pair: NSButton { statusView.pair }
    private var login: NSButton { statusView.login }
    private var lastLoginRefresh = Date.distantPast
    private var timer: Timer?
    private var pairingProcess: Process?
    private var quitting = false
    private var loginLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Capture the original launch event before initialization can process other events.
        loginLaunch = AppPresentation.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginLaunch = loginLaunch || AppPresentation.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Show Codex Drop", action: #selector(showWindow), keyEquivalent: "0").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Codex Drop…", action: #selector(quit), keyEquivalent: "q").target = self
        let applicationItem = NSMenuItem(); applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem); NSApp.mainMenu = menu
        do {
            guard let resources = Bundle.main.resourceURL,
                  let projectPath = Bundle.main.object(forInfoDictionaryKey: "CodexDropProjectRoot") as? String,
                  let pythonPath = Bundle.main.object(forInfoDictionaryKey: "CodexDropPythonExecutable") as? String else { throw ReceiverError.resources }
            let project = URL(fileURLWithPath: projectPath, isDirectory: true)
            let python = URL(fileURLWithPath: pythonPath)
            let data = try ReceiverConfiguration.prepareData(project: project, resources: resources, python: python)
            controller = try ReceiverController(configuration: ReceiverConfiguration(project: project, resources: resources,
                python: python, data: data))
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
        // Login registration changes only when the user toggles Open at Login.
        // Existing registrations remain intact; a new installation starts opted out.
        refreshLogin()
        if AppPresentation.shouldShowWindow(loginLaunch: loginLaunch, arguments: ProcessInfo.processInfo.arguments) { showWindow() }
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Drop"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 410, height: 350)
        statusView = StatusWindowView(target: self, actions: .init(
            start: #selector(startReceiver), stop: #selector(stopReceiver), pair: #selector(pairPhone),
            accessibility: #selector(accessibilitySettings), project: #selector(revealProject), log: #selector(revealLog),
            login: #selector(toggleLogin), loginSettings: #selector(loginItemSettings),
            close: #selector(closeWindow), quit: #selector(quit)))
        window.contentView = statusView
        window.center()
    }
    @objc private func closeWindow() { window.close() }
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
    @objc private func quit() {
        guard !quitting else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard AppPresentation.quitAlert().runModal() == .alertSecondButtonReturn else { return }
        NSApp.terminate(nil)
    }
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
