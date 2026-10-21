import UIKit
import UniformTypeIdentifiers
import ImageIO

@MainActor final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var transfer: Task<Void, Never>?
    private var started = false
    private var committed = false
    private let closeButton = UIButton(type: .system)
    private let requestID = UUID().uuidString.lowercased()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "Codex Drop"; title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center; title.adjustsFontForContentSizeCategory = true
        message.text = "Preparing images…"; message.numberOfLines = 0; message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        closeButton.setTitle("Cancel", for: .normal)
        closeButton.addTarget(self, action: #selector(closeExtension), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, spinner, message]); stack.axis = .vertical
        stack.alignment = .fill; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack); view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        preferredContentSize = CGSize(width: 360, height: 420)
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
        spinner.startAnimating(); defer { spinner.stopAnimating() }
        do {
            guard let context = extensionContext, let pairing = try PairingStore.load() else {
                message.text = "Open Codex Drop on your iPhone and pair your Mac first."
                closeButton.setTitle("Close", for: .normal); return
            }
            let items = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            guard (1...10).contains(items.count) else { throw ReceiverError.message("Share 1–10 images at a time.") }
            let client = ReceiverClient(pairing: pairing); defer { client.close() }
            let job = try await client.attachBatch(count: items.count, id: requestID, prepare: { index in
                let input = try await Self.readImage(items[index])
                return try await ImageEncoder.png(input)
            }, progress: { [self] progress in
                switch progress {
                case let .preparing(index, count): message.text = "Preparing image \(index + 1) of \(count)…"
                case let .uploading(index, count): message.text = "Uploading image \(index + 1) of \(count)… Nothing attached yet."
                case .committing:
                    committed = true
                    closeButton.setTitle("Close", for: .normal)
                    message.text = "Attaching to the focused Mac composer… Closing now will not stop delivery."
                case .confirming:
                    message.text = "Waiting for attachment confirmation… Closing now will not stop delivery. Check the Mac before sharing again."
                }
            }, timing: { timings[$0] = $1 })
            message.text = job.userMessage
            if job.allVerified(count: items.count) {
                context.completeRequest(returningItems: [], completionHandler: nil)
            }
        } catch is CancellationError { }
        catch {
            if committed {
                message.text = "Attachment is not confirmed. Some images may already be attached. Check the Mac before sharing again. Do not resend images already attached. No automatic retry."
            } else {
                let detail = error is ReceiverError ? error.localizedDescription : "Connection or image preparation interrupted."
                message.text = "Nothing attached; this batch was not committed. \(detail)"
            }
        }
        closeButton.setTitle("Close", for: .normal)
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
