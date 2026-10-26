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
        var formatDiagnostic: String?
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
            let job = try await client.attachBatch(count: items.count, id: requestID, prepareFile: { index in
                let input = try await Self.readImage(items[index])
                formatDiagnostic = ImageInput.formatDiagnostic(of: input,
                    requestedType: ImageInput.originalTypeIdentifier(in: items[index].registeredTypeIdentifiers),
                    offeredTypes: items[index].registeredTypeIdentifiers)
                let original = try await ImageInput.originalFile(input)
                if original !== input {
                    formatDiagnostic = ImageInput.formatDiagnostic(of: original,
                        requestedType: ImageInput.originalTypeIdentifier(in: items[index].registeredTypeIdentifiers),
                        offeredTypes: items[index].registeredTypeIdentifiers)
                }
                return original
            }, progress: { [self] progress in
                switch progress {
                case let .preparing(index, count):
                    sheet.render(status: "Reading image \(index + 1) of \(count)", detail: Self.destination(count: count), stage: 1)
                case let .uploading(index, count):
                    sheet.render(status: "Uploading image \(index + 1) of \(count)", detail: Self.destination(count: count), stage: 1)
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
                var detail = error is ReceiverError ? error.localizedDescription : "Connection or image preparation interrupted."
                if (error as? ReceiverError)?.isUnsupportedImageFormat == true, let formatDiagnostic {
                    detail += "\n\n" + formatDiagnostic
                }
                sheet.render(title: "Drop interrupted", status: "No images attached", detail: detail, stage: nil, working: false, buttonTitle: "Close")
            }
        }
    }
    private static func destination(count: Int) -> String {
        count == 1 ? "Your Mac will add this image\nto the current draft." : "Your Mac will add all \(count) images\nto the current draft."
    }
    private static func readImage(_ item: NSItemProvider) async throws -> ImageFile {
        guard let type = ImageInput.originalTypeIdentifier(in: item.registeredTypeIdentifiers) else {
            throw ReceiverError.message("The source app did not provide a concrete image file representation. Share an image file from Photos or Files; Codex Drop will not convert it.")
        }
        let load = ImageProviderLoad()
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ImageFile, any Error>) in
                let progress = item.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    defer { load.finish() }
                    do {
                        guard let url else { throw error ?? ImageInput.unreadableError }
                        // Provider files stop being valid as soon as this callback returns.
                        let image = try ImageFile.copy(from: url, cancelled: { load.isCancelled })
                        continuation.resume(returning: image)
                    } catch {
                        continuation.resume(throwing: error is ReceiverError || error is CancellationError ? error : ImageInput.unreadableError)
                    }
                }
                load.setProgress(progress)
            }
        } onCancel: { load.cancel() }
        try Task.checkCancellation()
        return image
    }
    @objc private func closeExtension() {
        transfer?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

// The provider callback and cancellation handler can run on different queues.
private final class ImageProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var progress: Progress?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func setProgress(_ progress: Progress) {
        lock.lock(); if !finished { self.progress = progress }; let cancel = cancelled; lock.unlock()
        if cancel { progress.cancel() }
    }
    func finish() { lock.lock(); finished = true; progress = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let progress = progress; lock.unlock()
        progress?.cancel()
    }
}
