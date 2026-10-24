import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ImageIO

private struct NativeBatchManifest: Decodable {
    struct Image: Decodable { let path: String; let sha256: String }
    let images: [Image]
}

/// Read at most the supported encoded-file limit even if a file changes after stat.
private func originalImage(_ url: URL, sha256: String? = nil) throws -> OriginalImage {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DeliveryRefusal(reason: "image_file_unavailable") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid() else { throw DeliveryRefusal(reason: "unsafe_image_file") }
    guard info.st_size <= ImageLimits.maxBytes else { throw DeliveryRefusal(reason: "image_size_limit") }
    var data = Data()
    while data.count <= ImageLimits.maxBytes {
        let remaining = min(1024 * 1024, ImageLimits.maxBytes + 1 - data.count)
        guard let part = try handle.read(upToCount: remaining), !part.isEmpty else { break }
        data.append(part)
    }
    guard data.count <= ImageLimits.maxBytes else { throw DeliveryRefusal(reason: "image_size_limit") }
    if let sha256 {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw DeliveryRefusal(reason: "batch_image_checksum_changed")
        }
    }
    let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
          let identifier = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0 else {
        throw DeliveryRefusal(reason: "invalid_image")
    }
    let types: [String: OriginalImageType] = ["public.png": .png, "public.jpeg": .jpeg,
        "com.compuserve.gif": .gif, "org.webmproject.webp": .webp, "public.webp": .webp]
    guard let type = types[identifier] else { throw DeliveryRefusal(reason: "unsupported_image_type") }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.doubleValue > 0, height.doubleValue > 0 else { throw DeliveryRefusal(reason: "invalid_image") }
    return OriginalImage(data: data, fileURL: url, type: type)
}

@main struct ReceiverMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] { try platformSelfTest(); return }
            if arguments.count == 2, arguments[0] == "--self-test-original-file" {
                try originalFileSelfTest(originalImage(URL(fileURLWithPath: arguments[1])))
                return
            }
            if arguments == ["--diagnose-clipboard"] { try diagnoseClipboardFormats(); return }
            if arguments.count == 2, arguments[0] == "--read-fixture-pasteboard",
               arguments[1].hasPrefix("com.example.CodexScreenshotReceiver.Test.") {
                let pb = NSPasteboard(name: .init(arguments[1]))
                let items = pb.pasteboardItems ?? []
                guard items.count == 1, Set(items[0].types) == [.fileURL],
                      let value = items[0].string(forType: .fileURL), let url = URL(string: value), url.isFileURL else {
                    throw DeliveryRefusal(reason: "fixture_original_file_unreadable")
                }
                let image = try originalImage(url)
                print(SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined())
                return
            }
            if arguments.count == 2, arguments[0] == "--try-fixture-lock",
               URL(fileURLWithPath: arguments[1]).lastPathComponent.hasPrefix("CodexReceiverLockTest-") {
                do {
                    let lock = try NativeDeliveryLock(directory: URL(fileURLWithPath: arguments[1]))
                    print("acquired"); lock.release()
                } catch { print("blocked") }
                return
            }
            if arguments == ["--help"] {
                print("MacAttachmentReceiver --image FILE --result FILE\n--diagnose: 8-second countdown, then read structural composer metadata only.\n--self-test: isolated pasteboard tests only.")
                return
            }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if arguments == ["--diagnose-focus"] || arguments == ["--diagnose-activation"] {
                guard AXIsProcessTrustedWithOptions(options) else { throw DeliveryRefusal(reason: "accessibility_permission_required") }
                print("Within 10 seconds, select the intended Codex thread WITHOUT clicking its composer, then switch to another app.")
                print("This probe requests composer focus and records structural checks for 0.5 seconds. Activation mode brings Codex forward. It never touches the clipboard, attaches an image, or sends a message.")
                fflush(stdout); Thread.sleep(forTimeInterval: 10)
                try diagnoseComposerFocus(activate: arguments == ["--diagnose-activation"]); return
            }
            if arguments == ["--diagnose"] {
                guard AXIsProcessTrustedWithOptions(options) else { throw DeliveryRefusal(reason: "accessibility_permission_required") }
                print("Focus Codex's main composer within 8 seconds; no clipboard or UI changes will occur.")
                fflush(stdout); Thread.sleep(forTimeInterval: 8)
                try diagnoseComposer(); return
            }
            guard [4,6,8,10,12].contains(arguments.count), ["--image", "--batch"].contains(arguments[0]), arguments[2] == "--result" else {
                throw DeliveryRefusal(reason: "invalid_arguments")
            }
            var stageHold: Double = 0, afterHold: Double = 0
            var fixturePasteboard: String?
            var expectedSHA256: String?
            var explicitRepairTest = false
            var activateFixture = false
            for index in stride(from: 4, to: arguments.count, by: 2) {
                if arguments[index] == "--expected-sha256" {
                    guard arguments[0] == "--image", expectedSHA256 == nil else {
                        throw DeliveryRefusal(reason: "invalid_arguments")
                    }
                    expectedSHA256 = arguments[index+1]
                    continue
                }
                if arguments[index] == "--live-test-repair" {
                    guard arguments[index+1] == "eager-png-v2" else { throw DeliveryRefusal(reason: "invalid_repair_test") }
                    explicitRepairTest = true; continue
                }
                if arguments[index] == "--fixture-pasteboard" {
                    guard arguments[index+1].hasPrefix("com.example.CodexScreenshotReceiver.Test.") else { throw DeliveryRefusal(reason: "invalid_fixture_pasteboard") }
                    fixturePasteboard = arguments[index+1]; continue
                }
                if arguments[index] == "--fixture-activation" {
                    guard arguments[index+1] == "required" else { throw DeliveryRefusal(reason: "invalid_fixture_activation") }
                    activateFixture = true; continue
                }
                guard let seconds = Double(arguments[index+1]), seconds >= 0, seconds <= 10 else { throw DeliveryRefusal(reason: "invalid_test_hold") }
                switch arguments[index] {
                case "--test-stage-hold": stageHold = seconds
                case "--test-after-paste-hold": afterHold = seconds
                default: throw DeliveryRefusal(reason: "invalid_arguments")
                }
            }
            guard !activateFixture || fixturePasteboard != nil else { throw DeliveryRefusal(reason: "fixture_activation_requires_private_pasteboard") }
            let resultURL = URL(fileURLWithPath: arguments[3])
            let pauseURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(".receiver-paused")
            if fixturePasteboard == nil && !explicitRepairTest && FileManager.default.fileExists(atPath: pauseURL.path) {
                try writeResult(DeliveryResult(status: "blocked", reason: "receiver_paused_for_repair", pasteAttempted: false, clipboardRead: nil), to: resultURL)
                return
            }
            let isBatch = arguments[0] == "--batch"
            let images: [OriginalImage]
            do {
                if isBatch {
                    let manifestURL = URL(fileURLWithPath: arguments[1])
                    guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else {
                        throw DeliveryRefusal(reason: "invalid_batch_manifest")
                    }
                    let manifest = try JSONDecoder().decode(NativeBatchManifest.self, from: Data(contentsOf: manifestURL))
                    guard (1...ImageLimits.maxBatchCount).contains(manifest.images.count) else { throw DeliveryRefusal(reason: "invalid_batch") }
                    var loaded: [OriginalImage] = [], total = 0
                    for entry in manifest.images {
                        guard entry.path.hasPrefix("/") else { throw DeliveryRefusal(reason: "invalid_batch_manifest") }
                        let imageURL = URL(fileURLWithPath: entry.path)
                        let size = try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= ImageLimits.maxBytes else { throw DeliveryRefusal(reason: "image_size_limit") }
                        guard size <= ImageLimits.maxBatchBytes - total else { throw DeliveryRefusal(reason: "batch_size_limit") }
                        let image = try originalImage(imageURL, sha256: entry.sha256)
                        total += image.data.count
                        guard total <= ImageLimits.maxBatchBytes else { throw DeliveryRefusal(reason: "batch_size_limit") }
                        loaded.append(image)
                    }
                    images = loaded
                } else { images = [try originalImage(URL(fileURLWithPath: arguments[1]), sha256: expectedSHA256)] }
            } catch {
                let reason = (error as? DeliveryRefusal)?.reason ?? (isBatch ? "invalid_batch_manifest" : "invalid_image")
                try writeResult(DeliveryResult(status: "blocked", reason: reason, pasteAttempted: false, clipboardRead: false), to: resultURL)
                return
            }
            guard fixturePasteboard == nil ? AXIsProcessTrustedWithOptions(options) : AXIsProcessTrusted() else {
                try writeResult(DeliveryResult(status: "blocked", reason: "accessibility_permission_required", pasteAttempted: false, clipboardRead: false), to: resultURL)
                return
            }
            let deliveryLock: NativeDeliveryLock
            do { deliveryLock = try NativeDeliveryLock() }
            catch let error as DeliveryRefusal {
                try writeResult(DeliveryResult(status: "blocked", reason: error.reason, pasteAttempted: false, clipboardRead: false), to: resultURL)
                return
            }
            defer { deliveryLock.release() }
            let adapter = MacDeliveryAdapter(fixturePasteboard: fixturePasteboard, activateFixture: activateFixture)
            adapter.testStageHold = stageHold; adapter.testAfterPasteHold = afterHold
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { adapter.cancelled = true }
                source.resume(); return source
            }
            let result: DeliveryResult
            if isBatch {
                result = DeliveryEngine.runBatch(images: images, adapter: adapter) { index in
                    let items = images.indices.map { position in
                        BatchItemResult(index: position, result: DeliveryResult(
                            status: position < index ? "verified" : position == index ? "uncertain" : "not_attempted",
                            reason: position < index ? "attachment_observed" : position == index ? "paste_intent_recorded" : "earlier_item_unconfirmed",
                            pasteAttempted: position <= index, clipboardRestoration: position < index ? "not_recorded" : "not_staged"))
                    }
                    try writeResult(DeliveryResult(status: "uncertain", reason: "batch_paste_intent_recorded", pasteAttempted: true,
                        items: items, verifiedCount: index, totalCount: images.count), to: resultURL)
                }
            } else {
                result = DeliveryEngine.run(image: images[0], adapter: adapter) {
                    // Durable intent prevents blindly replaying a possibly pasted image.
                    try writeResult(DeliveryResult(status: "uncertain", reason: "paste_intent_recorded", pasteAttempted: true, clipboardRead: false), to: resultURL)
                }
            }
            for source in sources { source.cancel() }
            try writeResult(result, to: resultURL)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        } catch let error as DeliveryRefusal {
            fputs("STOP: \(error.reason)\n", stderr); exit(1)
        } catch {
            fputs("STOP: receiver_io_or_platform_error\n", stderr); exit(1)
        }
    }
}
