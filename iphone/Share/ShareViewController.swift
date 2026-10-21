import UIKit
import UniformTypeIdentifiers
import ImageIO

@MainActor final class ShareViewController: UIViewController {
    private let sheet = ShareStatusView(frame: .zero)
    private var transfer: Task<Void, Never>?
    private var started = false
    private var committed = false
    private let requestID = UUID().uuidString.lowercased()
    override func loadView() { view = sheet }
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        preferredContentSize = CGSize(width: 390, height: 520)
        sheet.closeButton.addTarget(self, action: #selector(closeExtension), for: .touchUpInside)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        transfer = Task { [weak self] in await self?.attach() }
    }
    private func attach() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var timings: [String: Int] = [:]
        defer {
            timings["Total"] = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            PairingStore.saveTiming(timings)
        }
        do {
            guard let context = extensionContext, let pairing = try PairingStore.load() else {
                sheet.render(title: "Pair your Mac", status: "One quick setup", detail: "Open Codex Drop on your iPhone and scan the Mac’s pairing code, then share again.", stage: nil, working: false, buttonTitle: "Close")
                return
            }
            let items = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            guard (1...10).contains(items.count) else { throw ReceiverError.message("Share 1–10 images at a time.") }
            sheet.render(status: "Finding your Mac…", detail: Self.destination(count: items.count), stage: 0)
            let client = ReceiverClient(pairing: pairing); defer { client.close() }
            let job = try await client.attachBatch(count: items.count, id: requestID, prepare: { index in
                let input = try await Self.readImage(items[index])
                return try await ImageEncoder.png(input)
            }, progress: { [self] progress in
                switch progress {
                case let .preparing(index, count):
                    sheet.render(status: "Preparing screenshot \(index + 1) of \(count)", detail: Self.destination(count: count), stage: 1)
                case let .uploading(index, count):
                    sheet.render(status: "Uploading screenshot \(index + 1) of \(count)", detail: Self.destination(count: count), stage: 1)
                case .committing:
                    committed = true
                    sheet.render(status: "Attaching to Codex…", detail: "You can close this sheet. Delivery will continue on your Mac.", stage: 2, buttonTitle: "Close")
                case .confirming:
                    sheet.render(status: "Confirming attachments…", detail: "You can close this sheet. Delivery will continue on your Mac.", stage: 2, buttonTitle: "Close")
                }
            }, timing: { timings[$0] = $1 })
            if job.allVerified(count: items.count) {
                context.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                sheet.render(title: "Check your Mac", status: "Attachment needs review", detail: job.userMessage, stage: nil, working: false, buttonTitle: "Close")
            }
        } catch is CancellationError { }
        catch {
            if committed {
                sheet.render(title: "Check your Mac", status: "Attachment isn’t confirmed", detail: "Some images may already be attached. Check Codex before sharing again. Don’t resend images already attached. No automatic retry.", stage: nil, working: false, buttonTitle: "Close")
            } else {
                let detail = error is ReceiverError ? error.localizedDescription : "Connection or image preparation interrupted."
                sheet.render(title: "Drop interrupted", status: "No images attached", detail: detail, stage: nil, working: false, buttonTitle: "Close")
            }
        }
    }
    private static func destination(count: Int) -> String {
        count == 1 ? "Your Mac will add this image\nto the current draft." : "Your Mac will add all \(count) images\nto the current draft."
    }
    private static func readImage(_ item: NSItemProvider) async throws -> Data {
        let type = item.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? UTType.png.identifier : UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            item.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? ReceiverError.message("Could not read the shared image.") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 20 * 1024 * 1024 else { throw ReceiverError.message("Each image must be at most 20 MiB.") }
                    // Copy before this callback returns: the provider owns the temporary file.
                    let data = try Data(contentsOf: url)
                    guard data.count <= 20 * 1024 * 1024 else { throw ReceiverError.message("The image is too large.") }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @objc private func closeExtension() {
        transfer?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
