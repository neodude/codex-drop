import Foundation
import CoreFoundation

// Limits apply to original encoded files. Metadata checks never decode pixels.
enum ImageLimits {
    static let maxBytes = 50 * 1024 * 1024
    static let maxBatchBytes = 100 * 1024 * 1024
    static let maxBatchCount = 10
}

enum OriginalImageType: String {
    case png, jpeg, gif, webp
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
}

struct OriginalImage {
    let data: Data
    let fileURL: URL
    let type: OriginalImageType
}

// Only the empty-document decoration from Codex's editor may be excluded.
// Typed text, including words identical to a hint, retains its exact bytes.
struct DraftAXNode {
    var role: String
    var placeholder: Bool = false
    var text: String? = nil
    var children: [Int] = []
}

enum ComposerDraft {
    static func capture(raw: String, nodes: [DraftAXNode]) -> Data {
        let original = Data(raw.utf8)
        guard !nodes.isEmpty, nodes.count <= 128, nodes[0].role == "AXTextArea" else { return original }
        let placeholders = nodes.indices.filter { nodes[$0].placeholder }
        guard placeholders.count == 1, let placeholder = placeholders.first, placeholder != 0 else { return original }
        // The placeholder must be the editor's only content branch.
        var cursor = 0, visited = Set<Int>()
        while cursor != placeholder {
            guard visited.insert(cursor).inserted,
                  cursor == 0 || ["AXGroup", "AXParagraph"].contains(nodes[cursor].role),
                  nodes[cursor].children.count == 1,
                  let child = nodes[cursor].children.first, nodes.indices.contains(child) else { return original }
            cursor = child
        }
        var stack = [placeholder], hint = ""
        while let index = stack.popLast() {
            guard nodes.indices.contains(index), visited.insert(index).inserted else { return original }
            let node = nodes[index]
            guard ["AXGroup", "AXParagraph", "AXStaticText", "AXLineBreak"].contains(node.role) else { return original }
            if node.role == "AXStaticText" {
                guard node.children.isEmpty, let text = node.text else { return original }
                hint += text
            } else if node.role == "AXLineBreak" {
                guard node.children.isEmpty else { return original }
                hint += "\n"
            }
            stack.append(contentsOf: node.children.reversed())
        }
        guard visited.count == nodes.count,
              raw == hint || raw == hint + "\n" || raw == "\n" else { return original }
        return Data()
    }
}

// Best-effort OS metadata for a more specific refusal only. Unknown metadata
// provides no evidence of an unlocked session; all composer guards still apply.
enum MacSessionLockState {
    case locked, unlocked, unknown

    static func parse(_ value: Any?) -> MacSessionLockState {
        guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else { return .unknown }
        return boolean.boolValue ? .locked : .unlocked
    }
}

// AX focused/main-window values can be absent while application activation is
// asynchronous. A missing value is distinct from an available different window.
enum ActivationWindowIdentity { case same, unavailable, changed }

struct ComposerActivationObservation {
    var window: ActivationWindowIdentity
    var foregroundReady: Bool
    var contentUnchanged: Bool
    var diagnostics: [String: String] = [:]
}

enum ComposerActivationGuard {
    static func waitUntilReady(now: () -> TimeInterval, wait: (TimeInterval) -> Void,
                               timeout: TimeInterval = 1,
                               observe: () throws -> ComposerActivationObservation) throws {
        let deadline = now() + timeout
        while true {
            let state = try observe()
            // Never reacquire a window/editor or tolerate a readable mismatch.
            guard state.window != .changed, state.contentUnchanged else {
                throw DeliveryRefusal(reason: "composer_changed_during_activation", diagnostics: state.diagnostics)
            }
            if state.window == .same && state.foregroundReady { return }
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw DeliveryRefusal(reason: state.foregroundReady ? "composer_window_unavailable_after_activation" : "codex_activation_not_confirmed",
                                      diagnostics: state.diagnostics)
            }
            wait(min(0.02, remaining))
        }
    }
}

struct ComposerSnapshot {
    let target: String
    let draft: Data
    let selectionEmpty: Bool
    let attachments: [String: Int]
    var metadata: [String: String] = [:]
}

struct DeliveryResult: Codable {
    var status: String
    var reason: String
    var pasteAttempted: Bool
    var clipboardRead: Bool?
    var clipboardRestoration: String = "not_staged"
    var elapsedMS: Int = 0
    var diagnostics: [String: String]? = nil
    var items: [BatchItemResult]? = nil
    var verifiedCount: Int? = nil
    var totalCount: Int? = nil
}

struct BatchItemResult: Codable {
    var index: Int
    var status: String
    var reason: String
    var pasteAttempted: Bool
    var clipboardRestoration: String
    var elapsedMS: Int
    init(index: Int, result: DeliveryResult) {
        self.index = index; status = result.status; reason = result.reason
        pasteAttempted = result.pasteAttempted
        clipboardRestoration = result.clipboardRestoration; elapsedMS = result.elapsedMS
    }
}

protocol DeliveryAdapter: AnyObject {
    var now: TimeInterval { get }
    var clipboardOwned: Bool { get }
    var clipboardRead: Bool? { get }
    func observe() throws -> ComposerSnapshot
    func prepare() throws
    func stage(_ image: OriginalImage) throws
    func paste() throws
    func restore() -> String
    func wait(_ interval: TimeInterval)
}

enum DeliveryEngine {
    static func runBatch(images: [OriginalImage], adapter: DeliveryAdapter, timeout: TimeInterval = 8,
                         willPaste: (Int) throws -> Void = { _ in }) -> DeliveryResult {
        let started = adapter.now
        guard (1...ImageLimits.maxBatchCount).contains(images.count), images.reduce(0, { $0 + $1.data.count }) <= ImageLimits.maxBatchBytes else {
            return DeliveryResult(status: "blocked", reason: "invalid_batch", pasteAttempted: false,
                                  elapsedMS: 0, items: [], verifiedCount: 0, totalCount: images.count)
        }
        var results: [BatchItemResult] = [], failure: DeliveryResult?
        do {
            let bound = BatchBoundAdapter(base: adapter, anchor: try adapter.observe())
            for (index, image) in images.enumerated() {
                let result = run(image: image, adapter: bound, timeout: timeout) { try willPaste(index) }
                results.append(BatchItemResult(index: index, result: result))
                guard result.status == "verified" else { failure = result; break }
                // Last successful observation is before clipboard restoration; a later
                // missing thumbnail must not silently become the next item's baseline.
                bound.minimumAttachments = bound.lastSnapshot.attachments
            }
        } catch let refusal as DeliveryRefusal {
            failure = DeliveryResult(status: "blocked", reason: refusal.reason, pasteAttempted: false, diagnostics: refusal.diagnostics)
        } catch {
            failure = DeliveryResult(status: "blocked", reason: "batch_preflight_failed", pasteAttempted: false)
        }
        if results.isEmpty, let failure { results.append(BatchItemResult(index: 0, result: failure)) }
        while results.count < images.count {
            results.append(BatchItemResult(index: results.count,
                result: DeliveryResult(status: "not_attempted", reason: "earlier_item_unconfirmed", pasteAttempted: false)))
        }
        let attempted = results.contains { $0.pasteAttempted }
        let verified = results.filter { $0.status == "verified" }.count
        let status = verified == images.count ? "verified" : attempted ? "uncertain" : "blocked"
        let restorations = results.map(\.clipboardRestoration)
        let restoration = restorations.contains("failed") ? "failed" : restorations.contains("newer_preserved") ? "newer_preserved" : restorations.contains("restored") ? "restored" : "not_staged"
        return DeliveryResult(status: status, reason: failure?.reason ?? "batch_attached", pasteAttempted: attempted,
            clipboardRestoration: restoration, elapsedMS: Int((adapter.now - started) * 1000),
            diagnostics: failure?.diagnostics, items: results, verifiedCount: verified, totalCount: images.count)
    }

    private static func draftDifference(_ before: Data, _ after: Data) -> [String: String] {
        let a = Array(before), b = Array(after)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        func kind(_ bytes: ArraySlice<UInt8>) -> String {
            if bytes.isEmpty { return "empty" }
            if bytes.allSatisfy({ [9, 10, 13, 32].contains($0) }) { return "whitespace" }
            if String(decoding: bytes, as: UTF8.self).unicodeScalars.allSatisfy({ $0.value == 0xfffc }) { return "attachment_placeholder" }
            return "other"
        }
        let removed = a[prefix..<(a.count - suffix)], inserted = b[prefix..<(b.count - suffix)]
        return ["draftBeforeBytes": String(a.count), "draftAfterBytes": String(b.count),
                "removedBytes": String(removed.count), "insertedBytes": String(inserted.count),
                "removedKind": kind(removed), "insertedKind": kind(inserted)]
    }
    static func run(image: OriginalImage, adapter: DeliveryAdapter, timeout: TimeInterval = 8,
                    willPaste: () throws -> Void = {}) -> DeliveryResult {
        let started = adapter.now
        var staged = false, attempted = false
        func outcome(_ status: String, _ reason: String) -> DeliveryResult {
            DeliveryResult(status: status, reason: reason, pasteAttempted: attempted, clipboardRead: adapter.clipboardRead)
        }
        func execute() throws -> DeliveryResult {
            let before = try adapter.observe()
            guard before.selectionEmpty else { return outcome("blocked", "selected_or_unreadable_selection") }
            try adapter.prepare()
            staged = true // stage can fail after acquiring clipboard ownership.
            try adapter.stage(image)
            let ready = try adapter.observe()
            guard ready.target == before.target else { return outcome("blocked", "target_changed_before_paste") }
            guard ready.draft == before.draft && ready.attachments == before.attachments && ready.selectionEmpty else {
                return outcome("blocked", "draft_changed_before_paste")
            }
            guard adapter.clipboardOwned else { return outcome("blocked", "clipboard_changed_before_paste") }
            try willPaste() // Durable attempt intent must precede the external action.
            let final = try adapter.observe()
            guard final.target == before.target && final.draft == before.draft &&
                    final.attachments == before.attachments && final.selectionEmpty else {
                return outcome("blocked", "target_changed_during_journal")
            }
            guard adapter.clipboardOwned else { return outcome("blocked", "clipboard_changed_during_journal") }
            attempted = true
            try adapter.paste()
            let deadline = adapter.now + min(max(timeout, 0.2), 30)
            var stableSamples = 0
            while adapter.now < deadline {
                let current = try adapter.observe()
                guard current.target == before.target else { return outcome("uncertain", "target_changed_after_paste") }
                guard current.draft == before.draft else {
                    var result = outcome("uncertain", "draft_changed_after_paste")
                    result.diagnostics = draftDifference(before.draft, current.draft)
                    for (key, value) in current.metadata { result.diagnostics?[key] = value }
                    // Read-only diagnostic sampling. This never upgrades the outcome,
                    // rewrites the draft, or retries Paste. No draft bytes are logged.
                    var samples = ""
                    for _ in 0..<3 {
                        adapter.wait(0.1)
                        guard let next = try? adapter.observe(), next.target == before.target else { samples += "unavailable;"; break }
                        samples += next.draft == before.draft ? "original;" : "different(\(next.draft.count));"
                    }
                    result.diagnostics?["draftFollowupSamples"] = samples
                    return result
                }
                guard adapter.clipboardOwned else { return outcome("uncertain", "clipboard_changed_after_paste") }
                guard before.attachments.allSatisfy({ current.attachments[$0.key, default: 0] >= $0.value }) else {
                    return outcome("uncertain", "existing_attachment_disappeared")
                }
                let added = current.attachments.reduce(0) { $0 + max(0, $1.value - before.attachments[$1.key, default: 0]) }
                let addedImages = current.attachments.reduce(0) {
                    $0 + (OriginalImageType.supportedExtensions.contains(URL(fileURLWithPath: $1.key).pathExtension.lowercased()) ? max(0, $1.value - before.attachments[$1.key, default: 0]) : 0)
                }
                guard added <= 1 else { return outcome("uncertain", "unexpected_multiple_attachments") }
                stableSamples = added == 1 && addedImages == 1 ? stableSamples + 1 : 0
                if stableSamples >= 2 { return outcome("verified", "attachment_observed") }
                adapter.wait(0.1)
            }
            return outcome("uncertain", "attachment_acknowledgement_timeout")
        }
        var result: DeliveryResult
        do { result = try execute() }
        catch let failure as DeliveryRefusal {
            result = outcome(attempted ? "uncertain" : "blocked", failure.reason)
            result.diagnostics = failure.diagnostics
        }
        catch { result = outcome(attempted ? "uncertain" : "blocked", "adapter_or_journal_error") }
        if staged {
            result.clipboardRestoration = adapter.restore()
            if result.clipboardRestoration == "failed" {
                result.status = attempted ? "uncertain" : "blocked"
                result.reason = "clipboard_restoration_failed"
            }
        }
        result.elapsedMS = Int((adapter.now - started) * 1000)
        return result
    }
}

private final class BatchBoundAdapter: DeliveryAdapter {
    let base: DeliveryAdapter
    let anchor: ComposerSnapshot
    var lastSnapshot: ComposerSnapshot
    var minimumAttachments: [String: Int]
    init(base: DeliveryAdapter, anchor: ComposerSnapshot) {
        self.base = base; self.anchor = anchor; lastSnapshot = anchor; minimumAttachments = anchor.attachments
    }
    var now: TimeInterval { base.now }
    var clipboardOwned: Bool { base.clipboardOwned }
    var clipboardRead: Bool? { base.clipboardRead }
    func observe() throws -> ComposerSnapshot {
        let current = try base.observe()
        guard current.target == anchor.target else { throw DeliveryRefusal(reason: "batch_target_changed") }
        guard current.draft == anchor.draft else { throw DeliveryRefusal(reason: "batch_draft_changed") }
        guard minimumAttachments.allSatisfy({ current.attachments[$0.key, default: 0] >= $0.value }) else {
            throw DeliveryRefusal(reason: "batch_previous_attachment_disappeared")
        }
        lastSnapshot = current
        return current
    }
    func prepare() throws { try base.prepare() }
    func stage(_ image: OriginalImage) throws { try base.stage(image) }
    func paste() throws { try base.paste() }
    func restore() -> String { base.restore() }
    func wait(_ interval: TimeInterval) { base.wait(interval) }
}

struct DeliveryRefusal: Error {
    let reason: String
    var diagnostics: [String: String]? = nil
}
