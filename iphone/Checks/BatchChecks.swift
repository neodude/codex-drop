import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import zlib

// A format wrapper must never instantiate a class supplied by an archive.
final class ArchiveDecodeTrap: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    required init?(coder: NSCoder) { fatalError("An untrusted archive class was instantiated") }
    func encode(with coder: NSCoder) { fatalError("Test sentinel is never encoded") }
}

// Event gates prove overlap; the deadline only catches deadlocks in a broken
// implementation and does not assert any machine-dependent speedup.
@MainActor final class StartupGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var opened = false
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func open() { opened = true; continuation.finish() }
    func wait() async throws {
        try Task.checkCancellation()
        if opened { return }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }
}

@MainActor func startupDeadline(_ body: @escaping @MainActor @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw ReceiverError.message("Startup overlap check stalled: connection and preparation must run concurrently.")
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

@MainActor final class BatchStub {
    var calls: [String] = []
    var expectedHashes: [Int: String] = [:]
    var prepared: [Int] = []
    var failUpload: Int?
    var uploadFailure: (Data, Int)?
    var cancelAfterUpload: Int?
    var prepareFailure: Int?
    var pendingPolls = 0
    var receiptID: String?
    var received = true
    var terminal = "verified"
    var timeout = false
    var count = 2
    var beforeCreate: (() async throws -> Void)?
    var beforePrepare: ((Int) async throws -> Void)?
    let id = "11111111-1111-1111-1111-111111111111"
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.path
        calls.append(path)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "b", count: 32))
        if path.hasSuffix("commit") { precondition(request.httpBody == Data("{}".utf8)) }
        if path.contains("/jobs/") { pendingPolls = max(0, pendingPolls - 1) }
        if path == "/v1/batches" {
            try await beforeCreate?()
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            precondition(request.value(forHTTPHeaderField: "X-Request-ID") == id)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
            precondition(body["count"] == count)
        }
        if let last = path.split(separator: "/").last, let index = Int(last) {
            precondition(prepared == Array(0...index), "Preparation must alternate with upload")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            precondition(request.timeoutInterval == 120)
            precondition(request.httpBody == nil, "Uploads must not retain a Data request body")
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            var actual = 0
            var hash = SHA256()
            while true {
                let read = stream.read(&bytes, maxLength: bytes.count)
                precondition(read >= 0)
                if read == 0 { break }; actual += read
                hash.update(data: Data(bytes.prefix(read)))
            }
            precondition(actual == Int(request.value(forHTTPHeaderField: "Content-Length")!))
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = expectedHashes[index] { precondition(digest == expected, "Uploaded original bytes changed") }
            if failUpload == index { return uploadFailure ?? (Data(), 409) }
            if cancelAfterUpload == index { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let state = path.hasSuffix("commit") || path.contains("/jobs/") ? (timeout || pendingPolls > 0 ? "queued" : terminal) : "uploading"
        let result: String
        if terminal == "uncertain" {
            result = ",\"result\":{\"verifiedCount\":1,\"totalCount\":3,\"items\":[{\"index\":0,\"status\":\"verified\"},{\"index\":1,\"status\":\"uncertain\"},{\"index\":2,\"status\":\"not_attempted\"}]}"
        } else {
            let items = (0..<count).map { "{\"index\":\($0),\"status\":\"verified\"}" }.joined(separator: ",")
            result = ",\"result\":{\"verifiedCount\":\(count),\"totalCount\":\(count),\"items\":[\(items)]}"
        }
        let job = "{\"id\":\"\(receiptID ?? id)\",\"state\":\"\(state)\"\(result)}"
        return (Data((path.contains("/jobs/") ? job : "{\"received\":\(received),\"job\":\(job)}").utf8), 200)
    }
}

@main struct BatchChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-large-png-fixture" {
            try writeLargePNG(to: URL(fileURLWithPath: CommandLine.arguments[2]), size: ImageInput.maximumBytes); return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-normal-fixture" {
            try fixture(type: .jpeg, width: 3024, height: 4032).write(to: URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        if CommandLine.arguments.count == 3, ["--copy-file", "--prepare-file"].contains(CommandLine.arguments[1]) {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            let input = try ImageFile.copy(from: source)
            let output = try await ImageInput.originalFile(input)
            let sourceHash = try fileHash(source), outputHash = try fileHash(output.url)
            precondition(output === input && sourceHash == outputHash)
            print("PASS: byte-identical original file copy, \(output.byteCount) bytes; no image decoding.")
            return
        }
        let pairing = Pairing(v: 1, service: "unused", pin: String(repeating: "a", count: 64), token: String(repeating: "b", count: 32))
        var checks = 0
        @MainActor func run(_ stub: BatchStub, size: Int = 3, timeout: Duration = .seconds(120)) async throws -> DeliveryJob {
            let client = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: stub.send, pollTimeout: timeout)
            defer { client.close() }
            return try await client.attachBatch(count: stub.count, id: stub.id, prepare: { index in
                stub.prepared.append(index)
                try await stub.beforePrepare?(index)
                if stub.prepareFailure == index { throw ReceiverError.message("Fixture preparation rejected") }
                return Data(repeating: 1, count: size)
            })
        }
        for count in [1, 2] { try await startupDeadline {
            let connected = StartupGate(), preparing = StartupGate()
            let stub = BatchStub(); stub.count = count
            stub.beforeCreate = { connected.open(); try await preparing.wait() }
            stub.beforePrepare = { index in
                if index == 0 { try await connected.wait(); preparing.open() }
            }
            let result = try await run(stub)
            precondition(result.allVerified(count: count))
            precondition(stub.prepared == Array(0..<count), "Prepare each image exactly once")
        }; checks += 1 }
        try await startupDeadline {
            let preparing = StartupGate(), never = StartupGate()
            let stub = BatchStub()
            var preparationCancelled = false
            stub.beforeCreate = { try await preparing.wait(); throw ReceiverError.message("Fixture connection failure") }
            stub.beforePrepare = { _ in
                preparing.open()
                do { try await never.wait() } catch { preparationCancelled = error is CancellationError; throw error }
            }
            do { _ = try await run(stub); fatalError("Failed connection accepted") }
            catch { precondition(error.localizedDescription == "Fixture connection failure") }
            precondition(preparationCancelled && stub.calls == ["/v1/batches"])
        }
        checks += 1
        try await startupDeadline {
            let connected = StartupGate(), never = StartupGate()
            let stub = BatchStub()
            var connectionCancelled = false
            stub.beforeCreate = {
                connected.open()
                do { try await never.wait() } catch { connectionCancelled = error is CancellationError; throw error }
            }
            stub.beforePrepare = { _ in try await connected.wait(); throw ReceiverError.message("Fixture preparation failure") }
            do { _ = try await run(stub); fatalError("Failed preparation accepted") }
            catch { precondition(error.localizedDescription == "Fixture preparation failure") }
            precondition(connectionCancelled && stub.calls == ["/v1/batches"])
        }
        checks += 1
        try await startupDeadline {
            let connected = StartupGate(), preparing = StartupGate(), neverConnection = StartupGate(), neverImage = StartupGate()
            let stub = BatchStub()
            var connectionCancelled = false, preparationCancelled = false
            stub.beforeCreate = {
                connected.open()
                do { try await neverConnection.wait() } catch { connectionCancelled = error is CancellationError; throw error }
            }
            stub.beforePrepare = { _ in
                preparing.open()
                do { try await neverImage.wait() } catch { preparationCancelled = error is CancellationError; throw error }
            }
            let transfer = Task { try await run(stub) }
            try await connected.wait(); try await preparing.wait()
            transfer.cancel()
            do { _ = try await transfer.value; fatalError("Cancelled startup accepted") } catch { precondition(error is CancellationError) }
            precondition(connectionCancelled && preparationCancelled && stub.calls == ["/v1/batches"])
        }
        checks += 1
        try await startupDeadline {
            let prepared = StartupGate(), stub = BatchStub()
            var firstURL: URL?
            stub.beforeCreate = { try await prepared.wait(); throw ReceiverError.message("Fixture connection failure") }
            let client = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: stub.send)
            defer { client.close() }
            do {
                _ = try await client.attachBatch(count: 2, id: stub.id, prepareFile: { _ in
                    let file = try ImageFile.stage(Data([1, 2, 3])); firstURL = file.url; prepared.open(); return file
                })
                fatalError("Failed connection accepted")
            } catch { precondition(error.localizedDescription == "Fixture connection failure") }
            precondition(firstURL != nil && !FileManager.default.fileExists(atPath: firstURL!.path), "Failed startup must delete its prepared file")
        }
        checks += 1
        try await startupDeadline {
            let connected = StartupGate(), prepared = StartupGate(), never = StartupGate()
            let stub = BatchStub()
            var firstURL: URL?
            stub.beforeCreate = { try await prepared.wait(); connected.open(); try await never.wait() }
            let client = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: stub.send)
            defer { client.close() }
            let transfer = Task {
                try await client.attachBatch(count: 2, id: stub.id, prepareFile: { _ in
                    let file = try ImageFile.stage(Data([1, 2, 3])); firstURL = file.url; prepared.open(); return file
                })
            }
            try await connected.wait(); transfer.cancel()
            do { _ = try await transfer.value; fatalError("Cancelled startup accepted") } catch { precondition(error is CancellationError) }
            precondition(firstURL != nil && !FileManager.default.fileExists(atPath: firstURL!.path), "Cancelled startup must delete its prepared file")
            precondition(stub.calls == ["/v1/batches"])
        }
        checks += 1
        let lifetimeStub = BatchStub()
        let lifetimeClient = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: lifetimeStub.send)
        var firstURL: URL?
        let lifetimeResult = try await lifetimeClient.attachBatch(count: 2, id: lifetimeStub.id, prepareFile: { index in
            if index == 1 { precondition(!FileManager.default.fileExists(atPath: firstURL!.path), "Release the first image before preparing the next") }
            lifetimeStub.prepared.append(index)
            let file = try ImageFile.stage(Data([1, 2, 3]))
            if index == 0 { firstURL = file.url }
            return file
        })
        lifetimeClient.close()
        precondition(lifetimeResult.allVerified(count: 2)); checks += 1
        for count in [2, 10] {
            let stub = BatchStub(); stub.count = count
            let job = try await run(stub)
            precondition(job.allVerified(count: count))
            precondition(stub.calls == ["/v1/batches"] + (0..<count).map { "/v1/batches/\(stub.id)/images/\($0)" } + ["/v1/batches/\(stub.id)/commit"])
            checks += 1
        }
        for count in [0, 11] {
            let stub = BatchStub(); stub.count = count
            do { _ = try await run(stub); fatalError("Invalid count accepted") } catch { precondition(stub.calls.isEmpty) }
            checks += 1
        }
        let preparation = BatchStub(); preparation.prepareFailure = 1
        do { _ = try await run(preparation); fatalError("Preparation failure committed") }
        catch { precondition(preparation.calls.count == 2); precondition(!preparation.calls.contains { $0.hasSuffix("commit") }) }
        checks += 1
        let wrongReceipt = BatchStub(); wrongReceipt.receiptID = "22222222-2222-2222-2222-222222222222"
        do { _ = try await run(wrongReceipt); fatalError("Wrong receipt accepted") }
        catch { precondition(wrongReceipt.calls == ["/v1/batches"]) }
        checks += 1
        let unreceived = BatchStub(); unreceived.received = false
        do { _ = try await run(unreceived); fatalError("Rejected receipt accepted") }
        catch { precondition(unreceived.calls == ["/v1/batches"]) }
        checks += 1
        let failed = BatchStub(); failed.failUpload = 1
        do { _ = try await run(failed); fatalError("Upload failure accepted") } catch { precondition(!failed.calls.contains { $0.hasSuffix("commit") }) }
        checks += 1
        let unsupportedMessage = "Codex does not accept HEIC/HEIF as image inputs. Share a JPEG, PNG, GIF or WebP instead. In Photos, use Automatic or Most Compatible."
        for message in [unsupportedMessage, ""] {
            let unsupported = BatchStub(); unsupported.failUpload = 0
            unsupported.uploadFailure = (try JSONSerialization.data(withJSONObject: ["error": "unsupported_image_format", "message": message]), 400)
            do { _ = try await run(unsupported); fatalError("Unsupported image format accepted") }
            catch {
                precondition(error is ReceiverError)
                precondition((error as? ReceiverError)?.isUnsupportedImageFormat == true,
                             "Keep format refusals distinct so only they include file-format diagnostics")
                if !message.isEmpty { precondition(error.localizedDescription == message) }
                else { precondition(error.localizedDescription.contains("JPEG, PNG, GIF, or WebP")); precondition(error.localizedDescription.contains("Automatic or Most Compatible")) }
                precondition(unsupported.calls == ["/v1/batches", "/v1/batches/\(unsupported.id)/images/0"])
                precondition(unsupported.prepared == [0], "Format refusal must stop before the next file and commit")
            }
            checks += 1
        }
        let oversize = BatchStub()
        do { _ = try await run(oversize, size: 50 * 1024 * 1024 + 1); fatalError("Oversize accepted") }
        catch { precondition(oversize.calls == ["/v1/batches"]) }
        checks += 1
        let accepted = BatchStub(); accepted.count = 1
        let acceptedJob = try await run(accepted, size: 50 * 1024 * 1024)
        precondition(acceptedJob.allVerified(count: 1)); checks += 1
        let total = BatchStub(); total.count = 3
        do { _ = try await run(total, size: 50 * 1024 * 1024); fatalError("Batch oversize accepted") }
        catch { precondition(total.calls.count == 3); precondition(!total.calls.contains { $0.hasSuffix("commit") }) }
        checks += 1
        let cancel = BatchStub(); cancel.cancelAfterUpload = 1
        let task = Task { try await run(cancel) }
        do { _ = try await task.value; fatalError("Cancelled batch committed") } catch { precondition(!cancel.calls.contains { $0.hasSuffix("commit") }) }
        checks += 1
        let partial = BatchStub(); partial.count = 3; partial.terminal = "uncertain"
        let job = try await run(partial)
        let message = job.userMessage
        precondition(message.contains("1 of 3")); precondition(message.contains("2")); precondition(message.contains("3")); precondition(message.contains("not tried")); precondition(message.contains("No automatic retry"))
        checks += 1
        let polled = BatchStub(); polled.pendingPolls = 1
        let confirmed = try await run(polled)
        precondition(confirmed.allVerified(count: 2)); precondition(polled.calls.last == "/v1/jobs/" + polled.id)
        precondition(polled.calls.filter { $0.hasSuffix("commit") }.count == 1)
        checks += 1
        let before = BatchStub()
        let beforeTask = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await run(before) }
        do { _ = try await beforeTask.value; fatalError("Precancelled transfer accepted") }
        catch { precondition(before.calls.isEmpty) }
        checks += 1
        let malformed = try JSONDecoder().decode(DeliveryJob.self, from: Data("{\"id\":\"x\",\"state\":\"verified\",\"result\":{\"verifiedCount\":2,\"totalCount\":2,\"items\":[{\"index\":0,\"status\":\"verified\"},{\"index\":0,\"status\":\"verified\"}]}}".utf8))
        precondition(!malformed.allVerified(count: 2)); precondition(malformed.userMessage.contains("review"))
        checks += 1
        let permission = try JSONDecoder().decode(DeliveryJob.self, from: Data("{\"id\":\"x\",\"state\":\"blocked\",\"result\":{\"reason\":\"accessibility_permission_required\",\"verifiedCount\":0,\"totalCount\":2,\"items\":[{\"index\":0,\"status\":\"blocked\",\"pasteAttempted\":false},{\"index\":1,\"status\":\"not_attempted\"}]}}".utf8))
        precondition(permission.userMessage.contains("0 of 2")); precondition(permission.userMessage.contains("System Settings")); precondition(permission.userMessage.contains("Accessibility")); precondition(permission.userMessage.contains("not tried"))
        checks += 1
        let locked = try JSONDecoder().decode(DeliveryJob.self, from: Data(#"{"id":"x","state":"blocked","result":{"reason":"mac_screen_locked","verifiedCount":0,"totalCount":1,"items":[{"index":0,"status":"blocked","pasteAttempted":false}]}}"#.utf8))
        precondition(locked.userMessage.hasPrefix("Unlock your Mac")); precondition(locked.userMessage.contains("0 of 1")); precondition(locked.userMessage.contains("No automatic retry")); precondition(!locked.allVerified(count: 1))
        checks += 1
        let partialLocked = try JSONDecoder().decode(DeliveryJob.self, from: Data(#"{"id":"x","state":"uncertain","result":{"reason":"batch_stopped","verifiedCount":1,"totalCount":2,"items":[{"index":0,"status":"verified"},{"index":1,"status":"blocked","pasteAttempted":false,"reason":"mac_screen_locked"}]}}"#.utf8))
        precondition(partialLocked.userMessage.hasPrefix("Unlock your Mac")); precondition(partialLocked.userMessage.contains("1 of 2")); precondition(partialLocked.userMessage.contains("Do not resend"))
        checks += 1
        let missingLocked = try JSONDecoder().decode(DeliveryJob.self, from: Data(#"{"id":"x","state":"blocked","result":{"reason":"mac_screen_locked"}}"#.utf8))
        precondition(missingLocked.userMessage.hasPrefix("Unlock your Mac")); precondition(missingLocked.userMessage.contains("may already be attached")); precondition(!missingLocked.allVerified(count: 1))
        checks += 1
        for (reason, explanation) in [("clipboard_snapshot_incomplete", "clipboard"), ("file_dialog_timeout", "file-attachment dialog")] {
            let value: [String: Any] = ["id": "x", "state": "blocked", "result": ["reason": reason,
                "verifiedCount": 0, "totalCount": 1, "items": [["index": 0, "status": "blocked", "pasteAttempted": false]]]]
            let refused = try JSONDecoder().decode(DeliveryJob.self, from: JSONSerialization.data(withJSONObject: value))
            precondition(refused.userMessage.contains(explanation), "Show the Mac refusal cause on the phone")
            precondition(refused.userMessage.contains("0 of 1") && refused.userMessage.contains("No automatic retry"))
            checks += 1
        }
        let missing = try JSONDecoder().decode(DeliveryJob.self, from: Data("{\"id\":\"x\",\"state\":\"verified\"}".utf8))
        precondition(!missing.allVerified(count: 2)); precondition(missing.userMessage.contains("review"))
        checks += 1
        let timed = BatchStub(); timed.timeout = true
        do { _ = try await run(timed, timeout: .zero); fatalError("Pending accepted") }
        catch { precondition(timed.calls.filter { $0.hasSuffix("commit") }.count == 1) }
        checks += 1
        checks += try await imageChecks(pairing: pairing)
        var files: [URL] = []
        let fileStub = BatchStub(); fileStub.count = 1
        let fileClient = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: fileStub.send)
        defer { fileClient.close() }
        _ = try await fileClient.attachBatch(count: 1, id: fileStub.id, prepareFile: { index in
            fileStub.prepared.append(index)
            let file = try ImageFile.stage(Data([1, 2, 3]))
            files.append(file.url)
            return file
        })
        precondition(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }); checks += 1
        let cancelledFile = BatchStub(); cancelledFile.count = 1; cancelledFile.cancelAfterUpload = 0
        let cancelledClient = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: cancelledFile.send)
        defer { cancelledClient.close() }
        let cancelledTask = Task {
            try await cancelledClient.attachBatch(count: 1, id: cancelledFile.id, prepareFile: { index in
                cancelledFile.prepared.append(index)
                let file = try ImageFile.stage(Data([1, 2, 3])); files.append(file.url); return file
            })
        }
        do { _ = try await cancelledTask.value; fatalError("Cancelled file upload committed") } catch { }
        precondition(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        precondition(!cancelledFile.calls.contains { $0.hasSuffix("commit") }); checks += 1
        print("PASS: \(checks) Swift batch sequencing, bounds, cancellation, partial-result, timeout and original-file byte-preservation checks; no network, Codex or clipboard access.")
    }
    // Test-only pixel generation; production diagnostics only identify containers.
    static func fixture(type: UTType, width: Int = 64, height: Int = 32) -> Data {
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic byte-preservation fixture"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Preserve this metadata"]]
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, metadata as CFDictionary)
        precondition(CGImageDestinationFinalize(destination)); return output as Data
    }
    static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while true {
            let read = try autoreleasepool {
                guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
                digest.update(data: chunk); return true
            }
            if !read { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    // A valid private ancillary chunk makes a large PNG without a large bitmap.
    static func writeLargePNG(to url: URL, size: Int) throws {
        let png = fixture(type: .png, width: 1, height: 1)
        let length = size - png.count - 12
        precondition(length > 0)
        try Data(png.dropLast(12)).write(to: url)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) })
        let type = Data("npAD".utf8)
        try file.write(contentsOf: type)
        var crc = type.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(type.count)) }
        let zeroes = Data(repeating: 0, count: 64 * 1024)
        var remaining = length
        while remaining > 0 {
            let chunk = zeroes.prefix(min(remaining, zeroes.count))
            try file.write(contentsOf: chunk)
            crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
            remaining -= chunk.count
        }
        try file.write(contentsOf: withUnsafeBytes(of: UInt32(crc).bigEndian) { Data($0) })
        try file.write(contentsOf: png.suffix(12))
    }
    // UIKit 26.5 synthetic NSItemProvider(item: UIImage, typeIdentifier: public.jpeg) file output.
    // Reproduces a JPEG-advertised binary plist containing PNG bytes, without a phone.
    static let archivedUIImage = Data(base64Encoded: """
        YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEI
        CVRyb290gAGpCwwoKSouMjk9VSRudWxs3g0ODxAREhMUFRYXGBkaGxwcHh8gISIeIyQlIB9bVUlJbWFnZURhdGFfEBRVSUtpdFdh
        bnRzUHJvcGVydGllc15VSUtpdERpZEVuY29kZV8QD1VJUmVuZGVyaW5nTW9kZV8QHFVJSW1hZ2VBY2Nlc3NpYmlsaXR5TGFuZ3Vh
        Z2VcVUlIYXNQYXR0ZXJuXxAWVUlJbWFnZVRyYWl0Q29sbGVjdGlvblYkY2xhc3NfEBJVSUltYWdlT3JpZW50YXRpb25fEBRVSUlt
        YWdlQ29uZmlndXJhdGlvbldVSVNjYWxlXxATVUlJbWFnZVNpemVJblBpeGVsc18QHVVJSW1hZ2VJc0ZsaXBwZWRJblJpZ2h0VG9M
        ZWZ0XxAZVUlJbWFnZUFjY2Vzc2liaWxpdHlMYWJlbIACCQkQAIAACIAFgAiABCI/gAAAgAMIgABPEQFqiVBORw0KGgoAAAANSUhE
        UgAAABgAAAAYCAIAAABvFaqvAAAAAXNSR0IArs4c6QAAAIRlWElmTU0AKgAAAAgABQESAAMAAAABAAEAAAEaAAUAAAABAAAASgEb
        AAUAAAABAAAAUgEoAAMAAAABAAIAAIdpAAQAAAABAAAAWgAAAAAAAABIAAAAAQAAAEgAAAABAAOgAQADAAAAAQABAACgAgAEAAAA
        AQAAABigAwAEAAAAAQAAABgAAAAAEQ8YrgAAAAlwSFlzAAALEwAACxMBAJqcGAAAABxpRE9UAAAAAgAAAAAAAAAMAAAAKAAAAAwA
        AAAMAAAAW3FoSS0AAAAnSURBVDgRYvjHwEAVRB1TgE4ZNYhwCBBWQWScjhpEOAQIqyAysAEAAAD//zQ4a5YAAAAkSURBVGP4x8BA
        FUQdU4BOGTWIcAgQVkFknI4aRDgECKsgMrABTxI7n159H7UAAAAASUVORK5CYIJYezI0LCAyNH3SFCssIV8QEVVJVHJhaXRDb2xs
        ZWN0aW9ugAeABdIvFDAxXxA2VUlUcmFpdENvbGxlY3Rpb25CdWlsdGluVHJhaXQtX1VJVHJhaXROYW1lRGlzcGxheVNjYWxlIz/w
        AAAAAAAAgAbSMzQ1NlokY2xhc3NuYW1lWCRjbGFzc2VzXxARVUlUcmFpdENvbGxlY3Rpb26iNzhfEBFVSVRyYWl0Q29sbGVjdGlv
        blhOU09iamVjdNIzNDo7XxAUVUlJbWFnZUNvbmZpZ3VyYXRpb26iPDhfEBRVSUltYWdlQ29uZmlndXJhdGlvbtIzND4/V1VJSW1h
        Z2WiPjgACAARABoAJAApADIANwBJAEwAUQBTAF0AYwCAAIwAowCyAMQA4wDwAQkBEAElATwBRAFaAXoBlgGYAZkBmgGcAZ4BnwGh
        AaMBpQGqAawBrQGvAx0DJgMrAz8DQQNDA0gDgQOKA4wDkQOcA6UDuQO8A9AD2QPeA/UD+AQPBBQEHAAAAAAAAAIBAAAAAAAAAEAA
        AAAAAAAAAAAAAAAAAAQf
        """, options: .ignoreUnknownCharacters)!
    @MainActor static func imageChecks(pairing: Pairing) async throws -> Int {
        var checks = 0
        let wrapper = try ImageFile.stage(archivedUIImage)
        let plist = try PropertyListSerialization.propertyList(from: archivedUIImage, format: nil) as! [String: Any]
        let embedded = (plist["$objects"] as! [Any])[2] as! Data
        let extracted = try await ImageInput.originalFile(wrapper)
        precondition(extracted !== wrapper, "A JPEG-advertised UIImage archive must yield its embedded file, not the property list")
        let extractedBytes = try Data(contentsOf: extracted.url)
        precondition(extractedBytes == embedded, "Archive extraction must preserve every encoded image byte")
        let archiveStub = BatchStub(); archiveStub.count = 1; archiveStub.expectedHashes[0] = try fileHash(extracted.url)
        let archiveClient = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: archiveStub.send)
        defer { archiveClient.close() }
        let archiveJob = try await archiveClient.attachBatch(count: 1, id: archiveStub.id, prepareFile: { index in
            archiveStub.prepared.append(index); return extracted
        })
        precondition(archiveJob.allVerified(count: 1), "Recovered archive payload must upload and commit normally")
        checks += 3
        var archiveVariants: [Data] = [Data("bplist00truncated".utf8),
            try PropertyListSerialization.data(fromPropertyList: ["image": embedded], format: .binary, options: 0)]
        for variant in ["rotated", "mirrored", "animated", "missing payload", "wrong payload type", "non-image payload", "unexpected class"] {
            var changed = plist
            var objects = plist["$objects"] as! [Any]
            var imageObject = objects[1] as! [String: Any]
            switch variant {
            case "rotated": imageObject["UIImageOrientation"] = 3
            case "mirrored": imageObject["UIImageOrientation"] = 4
            case "animated": imageObject["UIImageImages"] = imageObject["UIImageData"]
            case "missing payload": imageObject.removeValue(forKey: "UIImageData")
            case "wrong payload type": objects[2] = "Not image bytes"
            case "non-image payload": objects[2] = Data("opaque text must not become an image".utf8)
            default:
                objects[8] = ["$classname": NSStringFromClass(ArchiveDecodeTrap.self),
                              "$classes": [NSStringFromClass(ArchiveDecodeTrap.self), "NSObject"]]
            }
            objects[1] = imageObject; changed["$objects"] = objects
            archiveVariants.append(try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0))
        }
        for bytes in archiveVariants {
            let file = try ImageFile.stage(bytes)
            do { _ = try await ImageInput.originalFile(file); fatalError("Unsafe or unsupported archive accepted") }
            catch { precondition((error as? ReceiverError)?.isUnsupportedImageFormat == true) }
            checks += 1
        }
        let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA==")!
        let fixtures = [("PNG", fixture(type: .png)), ("JPEG", fixture(type: .jpeg)),
                        ("HEIC", fixture(type: .heic)), ("GIF", fixture(type: .gif)), ("WebP", webp),
                        ("3024x4032 JPEG", fixture(type: .jpeg, width: 3024, height: 4032)),
                        ("opaque receiver-validated bytes", Data("not decoded on the phone".utf8))]
        for (name, bytes) in fixtures {
            let providerFile = ImageFile.temporaryURL()
            try bytes.write(to: providerFile)
            let sourceHash = try fileHash(providerFile)
            let copied = try ImageFile.copy(from: providerFile)
            try FileManager.default.removeItem(at: providerFile)
            let original = try await ImageInput.originalFile(copied)
            precondition(original === copied && original.byteCount == bytes.count, name)
            let copiedHash = try fileHash(original.url)
            precondition(sourceHash == copiedHash, "File copy changed " + name)
            let stub = BatchStub(); stub.count = 1; stub.expectedHashes[0] = sourceHash
            let client = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: stub.send)
            defer { client.close() }
            _ = try await client.attachBatch(count: 1, id: stub.id, prepareFile: { index in stub.prepared.append(index); return original })
            checks += 1
        }
        precondition(ImageInput.originalTypeIdentifier(in: [UTType.image.identifier, UTType.heic.identifier, UTType.jpeg.identifier]) == UTType.jpeg.identifier,
                     "Choose a supplied Codex-compatible representation before an unsupported image type")
        precondition(ImageInput.originalTypeIdentifier(in: [UTType.jpeg.identifier, UTType.png.identifier]) == UTType.jpeg.identifier)
        precondition(ImageInput.originalTypeIdentifier(in: [UTType.image.identifier, "com.apple.uikit.image"]) == nil)
        checks += 3
        for unsupported in [UTType.heic.identifier, UTType.tiff.identifier, "public.avif"] {
            precondition(ImageInput.originalTypeIdentifier(in: [unsupported, UTType.png.identifier]) == UTType.png.identifier,
                         "Unsupported first representation hid an available PNG: " + unsupported)
            checks += 1
        }
        for supported in [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier] {
            precondition(ImageInput.originalTypeIdentifier(in: [UTType.heic.identifier, supported]) == supported)
            checks += 1
        }
        precondition(ImageInput.originalTypeIdentifier(in: [UTType.image.identifier, UTType.heic.identifier]) == UTType.heic.identifier,
                     "Unsupported-only shares must still reach the receiver's format refusal without conversion")
        checks += 1
        let diagnosticImage = try ImageFile.stage(fixture(type: .tiff))
        let diagnostic = ImageInput.formatDiagnostic(of: diagnosticImage, requestedType: UTType.png.identifier,
                                                     offeredTypes: [UTType.png.identifier, UTType.tiff.identifier, "private filename / path"])
        precondition(diagnostic.contains("Detected: public.tiff"), "Identify supplied bytes even when the provider advertises PNG")
        precondition(diagnostic.contains("Requested: public.png") && diagnostic.contains("Offered: public.png, public.tiff"))
        precondition(!diagnostic.contains("private filename") && !diagnostic.contains("Synthetic") && !diagnostic.contains(diagnosticImage.url.path))
        checks += 3
        for (header, expected) in [(Data("bplist00private content".utf8), "binary property list"),
                                   (Data([0xff, 0x0a, 0, 0]), "JPEG XL"),
                                   (Data("private unknown file content".utf8), "unrecognized")] {
            let file = try ImageFile.stage(header)
            let description = ImageInput.formatDiagnostic(of: file, requestedType: nil, offeredTypes: [])
            precondition(description.contains("Detected: " + expected))
            precondition(!description.contains("private"))
            checks += 1
        }
        do { _ = try ImageFile.stage(Data()); fatalError("Empty file accepted") } catch { checks += 1 }
        do { _ = try ImageFile.stage(Data(repeating: 1, count: ImageInput.maximumBytes + 1)); fatalError("Over50 MiB accepted") }
        catch { precondition(error.localizedDescription.contains("50 MiB")); checks += 1 }
        let paddedURL = ImageFile.temporaryURL()
        defer { try? FileManager.default.removeItem(at: paddedURL) }
        try writeLargePNG(to: paddedURL, size: 21 * 1024 * 1024)
        let padded = try ImageFile.copy(from: paddedURL)
        let unchanged = try await ImageInput.originalFile(padded)
        let beforeHash = try fileHash(paddedURL), afterHash = try fileHash(unchanged.url)
        precondition(beforeHash == afterHash); checks += 1
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("codex-drop-image-") })
        do { _ = try ImageFile.copy(from: paddedURL, cancelled: { true }); fatalError("Cancelled copy accepted") }
        catch is CancellationError { checks += 1 }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("codex-drop-image-") })
        precondition(before == after)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await ImageInput.originalFile(padded) }
        do { _ = try await cancelled.value; fatalError("Cancelled original preparation accepted") } catch is CancellationError { checks += 1 }
        return checks
    }
}
