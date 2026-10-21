import Foundation

@main struct ClientChecks {
    @MainActor static func main() async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
        let code = config["code"]!
        let pairing = try Pairing.parse(code)
        var checks = 1
        for text in ["https://example.com/?token=secret", "codexshot://pair?data=bad", code + "&extra=1"] {
            do { _ = try Pairing.parse(text); throw ReceiverError.message("Invalid pairing was accepted") }
            catch is DecodingError { checks += 1 }
            catch let error as ReceiverError {
                if error.localizedDescription == "Invalid pairing was accepted" { throw error }; checks += 1
            }
        }
        let base = URL(string: config["url"]!)!
        let good = URLSession(configuration: .ephemeral, delegate: PinnedSessionDelegate(pin: pairing.pin), delegateQueue: nil)
        defer { good.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("v1/jobs"))
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await good.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReceiverError.message("Pinned TLS/auth request failed") }
        checks += 1
        let bad = URLSession(configuration: .ephemeral, delegate: PinnedSessionDelegate(pin: String(repeating: "0", count: 64)), delegateQueue: nil)
        defer { bad.invalidateAndCancel() }
        do {
            _ = try await bad.data(for: request)
            throw ReceiverError.message("Wrong certificate pin was accepted")
        } catch let error as ReceiverError { throw error }
        catch { checks += 1 }
        let delegate = PinnedSessionDelegate(pin: pairing.pin)
        var refusedRedirect = false
        delegate.urlSession(good, task: good.dataTask(with: request), willPerformHTTPRedirection: HTTPURLResponse(url: base, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://example.com")!)) { next in refusedRedirect = next == nil }
        guard refusedRedirect else { throw ReceiverError.message("Redirect was accepted") }; checks += 1
        print("PASS: \(checks) Swift pairing/pinned TLS/redirect checks; no Codex or clipboard access.")
    }
}
