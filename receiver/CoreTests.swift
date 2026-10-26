import Foundation

enum TestFailure: Error { case expected }

final class BatchFakeAdapter: DeliveryAdapter {
    var now: TimeInterval = 0
    var clipboardOwned = true
    var clipboardRead: Bool? = nil
    var pastes = 0, restores = 0
    var scenario = "success"
    var attached = ["Remove image.png": 2, "Remove existing.pdf": 1]
    var stagedAttachmentName: String? = nil
    var stagedTypes: [OriginalImageType] = []
    private var pastedAt: TimeInterval = 0
    private var acknowledged = false
    func observe() throws -> ComposerSnapshot {
        if scenario == "screen_locked_between" && restores > 0 { throw DeliveryRefusal(reason: "mac_screen_locked") }
        if scenario == "preflight_diagnostics" {
            throw DeliveryRefusal(reason: "composer_changed_during_focus", diagnostics: ["draftSame": "false", "windowObjectSame": "true"])
        }
        if pastes > 0 && !acknowledged && now - pastedAt >= 0.1 && !(scenario == "uncertain_second" && pastes == 2) {
            attached["Remove " + (stagedAttachmentName ?? "image.png"), default: 0] += 1; acknowledged = true
        }
        return ComposerSnapshot(target: scenario == "target_between" && restores > 0 ? "other" : "original",
            draft: Data((scenario == "draft_between" && restores > 0 ? "edited" : "existing draft").utf8),
            selectionEmpty: true, attachments: attached)
    }
    func prepare() throws {
        if scenario == "cancel_second" && restores > 0 { throw DeliveryRefusal(reason: "interrupted") }
    }
    func stage(_ image: OriginalImage) throws {
        clipboardOwned = true; stagedAttachmentName = "image." + image.type.fileExtension; stagedTypes.append(image.type)
    }
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
    var attachmentExtension = "png"
    var stagedNameOverride: String? = nil
    var stagedAttachmentName: String? { stagedNameOverride ?? "image." + attachmentExtension }
    var originalDraft = "draft\n🧗"
    var existing = ["Remove existing.pdf": 1]

    func observe() throws -> ComposerSnapshot {
        observations += 1
        if scenario == "screen_locked_preflight" || scenario == "screen_locked_staged" && staged || scenario == "screen_locked_after_paste" && pastes > 0 {
            throw DeliveryRefusal(reason: "mac_screen_locked")
        }
        let afterPaste = pastes > 0
        let newCount = afterPaste && (scenario != "missing_ack") && now >= (scenario == "delayed" ? 3.5 : 0.1) && (scenario != "transient" || now < 0.15)
        var attachments = existing
        if newCount { attachments["Remove image." + attachmentExtension, default: 0] += 1 }
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
    func stage(_ image: OriginalImage) throws {
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
        let fixtureImage = OriginalImage(data: Data([1]), fileURL: URL(fileURLWithPath: "/fixture/image.png"), type: .png)
        for suffix in ["mp4", "mov"] {
            guard let videoType = OriginalImageType(rawValue: suffix) else {
                try check(false, "video original type is available: \(suffix)"); return
            }
            let video = OriginalImage(data: Data([1]), fileURL: URL(fileURLWithPath: "/fixture/source." + suffix), type: videoType)
            let adapter = FakeAdapter(); adapter.attachmentExtension = suffix
            try check(DeliveryEngine.run(image: video, adapter: adapter).status == "verified", "expected video attachment is acknowledged")
            let wrongAdapter = FakeAdapter(); wrongAdapter.attachmentExtension = "png"
            try check(DeliveryEngine.run(image: video, adapter: wrongAdapter).status == "uncertain", "an image cannot acknowledge video delivery")
            let renamedAdapter = FakeAdapter(); renamedAdapter.attachmentExtension = suffix; renamedAdapter.stagedNameOverride = "other." + suffix
            try check(DeliveryEngine.run(image: video, adapter: renamedAdapter).status == "uncertain", "a different video filename cannot acknowledge the staged original")
            let draftAdapter = FakeAdapter(); draftAdapter.attachmentExtension = suffix; draftAdapter.scenario = "draft_after"
            try check(DeliveryEngine.run(image: video, adapter: draftAdapter).reason == "draft_changed_after_paste", "video file mentions cannot bypass unchanged draft guards")
        }
        try check(ImageLimits.maxBytes == 50 * 1024 * 1024, "original encoded input accepts up to exactly 50 MiB")
        try check(ImageLimits.maxBatchBytes == 100 * 1024 * 1024 && ImageLimits.maxBatchCount == 10,
                  "batch byte and count limits remain 100 MiB and ten")
        for suffix in OriginalImageType.supportedImageExtensions {
            let originalAdapter = FakeAdapter(); originalAdapter.attachmentExtension = suffix
            let receipt = DeliveryEngine.run(image: fixtureImage, adapter: originalAdapter)
            try check(receipt.status == "verified" && originalAdapter.pastes == 1,
                      "supported original file attachment is acknowledged: \(suffix)")
        }
        for suffix in ["heic", "heif"] {
            let unsupportedAdapter = FakeAdapter(); unsupportedAdapter.attachmentExtension = suffix
            try check(DeliveryEngine.run(image: fixtureImage, adapter: unsupportedAdapter).status == "uncertain",
                      "a generic HEIC or HEIF attachment cannot acknowledge an image")
        }
        let unrelatedAdapter = FakeAdapter(); unrelatedAdapter.attachmentExtension = "txt"
        try check(DeliveryEngine.run(image: fixtureImage, adapter: unrelatedAdapter).status == "uncertain",
                  "an unrelated added attachment cannot acknowledge an image")
        try check(MacSessionLockState.parse(true) == .locked, "true session lock flag yields explicit locked refusal")
        try check(MacSessionLockState.parse(false) == .unlocked, "false session lock flag is recognized without bypassing composer policy")
        for value: Any? in [nil, "true", "false", 1, 0, NSNumber(value: 1), NSNull(), ["locked": true]] {
            try check(MacSessionLockState.parse(value) == .unknown, "missing or unrecognized lock metadata supplies no unlocked evidence")
        }
        for phase in ["preflight", "staged", "after_paste"] {
            let lockedAdapter = FakeAdapter(); lockedAdapter.scenario = "screen_locked_" + phase
            let locked = DeliveryEngine.run(image: fixtureImage, adapter: lockedAdapter)
            try check(locked.reason == "mac_screen_locked" && locked.status == (phase == "after_paste" ? "uncertain" : "blocked"),
                      "screen lock keeps the correct before/after-Paste outcome")
            try check(lockedAdapter.pastes == (phase == "after_paste" ? 1 : 0), "screen lock never retries or pastes after a preflight refusal")
            try check(lockedAdapter.restores == (phase == "preflight" ? 0 : 1), "screen lock preserves staged cleanup without preflight clipboard access")
        }
        // Reproduce activation readiness without UI or clipboard access. In each
        // sample the native adapter still reads the original pinned editor/window.
        var activationTime: TimeInterval = 0
        var activationSamples = 0
        try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
            activationSamples += 1
            return ComposerActivationObservation(window: activationSamples < 3 ? .unavailable : .same,
                foregroundReady: true, contentUnchanged: true)
        }
        try check(activationSamples == 3 && activationTime > 0, "activation waits for missing AX window without reacquiring destination")
        activationTime = 0; activationSamples = 0
        try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
            activationSamples += 1
            return ComposerActivationObservation(window: .same,
                foregroundReady: activationSamples >= 3, contentUnchanged: true)
        }
        try check(activationSamples == 3, "activation waits for foreground acknowledgement with the same window")
        activationTime = 0; activationSamples = 0
        try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
            activationSamples += 1
            return ComposerActivationObservation(window: .same, foregroundReady: true, contentUnchanged: true,
                request: activationSamples < 3 ? .pending : .confirmed)
        }
        try check(activationSamples == 3, "foreground alone cannot approve an unfinished workspace request")
        for (request, reason) in [(ActivationRequestState.failed, "codex_activation_failed"), (.differentProcess, "codex_activation_target_changed")] {
            activationTime = 0; activationSamples = 0
            do {
                try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
                    activationSamples += 1
                    return ComposerActivationObservation(window: .same, foregroundReady: true, contentUnchanged: true,
                        request: request)
                }
                try check(false, "failed or substituted workspace target must refuse")
            } catch let refusal as DeliveryRefusal {
                try check(refusal.reason == reason && activationSamples == 1 && activationTime == 0,
                          "workspace error or different process blocks immediately without retry")
            }
        }
        activationTime = 0
        do {
            try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }, timeout: 0.05) {
                ComposerActivationObservation(window: .same, foregroundReady: true, contentUnchanged: true, request: .pending)
            }
            try check(false, "missing workspace completion must remain bounded")
        } catch let refusal as DeliveryRefusal {
            try check(refusal.reason == "codex_activation_not_confirmed" && activationTime >= 0.05 && activationTime < 0.071,
                      "missing workspace completion cannot turn foreground status into approval")
        }
        for window in [ActivationWindowIdentity.same, .unavailable, .changed] {
            activationTime = 0; activationSamples = 0
            do {
                try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
                    activationSamples += 1
                    return ComposerActivationObservation(window: window, foregroundReady: true,
                        contentUnchanged: window == .changed, diagnostics: ["draftSame": "false"])
                }
                try check(false, "activation must refuse known destination/content changes")
            } catch let refusal as DeliveryRefusal {
                try check(refusal.reason == "composer_changed_during_activation" && activationSamples == 1 && activationTime == 0,
                          "available different window or changed draft/attachments/selection blocks immediately")
                try check(refusal.diagnostics?["draftSame"] == "false", "activation preserves structural failure diagnostics")
            }
        }
        for changedWindow in [true, false] {
            activationTime = 0; activationSamples = 0
            do {
                try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
                    activationSamples += 1
                    return ComposerActivationObservation(window: activationSamples == 1 ? .unavailable : changedWindow ? .changed : .same,
                        foregroundReady: true, contentUnchanged: activationSamples == 1 || changedWindow)
                }
                try check(false, "pending activation cannot conceal later destination/content changes")
            } catch let refusal as DeliveryRefusal {
                try check(refusal.reason == "composer_changed_during_activation" && activationSamples == 2,
                          "pending activation aborts as soon as a real window or content change appears")
            }
        }
        activationTime = 0; activationSamples = 0
        try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
            activationSamples += 1
            return ComposerActivationObservation(window: .same, foregroundReady: true, contentUnchanged: true)
        }
        try check(activationTime == 0 && activationSamples == 1, "already-ready activation adds no delay or extra request")
        for foregroundReady in [true, false] {
            activationTime = 0; activationSamples = 0
            do {
                try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }, timeout: 0.05) {
                    activationSamples += 1
                    return ComposerActivationObservation(window: .unavailable, foregroundReady: foregroundReady, contentUnchanged: true)
                }
                try check(false, "activation unavailable deadline must refuse")
            } catch let refusal as DeliveryRefusal {
                try check(refusal.reason == (foregroundReady ? "composer_window_unavailable_after_activation" : "codex_activation_not_confirmed") && activationTime >= 0.05 && activationTime < 0.071,
                          "unavailable window/foreground has a bounded pre-paste deadline")
            }
        }
        activationTime = 0; activationSamples = 0
        do {
            try ComposerActivationGuard.waitUntilReady(now: { activationTime }, wait: { activationTime += $0 }) {
                activationSamples += 1
                if activationSamples == 2 { throw DeliveryRefusal(reason: "foreground_changed_during_activation") }
                return ComposerActivationObservation(window: .unavailable, foregroundReady: true, contentUnchanged: true)
            }
            try check(false, "foreground change during activation must propagate")
        } catch let refusal as DeliveryRefusal {
            try check(refusal.reason == "foreground_changed_during_activation" && activationSamples == 2,
                      "foreground intervention aborts pending activation without another request")
        }
        for scenario in ["success", "delayed", "target_before", "target_after", "selected_text", "clipboard_before",
                         "clipboard_after", "draft_after", "attachment_lost", "missing_ack", "unread_clipboard", "two_images", "paste_error", "unreadable",
                         "draft_before", "attachment_before", "stage_error", "restore_failed", "transient", "existing_png", "journal_target", "journal_clipboard"] {
            let adapter = FakeAdapter(); adapter.scenario = scenario
            if scenario == "existing_png" { adapter.existing["Remove image.png"] = 1 }
            var journalCount = 0
            let result = DeliveryEngine.run(image: fixtureImage, adapter: adapter, timeout: 5) {
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
        let result = DeliveryEngine.run(image: fixtureImage, adapter: adapter) { throw TestFailure.expected }
        try check(adapter.pastes == 0 && result.status == "blocked", "journal failure prevents Paste")
        let diagnosticAdapter = FakeAdapter(); diagnosticAdapter.scenario = "draft_after"
        diagnosticAdapter.originalDraft = "PRIVATE-DRAFT-SENTINEL-DO-NOT-LOG"
        let diagnostic = DeliveryEngine.run(image: fixtureImage, adapter: diagnosticAdapter)
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
            let outcome = DeliveryEngine.run(image: fixtureImage, adapter: placeholderAdapter)
            try check(outcome.status == (scenario == "empty_placeholder_after" ? "verified" : "uncertain"), "\(scenario): structural distinction controls draft verification")
            try check(placeholderAdapter.pastes == 1 && placeholderAdapter.restores == 1, "\(scenario): one Paste and clipboard cleanup")
        }
        for count in [2, 10] {
            let batchAdapter = BatchFakeAdapter()
            var intents: [Int] = []
            let batch = DeliveryEngine.runBatch(images: Array(repeating: fixtureImage, count: count), adapter: batchAdapter) { intents.append($0) }
            try check(batch.status == "verified" && batch.verifiedCount == count && batch.totalCount == count, "\(count) images verified as one batch")
            try check(batchAdapter.pastes == count && batchAdapter.restores == count && intents == Array(0..<count), "\(count) images each pasted once with durable ordered intent")
            try check(batchAdapter.attached["Remove image.png"] == 2 + count && batchAdapter.attached["Remove existing.pdf"] == 1, "duplicate image names and existing attachments preserved")
        }
        let mixedFiles = [fixtureImage, OriginalImage(data: Data([2]), fileURL: URL(fileURLWithPath: "/fixture/video.mp4"), type: .mp4),
                          OriginalImage(data: Data([3]), fileURL: URL(fileURLWithPath: "/fixture/video.mov"), type: .mov), fixtureImage]
        let mixedAdapter = BatchFakeAdapter()
        let mixedResult = DeliveryEngine.runBatch(images: mixedFiles, adapter: mixedAdapter)
        try check(mixedResult.status == "verified" && mixedResult.verifiedCount == 4 && mixedAdapter.stagedTypes == [.png, .mp4, .mov, .png], "mixed image and video batch preserves order and acknowledgement")
        let stoppedMixedAdapter = BatchFakeAdapter(); stoppedMixedAdapter.scenario = "uncertain_second"
        let stoppedMixed = DeliveryEngine.runBatch(images: mixedFiles, adapter: stoppedMixedAdapter)
        try check(stoppedMixed.status == "uncertain" && stoppedMixed.verifiedCount == 1 && stoppedMixedAdapter.pastes == 2 && stoppedMixedAdapter.stagedTypes == [.png, .mp4], "mixed batch stops on an unacknowledged video without replay or later Paste")
        for scenario in ["target_between", "draft_between", "previous_image_lost", "uncertain_second", "clipboard_second", "cancel_second", "screen_locked_between"] {
            let batchAdapter = BatchFakeAdapter(); batchAdapter.scenario = scenario
            let batch = DeliveryEngine.runBatch(images: Array(repeating: fixtureImage, count: 3), adapter: batchAdapter)
            let expectedPastes = ["uncertain_second", "clipboard_second"].contains(scenario) ? 2 : 1
            try check(batch.status == "uncertain" && batch.verifiedCount == 1, "\(scenario): partial batch never reported verified")
            try check(batchAdapter.pastes == expectedPastes, "\(scenario): no later Paste or retry after failure")
            try check(batch.items?.last?.status == "not_attempted" && batch.items?.last?.pasteAttempted == false, "\(scenario): untried images explicit")
        }
        let emptyBatchAdapter = BatchFakeAdapter()
        let emptyBatch = DeliveryEngine.runBatch(images: [], adapter: emptyBatchAdapter)
        try check(emptyBatch.status == "blocked" && emptyBatchAdapter.pastes == 0, "empty batch cannot Paste")
        let journalBatchAdapter = BatchFakeAdapter()
        let journalBatch = DeliveryEngine.runBatch(images: Array(repeating: fixtureImage, count: 3), adapter: journalBatchAdapter) { index in
            if index == 1 { throw TestFailure.expected }
        }
        try check(journalBatch.status == "uncertain" && journalBatch.verifiedCount == 1 && journalBatchAdapter.pastes == 1,
                  "journal failure between images stops batch without another Paste")
        let oversizedBatchAdapter = BatchFakeAdapter()
        let oversizedBatch = DeliveryEngine.runBatch(images: Array(repeating: OriginalImage(data: Data(repeating: 0, count: 20 * 1024 * 1024), fileURL: fixtureImage.fileURL, type: .png), count: 6), adapter: oversizedBatchAdapter)
        try check(oversizedBatch.status == "blocked" && oversizedBatchAdapter.pastes == 0,
                  "100 MiB aggregate limit enforced before any Paste")
        let preflightAdapter = BatchFakeAdapter(); preflightAdapter.scenario = "preflight_diagnostics"
        let preflight = DeliveryEngine.runBatch(images: [fixtureImage], adapter: preflightAdapter)
        try check(preflight.status == "blocked" && preflightAdapter.pastes == 0 && preflightAdapter.restores == 0,
                  "preflight diagnostic failure cannot stage or Paste")
        try check(preflight.diagnostics?["draftSame"] == "false" && preflight.diagnostics?["windowObjectSame"] == "true",
                  "batch preflight preserves structural failure diagnostics")
        print("PASS: \(checks) delivery-policy checks; no UI or system clipboard access.")
    }
}
