import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private struct NativeBatchManifest: Decodable {
    struct Image: Decodable { let path: String; let sha256: String }
    let images: [Image]
}

private func validatedPNG(_ url: URL, sha256: String? = nil) throws -> Data {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size >= 33, size <= 20 * 1024 * 1024 else { throw DeliveryRefusal(reason: "invalid_png") }
    let data = try Data(contentsOf: url) // Immutable eager bytes, independent of later file changes.
    if let sha256 {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw DeliveryRefusal(reason: "batch_image_checksum_changed")
        }
    }
    func dimension(_ offset: Int) -> Int { data[offset..<offset+4].reduce(0) { $0 * 256 + Int($1) } }
    guard data.count <= 20 * 1024 * 1024, data.count >= 33,
          Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
          dimension(16) > 0, dimension(20) > 0,
          dimension(16) <= 10000, dimension(20) <= 10000,
          dimension(16) * dimension(20) <= 40_000_000,
          let image = NSBitmapImageRep(data: data), image.pixelsWide > 0, image.pixelsHigh > 0,
          image.pixelsWide <= 10000, image.pixelsHigh <= 10000,
          image.pixelsWide * image.pixelsHigh <= 40_000_000 else { throw DeliveryRefusal(reason: "invalid_png") }
    return data
}

@main struct ReceiverMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] { try platformSelfTest(); return }
            if arguments == ["--diagnose-clipboard"] { try diagnoseClipboardFormats(); return }
            if arguments.count == 2, arguments[0] == "--read-fixture-pasteboard",
               arguments[1].hasPrefix("com.example.CodexScreenshotReceiver.Test.") {
                let pb = NSPasteboard(name: .init(arguments[1]))
                guard let data = pb.data(forType: .png) else { throw DeliveryRefusal(reason: "fixture_png_unreadable") }
                print(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
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
            guard [4,6,8,10].contains(arguments.count), ["--image", "--batch"].contains(arguments[0]), arguments[2] == "--result" else {
                throw DeliveryRefusal(reason: "invalid_arguments")
            }
            var stageHold: Double = 0, afterHold: Double = 0
            var fixturePasteboard: String?
            var explicitRepairTest = false
            var activateFixture = false
            for index in stride(from: 4, to: arguments.count, by: 2) {
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
            let images: [Data]
            do {
                if isBatch {
                    let manifestURL = URL(fileURLWithPath: arguments[1])
                    guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else {
                        throw DeliveryRefusal(reason: "invalid_batch_manifest")
                    }
                    let manifest = try JSONDecoder().decode(NativeBatchManifest.self, from: Data(contentsOf: manifestURL))
                    guard (1...10).contains(manifest.images.count) else { throw DeliveryRefusal(reason: "invalid_batch") }
                    var loaded: [Data] = [], total = 0
                    for entry in manifest.images {
                        guard entry.path.hasPrefix("/") else { throw DeliveryRefusal(reason: "invalid_batch_manifest") }
                        let image = try validatedPNG(URL(fileURLWithPath: entry.path), sha256: entry.sha256)
                        total += image.count
                        guard total <= 100 * 1024 * 1024 else { throw DeliveryRefusal(reason: "batch_size_limit") }
                        loaded.append(image)
                    }
                    images = loaded
                } else { images = [try validatedPNG(URL(fileURLWithPath: arguments[1]))] }
            } catch {
                let reason = (error as? DeliveryRefusal)?.reason ?? (isBatch ? "invalid_batch_manifest" : "invalid_png")
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
