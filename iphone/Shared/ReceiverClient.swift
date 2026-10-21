import Foundation
import CryptoKit
import Security

struct DeliveryJob: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let index: Int
            let status: String
            let reason: String?
            let pasteAttempted: Bool?
            let clipboardRestoration: String?
            let elapsedMS: Int?
        }
        let reason: String?
        let pasteAttempted: Bool?
        let items: [Item]?
        let verifiedCount: Int?
        let totalCount: Int?
    }
    let id: String
    let state: String
    let result: Result?

    func allVerified(count: Int) -> Bool {
        guard state == "verified", let result, result.verifiedCount == count,
              result.totalCount == count, let items = result.items, items.count == count else { return false }
        return items.map(\.index).sorted() == Array(0..<count) && items.allSatisfy { $0.status == "verified" }
    }
    var userMessage: String {
        let permissionNeeded = result?.reason == "accessibility_permission_required" || result?.items?.contains { $0.reason == "accessibility_permission_required" } == true
        let unlockNeeded = result?.reason == "mac_screen_locked" || result?.items?.contains { $0.reason == "mac_screen_locked" } == true
        let unlockHelp = "Unlock your Mac to attach screenshots."
        let permissionHelp = "Allow Codex Drop in Mac System Settings → Privacy & Security → Accessibility, then share again."
        guard let result, let count = result.totalCount, let verified = result.verifiedCount,
              (1...10).contains(count), (0...count).contains(verified), let items = result.items,
              items.count == count, items.map(\.index).sorted() == Array(0..<count),
              items.filter({ $0.status == "verified" }).count == verified else {
            return (unlockNeeded ? unlockHelp + "\n" : "") + (permissionNeeded ? permissionHelp + "\n" : "") + "Delivery needs review on the Mac. Images may already be attached. Check before sharing again. No automatic retry."
        }
        if allVerified(count: count) { return "Attached \(count) \(count == 1 ? "image" : "images"). Message not sent." }
        var lines = unlockNeeded ? [unlockHelp] : []
        lines.append("\(verified) of \(count) images verified attached.")
        for item in items.sorted(by: { $0.index < $1.index }) where item.status != "verified" {
            switch item.status {
            case "uncertain": lines.append("Image \(item.index + 1): uncertain; it may already be attached.")
            case "blocked": lines.append(item.pasteAttempted == false
                ? "Image \(item.index + 1): blocked before attachment."
                : "Image \(item.index + 1): unconfirmed; check whether it is attached.")
            case "not_attempted": lines.append("Image \(item.index + 1): not tried.")
            default: lines.append("Image \(item.index + 1): needs review on the Mac.")
            }
        }
        if permissionNeeded { lines.append(permissionHelp) }
        lines.append("Check the Mac before sharing again. Do not resend images already attached. No automatic retry.")
        return lines.joined(separator: "\n")
    }
}

enum BatchProgress {
    case preparing(Int, Int), uploading(Int, Int), committing, confirming
}

// URLSession calls this delegate on its own queue. Its only stored state is
// immutable Sendable data; no UI or actor state crosses that boundary.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let pin: String
    init(pin: String) { self.pin = pin }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard actual == pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the paired bearer credential to a redirect.
    }
}

@MainActor final class ServiceResolver: NSObject, @preconcurrency NetServiceDelegate {
    private var service: NetService?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var deadline: Timer?
    func resolve(_ name: String, timeout: TimeInterval = 5) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let service = NetService(domain: "local.", type: "_codexshot._tcp.", name: name)
                self.service = service; service.delegate = self
                deadline = Timer.scheduledTimer(withTimeInterval: timeout + 1, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.finish(.failure(ReceiverError.message("Mac not found. Use the same Wi-Fi and start the receiver."))) }
                }
                service.resolve(withTimeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { finish(.failure(ReceiverError.message("Mac has no reachable address."))); return }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.port = sender.port
        guard let url = parts.url else { finish(.failure(ReceiverError.message("Mac returned an invalid address."))); return }
        finish(.success(url))
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.intValue ?? 0
        finish(.failure(ReceiverError.message("Mac discovery failed (Bonjour \(domain)/\(code)). Check the receiver, Wi-Fi and Local Network permission.")))
    }
    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.invalidate(); deadline = nil
        service?.delegate = nil; service?.stop(); service = nil
        continuation.resume(with: result)
    }
}

@MainActor final class ReceiverClient {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, Int)
    private let pairing: Pairing
    private let session: URLSession
    private let baseURL: URL?
    private let transport: Transport?
    private let pollTimeout: Duration
    init(pairing: Pairing, baseURL: URL? = nil, transport: Transport? = nil, pollTimeout: Duration = .seconds(120)) {
        self.pairing = pairing; self.baseURL = baseURL; self.transport = transport; self.pollTimeout = pollTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.urlCache = nil
        session = URLSession(configuration: config, delegate: PinnedSessionDelegate(pin: pairing.pin), delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    private func request(_ base: URL, path: String, body: Data? = nil, id: String? = nil,
                         contentType: String = "application/json", timeout: TimeInterval = 10) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(id, forHTTPHeaderField: "X-Request-ID")
        }
        let data: Data, code: Int
        if let transport { (data, code) = try await transport(request) }
        else {
            let (received, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ReceiverError.message("The Mac returned an invalid response.") }
            data = received; code = response.statusCode
        }
        if code == 401 { throw ReceiverError.message("Pairing was rejected. Scan the Mac's QR code again.") }
        return (data, code)
    }
    func checkConnection() async throws {
        let base = try await ServiceResolver().resolve(pairing.service, timeout: 20)
        let (_, code) = try await request(base, path: "v1/jobs/00000000-0000-0000-0000-000000000000")
        guard code == 404 else { throw ReceiverError.message("The Mac receiver did not answer as expected.") }
    }
    func attachBatch(count: Int, id: String, prepare: (Int) async throws -> Data,
                     progress: (BatchProgress) -> Void = { _ in },
                     timing: (String, Int) -> Void = { _, _ in }) async throws -> DeliveryJob {
        guard (1...10).contains(count), UUID(uuidString: id)?.uuidString.lowercased() == id else {
            throw ReceiverError.message("Share 1–10 images in one new request.")
        }
        try Task.checkCancellation()
        let lookupStarted = ProcessInfo.processInfo.systemUptime
        let base: URL
        if let baseURL { base = baseURL } else { base = try await ServiceResolver().resolve(pairing.service) }
        timing("Finding Mac", Int((ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000))
        struct Receipt: Decodable { let received: Bool; let job: DeliveryJob }
        func receipt(_ response: (Data, Int)) throws -> DeliveryJob {
            guard response.1 == 200 || response.1 == 202 else {
                throw ReceiverError.message("The Mac refused the request (HTTP \(response.1)). No automatic retry.")
            }
            let value = try JSONDecoder().decode(Receipt.self, from: response.0)
            guard value.received, value.job.id == id else { throw ReceiverError.message("The Mac returned an invalid receipt.") }
            return value.job
        }
        _ = try receipt(await request(base, path: "v1/batches", body: JSONEncoder().encode(["count": count]), id: id))
        var totalBytes = 0, preparingMS = 0, uploadMS = 0
        for index in 0..<count {
            try Task.checkCancellation()
            progress(.preparing(index, count))
            let preparedAt = ProcessInfo.processInfo.systemUptime
            // Scope each PNG to one upload. Never accumulate the batch's image data.
            do {
                let png = try await prepare(index)
                preparingMS += Int((ProcessInfo.processInfo.systemUptime - preparedAt) * 1000)
                try Task.checkCancellation()
                guard !png.isEmpty, png.count <= 20 * 1024 * 1024 else {
                    throw ReceiverError.message("Each image must be at most 20 MiB.")
                }
                totalBytes += png.count
                guard totalBytes <= 100 * 1024 * 1024 else { throw ReceiverError.message("The batch must be at most 100 MiB.") }
                progress(.uploading(index, count))
                let uploadAt = ProcessInfo.processInfo.systemUptime
                _ = try receipt(await request(base, path: "v1/batches/" + id + "/images/\(index)", body: png, contentType: "image/png"))
                uploadMS += Int((ProcessInfo.processInfo.systemUptime - uploadAt) * 1000)
            }
        }
        timing("Preparing images", preparingMS); timing("Upload", uploadMS)
        // Last cancellation gate: staged uploads cannot paste until this commit.
        try Task.checkCancellation()
        progress(.committing)
        var job = try receipt(await request(base, path: "v1/batches/" + id + "/commit", body: Data("{}".utf8)))
        progress(.confirming)
        let confirmationStarted = ProcessInfo.processInfo.systemUptime
        let deadline = ContinuousClock.now + pollTimeout
        while job.state == "queued" || job.state == "running" {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw ReceiverError.message("The Mac received the batch, but attachment is not confirmed. Check the Mac before sharing again. No automatic retry.") }
            try await Task.sleep(for: min(.milliseconds(180), remaining))
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { throw ReceiverError.message("Attachment confirmation timed out. Check the Mac before sharing again. No automatic retry.") }
            let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
            let (next, status) = try await request(base, path: "v1/jobs/" + id, timeout: min(10, seconds))
            guard status == 200 else { throw ReceiverError.message("Could not confirm the attachments. Check the Mac before sharing again. No automatic retry.") }
            job = try JSONDecoder().decode(DeliveryJob.self, from: next)
            guard job.id == id else { throw ReceiverError.message("The Mac returned the wrong job. Check attachments before sharing again.") }
        }
        timing("Confirmation", Int((ProcessInfo.processInfo.systemUptime - confirmationStarted) * 1000))
        return job
    }
}
