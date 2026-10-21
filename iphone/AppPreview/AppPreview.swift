import SwiftUI
import UIKit

/// Offline host: the app container, PairingStore, scanner and ReceiverClient are
/// deliberately excluded from this target. All actions are inert fixtures.
@main struct AppPreview: App {
    var body: some Scene {
        WindowGroup { PreviewHost().ignoresSafeArea() }
    }
}

private struct PreviewHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PreviewController { PreviewController() }
    func updateUIViewController(_ controller: PreviewController, context: Context) {}
}

private final class PreviewController: UIViewController {
    private var renderedView: UIView?
    private let args = ProcessInfo.processInfo.arguments
    private var scenario: String {
        guard let index = args.firstIndex(of: "--scenario"), args.indices.contains(index + 1) else { return "unpaired" }
        return args[index + 1]
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = args.contains("--dark") ? .dark : .light
        let paired = scenario != "unpaired"
        let status = scenario == "error"
            ? "Mac unavailable. Check the receiver, Wi-Fi and Local Network permission."
            : paired ? "Pairing saved. Check the connection to confirm your Mac is reachable."
            : "Open Codex Drop on your Mac, then scan its pairing QR code."
        let content = PairingContentView(
            isPaired: paired, status: status, busy: scenario == "connecting", canScan: true,
            timings: scenario == "timings" ? ["Preparing images": 230, "Finding Mac": 110, "Upload": 815, "Confirmation": 320, "Total": 1475] : [:],
            scan: {}, check: {}, forget: {},
            pasteControl: Button("Paste", systemImage: "doc.on.clipboard") {}
                .buttonStyle(.borderedProminent)
        )
        let host = UIHostingController(rootView: content.dynamicTypeSize(args.contains("--large-text") ? .accessibility3 : .large).preferredColorScheme(args.contains("--dark") ? .dark : .light))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        renderedView = host.view
        if args.contains("--compact") {
            NSLayoutConstraint.activate([
                host.view.widthAnchor.constraint(equalToConstant: 320), host.view.heightAnchor.constraint(equalToConstant: 568),
                host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor), host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
        }
        host.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            capture(suffix: "")
            if args.contains("--large-text") || scenario == "timings", let scroll = findScroll(in: view) {
                scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                captureBottom(scroll: scroll, attempts: 8)
            }
        }
    }
    private func captureBottom(scroll: UIScrollView, attempts: Int) {
        scroll.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            if attempts > 0 { captureBottom(scroll: scroll, attempts: attempts - 1) }
            else { capture(suffix: "-bottom") }
        }
    }
    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
    private func capture(suffix: String) {
        guard let renderedView else { return }
        let image = UIGraphicsImageRenderer(bounds: renderedView.bounds).image { _ in renderedView.drawHierarchy(in: renderedView.bounds, afterScreenUpdates: true) }
        let name = "\(scenario)-\(args.contains("--dark") ? "dark" : "light")\(args.contains("--large-text") ? "-large" : "")\(args.contains("--compact") ? "-compact" : "")\(suffix).png"
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? image.pngData()?.write(to: destination)
    }
}
