import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor final class BatchStub {
    var calls: [String] = []
    var prepared: [Int] = []
    var failUpload: Int?
    var cancelAfterUpload: Int?
    var prepareFailure: Int?
    var pendingPolls = 0
    var receiptID: String?
    var received = true
    var terminal = "verified"
    var timeout = false
    var count = 2
    let id = "11111111-1111-1111-1111-111111111111"
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.path
        calls.append(path)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "b", count: 32))
        if path.hasSuffix("commit") { precondition(request.httpBody == Data("{}".utf8)) }
        if path.contains("/jobs/") { pendingPolls = max(0, pendingPolls - 1) }
        if path == "/v1/batches" {
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            precondition(request.value(forHTTPHeaderField: "X-Request-ID") == id)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
            precondition(body["count"] == count)
        }
        if let last = path.split(separator: "/").last, let index = Int(last) {
            precondition(prepared == Array(0...index), "Preparation must alternate with upload")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
            if failUpload == index { return (Data(), 409) }
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
        let pairing = Pairing(v: 1, service: "unused", pin: String(repeating: "a", count: 64), token: String(repeating: "b", count: 32))
        var checks = 0
        func run(_ stub: BatchStub, size: Int = 3, timeout: Duration = .seconds(120)) async throws -> DeliveryJob {
            let client = ReceiverClient(pairing: pairing, baseURL: URL(string: "https://test.invalid")!, transport: stub.send, pollTimeout: timeout)
            defer { client.close() }
            return try await client.attachBatch(count: stub.count, id: stub.id, prepare: { index in
                stub.prepared.append(index)
                if stub.prepareFailure == index { throw ReceiverError.message("Fixture preparation rejected") }
                return Data(repeating: 1, count: size)
            })
        }
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
        let oversize = BatchStub()
        do { _ = try await run(oversize, size: 20 * 1024 * 1024 + 1); fatalError("Oversize accepted") }
        catch { precondition(oversize.calls == ["/v1/batches"]) }
        checks += 1
        let total = BatchStub(); total.count = 6
        do { _ = try await run(total, size: 20 * 1024 * 1024); fatalError("Batch oversize accepted") }
        catch { precondition(total.calls.count == 6); precondition(!total.calls.contains { $0.hasSuffix("commit") }) }
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
        let missing = try JSONDecoder().decode(DeliveryJob.self, from: Data("{\"id\":\"x\",\"state\":\"verified\"}".utf8))
        precondition(!missing.allVerified(count: 2)); precondition(missing.userMessage.contains("review"))
        checks += 1
        let timed = BatchStub(); timed.timeout = true
        do { _ = try await run(timed, timeout: .zero); fatalError("Pending accepted") }
        catch { precondition(timed.calls.filter { $0.hasSuffix("commit") }.count == 1) }
        checks += 1
        let pixel = makePNG(width: 1, height: 1)
        let preserved = try await ImageEncoder.png(pixel)
        precondition(preserved == pixel)
        checks += 1
        do { _ = try await ImageEncoder.png(Data()); fatalError("Empty image accepted") } catch { checks += 1 }
        do { _ = try await ImageEncoder.png(Data(repeating: 0, count: 20 * 1024 * 1024 + 1)); fatalError("Large input accepted") } catch { checks += 1 }
        let tooManyPixels = makePNG(width: 4000, height: 3001)
        do { _ = try await ImageEncoder.png(tooManyPixels); fatalError("Over 12 MP accepted") } catch { checks += 1 }
        print("PASS: \(checks) Swift batch sequencing, bounds, cancellation, partial-result, timeout and image-encoder checks; no network, Codex or clipboard access.")
    }
    static func makePNG(width: Int, height: Int) -> Data {
        let bytes = Data(repeating: 0, count: width * height * 4)
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

}
