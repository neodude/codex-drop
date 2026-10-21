// Actual-AppKit regression fixture. No product app, queue, network, or clipboard.
import AppKit
import Darwin

func record(_ line: String, at url: URL) {
    let bytes = Data((line + "\n").utf8)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    bytes.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
    close(fd)
}

@MainActor final class QuitFixtureDelegate: NSObject, NSApplicationDelegate {
    let mode: String
    let root: URL
    var child: Process!
    var timer: Timer?
    var quitting = false
    var lastMode = ""
    init(mode: String, root: URL) { self.mode = mode; self.root = root }
    var log: URL { root.appendingPathComponent("events.log") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let fixture = root.appendingPathComponent("fake-receiver.sh")
            try "trap 'sleep 0.3; echo cleaned-up; exit 0' TERM\nwhile :; do sleep 0.05; done\n".write(to: fixture, atomically: true, encoding: .utf8)
            let output = root.appendingPathComponent("child.log")
            _ = FileManager.default.createFile(atPath: output.path, contents: Data())
            child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = [fixture.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = try FileHandle(forWritingTo: output)
            child.standardError = child.standardOutput
            try child.run()
            record("child-started", at: log)
        } catch {
            record("fixture-start-failed: \(error)", at: log); _exit(70)
        }
        let callback: @Sendable (Timer) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if mode == "default" {
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true, block: callback)
        } else {
            let pollTimer = Timer(timeInterval: 0.03, repeats: true, block: callback)
            timer = pollTimer
            if mode == "common" || mode == "common-modal" { RunLoop.main.add(pollTimer, forMode: .common) }
            if mode == "modal" || mode == "common-modal" { RunLoop.main.add(pollTimer, forMode: .modalPanel) }
        }
        // Exercise the normal delegate path without scripting another app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            record("request-terminate", at: self.log)
            NSApp.terminate(nil)
            record("terminate-returned", at: self.log)
        }
        let logURL = log
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            record("watchdog-timeout", at: logURL)
            _exit(124)
        }
    }
    func poll() {
        let runMode = RunLoop.current.currentMode?.rawValue ?? "nil"
        if runMode != lastMode {
            record("timer-mode: \(runMode)", at: log); lastMode = runMode
        }
        if quitting && !child.isRunning {
            record("cleanup-observed; reply-terminate=true", at: log)
            timer?.invalidate()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("delegate-terminate-later", at: log)
        quitting = true
        child.terminate()
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        record("will-terminate", at: log)
    }
}

@main struct AppKitQuitFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { _exit(64) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let delegate = QuitFixtureDelegate(mode: CommandLine.arguments[1], root: root)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
