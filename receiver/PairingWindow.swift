import AppKit
import CoreImage.CIFilterBuiltins

@MainActor final class PairingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

@main struct PairingWindow {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let code = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(code.utf8); filter.correctionLevel = "M"
        guard let qr = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(qr, from: qr.extent) else { return }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Pair iPhone with Codex Drop"; window.isReleasedWhenClosed = false
        let image = NSImageView(); image.image = NSImage(cgImage: cg, size: NSSize(width: 430, height: 430))
        image.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Scan with Codex Drop on your iPhone")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "This QR pairs your phone with this Mac. Keep it private.\nAfter pairing, close this window and focus the intended Codex composer. Leave Codex Drop running; its main window can be closed.")
        note.alignment = .center
        let stack = NSStackView(views: [title, image, note]); stack.orientation = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor), image.heightAnchor.constraint(equalToConstant: 430)])
        let delegate = PairingWindowDelegate(); window.delegate = delegate
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}
