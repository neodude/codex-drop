import Foundation

enum TestFailure: Error { case expected }

final class BatchFakeAdapter: DeliveryAdapter {
    var now: TimeInterval = 0
    var clipboardOwned = true
    var clipboardRead: Bool? = nil
    var pastes = 0, restores = 0
    var scenario = "success"
    var attached = ["Remove image.png": 2, "Remove existing.pdf": 1]
    private var pastedAt: TimeInterval = 0
    private var acknowledged = false
    func observe() throws -> ComposerSnapshot {
        if scenario == "preflight_diagnostics" {
            throw DeliveryRefusal(reason: "composer_changed_during_focus", diagnostics: ["draftSame": "false", "windowObjectSame": "true"])
        }
        if pastes > 0 && !acknowledged && now - pastedAt >= 0.1 && !(scenario == "uncertain_second" && pastes == 2) {
            attached["Remove image.png", default: 0] += 1; acknowledged = true
        }
        return ComposerSnapshot(target: scenario == "target_between" && restores > 0 ? "other" : "original",
            draft: Data((scenario == "draft_between" && restores > 0 ? "edited" : "existing draft").utf8),
            selectionEmpty: true, attachments: attached)
    }
    func prepare() throws {
        if scenario == "cancel_second" && restores > 0 { throw DeliveryRefusal(reason: "interrupted") }
    }
    func stage(_ png: Data) throws { clipboardOwned = true }
    func paste() throws { pastes += 1; pastedAt = now; acknowledged = false }
    func restore() -> String {
        restores += 1
        if scenario == "previous_image_lost" && restores == 1 { attached["Remove image.png", default: 0] -= 1 }
        return clipboardOwned ? "restored" : "newer_preserved"
    }
    func wait(_ interval: TimeInterval) {
        now += interval
        if scenario == "clipboard_second" && pastes == 2 { clipboardOwned = false }
    }
}

final class FakeAdapter: DeliveryAdapter {
    var now: TimeInterval = 0
    var clipboardOwned = true
    var clipboardRead: Bool? = nil
    var observations = 0
    var pastes = 0
    var restores = 0
    var staged = false
    var scenario = "success"
    var originalDraft = "draft\n🧗"
    var existing = ["Remove existing.pdf": 1]

    func observe() throws -> ComposerSnapshot {
        observations += 1
        let afterPaste = pastes > 0
        let newCount = afterPaste && (scenario != "missing_ack") && now >= (scenario == "delayed" ? 3.5 : 0.1) && (scenario != "transient" || now < 0.15)
        var attachments = existing
        if newCount { attachments["Remove image.png", default: 0] += 1 }
        if afterPaste && scenario == "attachment_lost" { attachments.removeValue(forKey: "Remove existing.pdf") }
        if staged && scenario == "attachment_before" { attachments.removeValue(forKey: "Remove existing.pdf") }
        if afterPaste && scenario == "two_images" { attachments["Remove image.png"] = 2 }
        var draft = Data((scenario == "draft_after" && afterPaste || scenario == "draft_before" && staged ? "changed" : originalDraft).utf8)
        if ["empty_placeholder_after", "typed_placeholder_after"].contains(scenario) {
            let raw = afterPaste ? "Work with Codex\n" : "\n"
            draft = ComposerDraft.capture(raw: raw, nodes: [
                DraftAXNode(role: "AXTextArea", children: [1]),
                DraftAXNode(role: "AXGroup", placeholder: !afterPaste || scenario == "empty_placeholder_after", children: afterPaste ? [2] : []),
            ] + (afterPaste ? [DraftAXNode(role: "AXStaticText", text: "Work with Codex")] : []))
        }
        return ComposerSnapshot(
            target: scenario == "target_before" && staged || scenario == "target_after" && afterPaste ? "other" : "original",
            draft: draft,
            selectionEmpty: scenario != "selected_text",
            attachments: attachments)
    }
    func prepare() throws { if scenario == "unreadable" { throw TestFailure.expected } }
    func stage(_ png: Data) throws {
        staged = true
        if scenario == "stage_error" { throw TestFailure.expected }
        if scenario == "clipboard_before" { clipboardOwned = false }
    }
    func paste() throws {
        pastes += 1
        if scenario == "paste_error" { throw TestFailure.expected }
    }
    func restore() -> String {
        restores += 1
        if scenario == "restore_failed" { return "failed" }
        return clipboardOwned ? "restored" : "newer_preserved"
    }
    func wait(_ interval: TimeInterval) {
        now += interval
        if scenario != "unread_clipboard" { clipboardRead = pastes > 0 && now >= (scenario == "delayed" ? 3.5 : 0.1) }
        if scenario == "clipboard_after" && pastes > 0 { clipboardOwned = false }
    }
}

@main struct CoreTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { fputs("FAIL: \(name)\n", stderr); throw TestFailure.expected }
            checks += 1
        }
        for scenario in ["success", "delayed", "target_before", "target_after", "selected_text", "clipboard_before",
                         "clipboard_after", "draft_after", "attachment_lost", "missing_ack", "unread_clipboard", "two_images", "paste_error", "unreadable",
                         "draft_before", "attachment_before", "stage_error", "restore_failed", "transient", "existing_png", "journal_target", "journal_clipboard"] {
            let adapter = FakeAdapter(); adapter.scenario = scenario
            if scenario == "existing_png" { adapter.existing["Remove image.png"] = 1 }
            var journalCount = 0
            let result = DeliveryEngine.run(image: Data([1]), adapter: adapter, timeout: 5) {
                journalCount += 1
                if scenario == "journal_target" { adapter.scenario = "target_before" }
                if scenario == "journal_clipboard" { adapter.clipboardOwned = false }
            }
            let success = ["success", "delayed", "existing_png", "unread_clipboard"].contains(scenario)
            let neverPaste = ["target_before", "selected_text", "clipboard_before", "unreadable", "draft_before", "attachment_before", "stage_error", "journal_target", "journal_clipboard"].contains(scenario)
            try check(result.status == (success ? "verified" : neverPaste ? "blocked" : "uncertain"), "\(scenario): correct outcome")
            try check(adapter.pastes == (neverPaste ? 0 : 1), "\(scenario): never retries Paste")
            try check(journalCount == (scenario.hasPrefix("journal_") ? 1 : adapter.pastes), "\(scenario): durable intent before attempt")
            try check(adapter.restores == (adapter.staged ? 1 : 0), "\(scenario): clipboard cleanup")
            if scenario == "delayed" { try check(adapter.now >= 3.5, "late acknowledgement is awaited") }
            if scenario == "clipboard_after" { try check(result.clipboardRestoration == "newer_preserved", "newer clipboard retained") }
        }
        let adapter = FakeAdapter()
        let result = DeliveryEngine.run(image: Data([1]), adapter: adapter) { throw TestFailure.expected }
        try check(adapter.pastes == 0 && result.status == "blocked", "journal failure prevents Paste")
        let diagnosticAdapter = FakeAdapter(); diagnosticAdapter.scenario = "draft_after"
        diagnosticAdapter.originalDraft = "PRIVATE-DRAFT-SENTINEL-DO-NOT-LOG"
        let diagnostic = DeliveryEngine.run(image: Data([1]), adapter: diagnosticAdapter)
        try check(diagnostic.status == "uncertain" && diagnosticAdapter.pastes == 1, "draft diagnostics never retry or verify a changed draft")
        try check(diagnostic.diagnostics?["draftBeforeBytes"] != nil, "draft failure includes bounded structural metadata")
        let diagnosticJSON = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        try check(!diagnosticJSON.contains("PRIVATE-DRAFT-SENTINEL"), "draft diagnostics never record draft content")
        let placeholderTree = [DraftAXNode(role: "AXTextArea", children: [1]),
                               DraftAXNode(role: "AXGroup", placeholder: true, children: [2]),
                               DraftAXNode(role: "AXStaticText", text: "Work with Codex")]
        try check(ComposerDraft.capture(raw: "Work with Codex\n", nodes: placeholderTree).isEmpty, "CSS-generated hint is an empty draft")
        var typedTree = placeholderTree
        typedTree[1].placeholder = false
        try check(ComposerDraft.capture(raw: "Work with Codex\n", nodes: typedTree) == Data("Work with Codex\n".utf8), "typed text identical to the hint remains exact")
        try check(ComposerDraft.capture(raw: "edited\n", nodes: placeholderTree) == Data("edited\n".utf8), "inconsistent AX text is never discarded")
        var mixedTree = placeholderTree
        mixedTree[0].children.append(3)
        mixedTree.append(DraftAXNode(role: "AXStaticText", text: "real draft"))
        try check(ComposerDraft.capture(raw: "Work with Codexreal draft\n", nodes: mixedTree) == Data("Work with Codexreal draft\n".utf8), "text outside the placeholder is preserved")
        var imageTree = placeholderTree
        imageTree[1].children.append(3)
        imageTree.append(DraftAXNode(role: "AXImage"))
        try check(ComposerDraft.capture(raw: "Work with Codex\n", nodes: imageTree) == Data("Work with Codex\n".utf8), "unexpected embedded content refuses empty projection")
        var invalidTree = placeholderTree
        invalidTree[1].children.append(99)
        try check(ComposerDraft.capture(raw: "Work with Codex\n", nodes: invalidTree) == Data("Work with Codex\n".utf8), "incomplete AX graph preserves raw text")
        for scenario in ["empty_placeholder_after", "typed_placeholder_after"] {
            let placeholderAdapter = FakeAdapter(); placeholderAdapter.scenario = scenario
            let outcome = DeliveryEngine.run(image: Data([1]), adapter: placeholderAdapter)
            try check(outcome.status == (scenario == "empty_placeholder_after" ? "verified" : "uncertain"), "\(scenario): structural distinction controls draft verification")
            try check(placeholderAdapter.pastes == 1 && placeholderAdapter.restores == 1, "\(scenario): one Paste and clipboard cleanup")
        }
        for count in [2, 10] {
            let batchAdapter = BatchFakeAdapter()
            var intents: [Int] = []
            let batch = DeliveryEngine.runBatch(images: Array(repeating: Data([1]), count: count), adapter: batchAdapter) { intents.append($0) }
            try check(batch.status == "verified" && batch.verifiedCount == count && batch.totalCount == count, "\(count) images verified as one batch")
            try check(batchAdapter.pastes == count && batchAdapter.restores == count && intents == Array(0..<count), "\(count) images each pasted once with durable ordered intent")
            try check(batchAdapter.attached["Remove image.png"] == 2 + count && batchAdapter.attached["Remove existing.pdf"] == 1, "duplicate image names and existing attachments preserved")
        }
        for scenario in ["target_between", "draft_between", "previous_image_lost", "uncertain_second", "clipboard_second", "cancel_second"] {
            let batchAdapter = BatchFakeAdapter(); batchAdapter.scenario = scenario
            let batch = DeliveryEngine.runBatch(images: Array(repeating: Data([1]), count: 3), adapter: batchAdapter)
            let expectedPastes = ["uncertain_second", "clipboard_second"].contains(scenario) ? 2 : 1
            try check(batch.status == "uncertain" && batch.verifiedCount == 1, "\(scenario): partial batch never reported verified")
            try check(batchAdapter.pastes == expectedPastes, "\(scenario): no later Paste or retry after failure")
            try check(batch.items?.last?.status == "not_attempted" && batch.items?.last?.pasteAttempted == false, "\(scenario): untried images explicit")
        }
        let emptyBatchAdapter = BatchFakeAdapter()
        let emptyBatch = DeliveryEngine.runBatch(images: [], adapter: emptyBatchAdapter)
        try check(emptyBatch.status == "blocked" && emptyBatchAdapter.pastes == 0, "empty batch cannot Paste")
        let journalBatchAdapter = BatchFakeAdapter()
        let journalBatch = DeliveryEngine.runBatch(images: Array(repeating: Data([1]), count: 3), adapter: journalBatchAdapter) { index in
            if index == 1 { throw TestFailure.expected }
        }
        try check(journalBatch.status == "uncertain" && journalBatch.verifiedCount == 1 && journalBatchAdapter.pastes == 1,
                  "journal failure between images stops batch without another Paste")
        let oversizedBatchAdapter = BatchFakeAdapter()
        let oversizedBatch = DeliveryEngine.runBatch(images: Array(repeating: Data(repeating: 0, count: 20 * 1024 * 1024), count: 6), adapter: oversizedBatchAdapter)
        try check(oversizedBatch.status == "blocked" && oversizedBatchAdapter.pastes == 0,
                  "100 MiB aggregate limit enforced before any Paste")
        let preflightAdapter = BatchFakeAdapter(); preflightAdapter.scenario = "preflight_diagnostics"
        let preflight = DeliveryEngine.runBatch(images: [Data([1])], adapter: preflightAdapter)
        try check(preflight.status == "blocked" && preflightAdapter.pastes == 0 && preflightAdapter.restores == 0,
                  "preflight diagnostic failure cannot stage or Paste")
        try check(preflight.diagnostics?["draftSame"] == "false" && preflight.diagnostics?["windowObjectSame"] == "true",
                  "batch preflight preserves structural failure diagnostics")
        print("PASS: \(checks) delivery-policy checks; no UI or system clipboard access.")
    }
}
