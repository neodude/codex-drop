import UIKit

/// Offline visual fixture. No pairing, image access, network, clipboard, or Mac delivery.
@main @MainActor final class SharePreviewApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Preview", sessionRole: session.role)
        configuration.delegateClass = PreviewSceneDelegate.self
        return configuration
    }
}

@MainActor final class PreviewSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = PreviewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}

@MainActor final class PreviewController: UIViewController {
    private let sheet = ShareStatusView(frame: .zero)
    private var scenario = "uploading"
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--scenario"), args.indices.contains(flag + 1) { scenario = args[flag + 1] }
        if args.contains("--large-text") { traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        let width: CGFloat = args.contains("--compact") ? 320 : 390
        let height: CGFloat = args.contains("--compact") ? 420 : 520
        sheet.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.widthAnchor.constraint(equalToConstant: width), sheet.heightAnchor.constraint(equalToConstant: height),
            sheet.centerXAnchor.constraint(equalTo: view.centerXAnchor), sheet.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        switch scenario {
        case "finding":
            sheet.render(status: "Finding your Mac…", detail: "Your Mac will add all 3 images\nto the current draft.", stage: 0)
        case "confirming":
            sheet.render(status: "Confirming attachments…", detail: "You can close this sheet. Delivery will continue on your Mac.", stage: 2, buttonTitle: "Close")
        case "unpaired":
            sheet.render(title: "Pair your Mac", status: "One quick setup", detail: "Open Codex Drop on your iPhone and scan the Mac’s pairing code, then share again.", stage: nil, working: false, buttonTitle: "Close")
        case "blocked":
            sheet.render(title: "Check your Mac", status: "Attachment needs review", detail: "1 of 3 images verified attached.\nImage 2: blocked before attachment.\nImage 3: not tried.\n\nCheck Codex before sharing again. Don’t resend images already attached. No automatic retry.", stage: nil, working: false, buttonTitle: "Close")
        case "uncertain":
            sheet.render(title: "Check your Mac", status: "Attachment isn’t confirmed", detail: "Some images may already be attached. Check Codex before sharing again. Don’t resend images already attached. No automatic retry.", stage: nil, working: false, buttonTitle: "Close")
        default:
            sheet.render(status: "Uploading screenshot 2 of 3", detail: "Your Mac will add all 3 images\nto the current draft.", stage: 1)
        }
        sheet.closeButton.addAction(UIAction { [weak self] _ in self?.sheet.isHidden = true }, for: .touchUpInside)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            sheet.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: sheet.bounds).image { _ in
                sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true)
            }
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(scenario).png")
            try? image.pngData()?.write(to: destination)
            let scroll = sheet.subviews.compactMap { $0 as? UIScrollView }.first
            let report: [String: Any] = [
                "scenario": scenario,
                "viewportWidth": sheet.bounds.width, "viewportHeight": sheet.bounds.height,
                "contentSizeCategory": sheet.traitCollection.preferredContentSizeCategory.rawValue,
                "buttonVisible": sheet.bounds.contains(sheet.closeButton.frame),
                "buttonHeight": sheet.closeButton.bounds.height,
                "buttonFontSize": sheet.closeButton.titleLabel?.font.pointSize ?? 0,
                "scrollContentHeight": scroll?.contentSize.height ?? 0,
                "scrollViewportHeight": scroll?.bounds.height ?? 0,
                "iconLoaded": UIImage(named: "DropMark") != nil
            ]
            if let encoded = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? encoded.write(to: destination.deletingPathExtension().appendingPathExtension("json"))
            }
            if argsContainLargeText(), let scroll {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
                sheet.layoutIfNeeded()
                let bottom = UIGraphicsImageRenderer(bounds: sheet.bounds).image { _ in sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true) }
                try? bottom.pngData()?.write(to: destination.deletingPathExtension().appendingPathExtension("bottom.png"))
            }
        }
    }
    private func argsContainLargeText() -> Bool { ProcessInfo.processInfo.arguments.contains("--large-text") }
}
