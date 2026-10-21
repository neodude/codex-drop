import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

// Shared by every receiver/test queue for this user, independent of data-dir.
final class NativeDeliveryLock {
    private var descriptor: Int32 = -1
    init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexScreenshotReceiver", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = base.appendingPathComponent("native-delivery.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DeliveryRefusal(reason: "native_delivery_lock_unavailable") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw DeliveryRefusal(reason: "another_delivery_in_progress")
        }
        descriptor = fd
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}

func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func axString(_ element: AXUIElement, _ name: String) -> String? { axValue(element, name) as? String }

func captureComposerDraft(_ editor: AXUIElement, text: String) throws -> Data {
    let elements = try axWalk(editor)
    let indices = Dictionary(uniqueKeysWithValues: elements.enumerated().map { ($0.element, $0.offset) })
    let nodes = elements.map { element in
        DraftAXNode(role: axString(element, kAXRoleAttribute) ?? "",
                    placeholder: (axValue(element, "AXDOMClassList") as? [String] ?? []).contains("placeholder"),
                    text: axString(element, kAXValueAttribute),
                    children: (axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { indices[$0] ?? -1 })
    }
    return ComposerDraft.capture(raw: text, nodes: nodes)
}

// Structural diagnostics only. Never return draft text, hashes, or attachment labels.
func draftAXMetadata(_ editor: AXUIElement, text: String) -> [String: String] {
    var details = ["axKnownImageMarker": String(text.trimmingCharacters(in: .whitespacesAndNewlines) == "[Image: image]"),
                   "axMatchesKnownCodexPlaceholder": String(text.trimmingCharacters(in: .newlines) == "Work with Codex"),
                   "axObjectReplacementScalars": String(text.unicodeScalars.filter { $0.value == 0xfffc }.count),
                   "axNewlineScalars": String(text.unicodeScalars.filter { $0.value == 10 }.count)]
    details["axValueBytes"] = String(text.utf8.count)
    if let projected = try? captureComposerDraft(editor, text: text) {
        details["draftBytesExcludingPlaceholder"] = String(projected.count)
    }
    if let placeholder = axString(editor, "AXPlaceholderValue") {
        details["axPlaceholderBytes"] = String(placeholder.utf8.count)
        details["axValueMatchesPlaceholder"] = String(text.trimmingCharacters(in: .newlines) == placeholder)
    }
    if let nodes = try? axWalk(editor) {
        details["axEditorImageNodes"] = String(nodes.filter { axString($0, kAXRoleAttribute) == kAXImageRole }.count)
        details["axEditorStaticTextNodes"] = String(nodes.filter { axString($0, kAXRoleAttribute) == kAXStaticTextRole }.count)
        details["axPlaceholderClassNodes"] = String(nodes.filter {
            let classes = axValue($0, "AXDOMClassList") as? [String] ?? []
            return classes.contains("placeholder")
        }.count)
        details["axStaticTextMatchesKnownPlaceholder"] = String(nodes.filter {
            axString($0, kAXRoleAttribute) == kAXStaticTextRole &&
            axString($0, kAXValueAttribute) == "Work with Codex"
        }.count)
    }
    let count = (axValue(editor, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? text.utf16.count
    guard count >= 0, count <= 1_000_000 else { return details }
    var range = CFRange(location: 0, length: count)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return details }
    var value: CFTypeRef?
    let status = AXUIElementCopyParameterizedAttributeValue(editor, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
    details["axStringRangeStatus"] = String(status.rawValue)
    if let string = value as? String {
        details["axStringRangeBytes"] = String(string.utf8.count)
        details["axStringRangeMatchesValue"] = String(string == text)
        details["axStringRangeObjects"] = String(string.unicodeScalars.filter { $0.value == 0xfffc }.count)
    }
    value = nil
    let attributedStatus = AXUIElementCopyParameterizedAttributeValue(editor, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value)
    details["axAttributedRangeStatus"] = String(attributedStatus.rawValue)
    if let attributed = value as? NSAttributedString {
        details["axAttributedBytes"] = String(attributed.string.utf8.count)
        details["axAttributedMatchesValue"] = String(attributed.string == text)
        details["axAttributedObjects"] = String(attributed.string.unicodeScalars.filter { $0.value == 0xfffc }.count)
        var attachmentRuns = 0
        attributed.enumerateAttribute(NSAttributedString.Key(kAXAttachmentTextAttribute.takeUnretainedValue() as String), in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachmentRuns += 1 }
        }
        details["axAttachmentRuns"] = String(attachmentRuns)
    }
    return details
}
func axWalk(_ root: AXUIElement) throws -> [AXUIElement] {
    var stack = [root], visited = Set<AXUIElement>(), result: [AXUIElement] = []
    while let next = stack.popLast() {
        guard visited.insert(next).inserted else { continue }
        result.append(next)
        guard result.count <= 12_000 else { throw DeliveryRefusal(reason: "accessibility_tree_limit") }
        stack.append(contentsOf: axValue(next, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return result
}
func axLabel(_ element: AXUIElement) -> String {
    // Prefer a single accessible label rather than concatenating duplicates.
    for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
        if let value = axString(element, key), !value.isEmpty { return value }
    }
    return ""
}
func axSelectionState(_ editor: AXUIElement) -> (empty: Bool, readable: Bool, length: Int?) {
    if let value = axValue(editor, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        let rangeValue = value as! AXValue
        var range = CFRange()
        if AXValueGetType(rangeValue) == .cfRange && AXValueGetValue(rangeValue, .cfRange, &range) { return (range.length == 0, true, range.length) }
    }
    if let text = axString(editor, kAXSelectedTextAttribute) { return (text.isEmpty, true, text.utf16.count) }
    return (false, false, nil)
}
func axSelectionEmpty(_ editor: AXUIElement) -> Bool { axSelectionState(editor).empty }

// All original clipboard representations stay in memory only.
final class ClipboardLease {
    let pasteboard: NSPasteboard
    let saved: [[NSPasteboard.PasteboardType: Data]]
    let initialCount: Int
    var ownedCount: Int?
    var owned: Bool { ownedCount != nil && pasteboard.changeCount == ownedCount }

    init(_ pasteboard: NSPasteboard) throws {
        self.pasteboard = pasteboard
        initialCount = pasteboard.changeCount
        saved = try (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw DeliveryRefusal(reason: "clipboard_snapshot_incomplete", diagnostics: [
                        "unreadableFormat": type.rawValue,
                        "recovery": "Copy some plain text, then explicitly retry. The unreadable clipboard was left unchanged."
                    ])
                }
                copy[type] = data
            }
            return copy
        }
        guard pasteboard.changeCount == initialCount else { throw DeliveryRefusal(reason: "clipboard_changed_during_snapshot") }
    }
    func stage(_ data: Data) throws {
        guard pasteboard.changeCount == initialCount else { throw DeliveryRefusal(reason: "clipboard_changed_before_stage") }
        let item = NSPasteboardItem()
        // Eager bytes only. A lazy provider here can deadlock against synchronous AX Paste.
        guard item.setData(data, forType: .png) else { throw DeliveryRefusal(reason: "clipboard_image_encoding_failed") }
        pasteboard.clearContents()
        ownedCount = pasteboard.changeCount
        guard pasteboard.writeObjects([item]) else { throw DeliveryRefusal(reason: "clipboard_stage_failed") }
        ownedCount = pasteboard.changeCount
    }
    func restore() -> String {
        guard ownedCount != nil else { return "not_staged" }
        guard owned else { return "newer_preserved" }
        let items = saved.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        let success = items.isEmpty || pasteboard.writeObjects(items)
        ownedCount = nil
        return success ? "restored" : "failed"
    }
}

final class MacDeliveryAdapter: DeliveryAdapter {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var clipboardOwned: Bool { lease?.owned ?? false }
    var clipboardRead: Bool? { nil } // Eager clipboard reads are not observable.
    var cancelled = false
    var testStageHold: TimeInterval = 0
    var testAfterPasteHold: TimeInterval = 0
    private let expectedBundleID: String
    private let fixturePasteboard: String?
    private let requiresActivation: Bool
    init(fixturePasteboard: String? = nil, activateFixture: Bool = false) {
        self.fixturePasteboard = fixturePasteboard
        requiresActivation = fixturePasteboard == nil || activateFixture
        expectedBundleID = fixturePasteboard == nil ? "com.openai.codex" : "com.example.CodexScreenshotReceiverFixture"
    }
    private var application: NSRunningApplication?
    private var app: AXUIElement?
    private var window: AXUIElement?
    private var editor: AXUIElement?
    private var scope: AXUIElement?
    private var pasteItem: AXUIElement?
    private var lease: ClipboardLease?
    private var lastSnapshot: ComposerSnapshot?
    // Explicit, user-run probe only: never stages a clipboard or invokes Paste.
    var focusDiagnostic = false
    var diagnosticActivates = false
    var focusSamples: [[String: String]] = []
    private var needsActiveResponder: Bool { requiresActivation && (!focusDiagnostic || diagnosticActivates) }

    private let composerMarkers: Set<String> = ["add files and more", "add photos and files", "attach files"]

    private func findScope(editor: AXUIElement, window: AXUIElement) throws -> AXUIElement {
        var current = axElement(editor, kAXParentAttribute)
        for _ in 0..<14 {
            guard let candidate = current, !CFEqual(candidate, window) else { break }
            let role = axString(candidate, kAXRoleAttribute) ?? ""
            if ["AXWebArea", kAXApplicationRole, kAXWindowRole].contains(role) { break }
            let nodes = try axWalk(candidate)
            let textAreas = nodes.filter { axString($0, kAXRoleAttribute) == kAXTextAreaRole }
            let markers = nodes.filter { axString($0, kAXRoleAttribute) == kAXButtonRole && composerMarkers.contains(axLabel($0).lowercased()) }
            if textAreas.count == 1, CFEqual(textAreas[0], editor), markers.count == 1 { return candidate }
            current = axElement(candidate, kAXParentAttribute)
        }
        throw DeliveryRefusal(reason: "composer_scope_not_recognized_run_diagnose")
    }

    private func attachmentCounts(_ scope: AXUIElement) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for node in try axWalk(scope) where axString(node, kAXRoleAttribute) == kAXButtonRole {
            let label = axLabel(node)
            if label.hasPrefix("Remove ") { counts[label, default: 0] += 1 }
        }
        return counts
    }

    private func composerHasFocus(_ editor: AXUIElement, app: AXUIElement) -> Bool {
        // Chromium omits the application-level focused element while inactive.
        // Its editor still reports document focus through AXFocused.
        if let focused = axElement(app, kAXFocusedUIElementAttribute) { return CFEqual(focused, editor) }
        // Native menu Paste also needs the foreground application's responder.
        if needsActiveResponder { return false }
        return (axValue(editor, kAXFocusedAttribute) as? Bool) == true
    }

    // Acquire only once. Later observations must never pull focus back after the
    // user changes it, especially between images in a batch.
    private func acquireComposer(app: AXUIElement, window: AXUIElement) throws -> AXUIElement {
        guard (axValue(window, "AXSheets") as? [AXUIElement] ?? []).isEmpty,
              (axValue(window, kAXModalAttribute) as? Bool) != true else {
            throw DeliveryRefusal(reason: "codex_dialog_open")
        }
        let initialFocus = axElement(app, kAXFocusedUIElementAttribute)
        let title = axString(window, kAXTitleAttribute) ?? ""
        let candidates: [(AXUIElement, AXUIElement)]
        if let initialFocus, axString(initialFocus, kAXRoleAttribute) == kAXTextAreaRole,
           let scope = try? findScope(editor: initialFocus, window: window) {
            // Keep the existing narrow, fast path when the composer is focused.
            candidates = [(initialFocus, scope)]
        } else {
            candidates = try axWalk(window).filter { axString($0, kAXRoleAttribute) == kAXTextAreaRole }
                .compactMap { candidate -> (AXUIElement, AXUIElement)? in
                    guard let scope = try? findScope(editor: candidate, window: window) else { return nil }
                    return (candidate, scope)
                }
        }
        guard candidates.count == 1, let (candidate, scope) = candidates.first else {
            throw DeliveryRefusal(reason: "main_composer_not_unique")
        }
        guard let text = axString(candidate, kAXValueAttribute) else { throw DeliveryRefusal(reason: "draft_unreadable") }
        let draft = try captureComposerDraft(candidate, text: text)
        let attachments = try attachmentCounts(scope)
        guard axSelectionEmpty(candidate) else { throw DeliveryRefusal(reason: "selection_not_empty") }
        func invariants(detailed: Bool = false) -> (unchanged: Bool, details: [String: String]) {
            let currentWindow = axElement(app, kAXFocusedWindowAttribute) ?? axElement(app, kAXMainWindowAttribute)
            let windowSame = currentWindow.map { CFEqual($0, window) } ?? false
            let titleSame = (axString(window, kAXTitleAttribute) ?? "") == title
            let after = axString(candidate, kAXValueAttribute)
            let projected = after.flatMap { try? captureComposerDraft(candidate, text: $0) }
            let draftSame = projected == draft
            let counts = try? attachmentCounts(scope)
            let attachmentsSame = counts == attachments
            let selection = axSelectionState(candidate)
            let selectionEmpty = selection.empty
            var details = ["windowObjectSame": String(windowSame), "windowTitleSame": String(titleSame),
                           "draftReadable": String(after != nil), "draftSame": String(draftSame),
                           "draftBeforeBytes": String(draft.count), "rawBeforeBytes": String(text.utf8.count),
                           "draftAfterBytes": projected.map { String($0.count) } ?? "unavailable",
                           "rawAfterBytes": after.map { String($0.utf8.count) } ?? "unavailable",
                           "attachmentsReadable": String(counts != nil), "attachmentsSame": String(attachmentsSame),
                           "selectionEmpty": String(selectionEmpty), "selectionReadable": String(selection.readable),
                           "selectionLength": selection.length.map { String($0) } ?? "unavailable"]
            if detailed, let after { details.merge(draftAXMetadata(candidate, text: after)) { _, new in new } }
            return (windowSame && titleSame && draftSame && attachmentsSame && selectionEmpty, details)
        }
        if focusDiagnostic {
            var baseline = draftAXMetadata(candidate, text: text)
            baseline["phase"] = "beforeActivation"; baseline["draftBytes"] = String(draft.count)
            focusSamples.append(baseline)
        }
        func sameWindow() -> Bool {
            guard let current = axElement(app, kAXFocusedWindowAttribute) ?? axElement(app, kAXMainWindowAttribute) else { return false }
            return CFEqual(current, window) && (axString(window, kAXTitleAttribute) ?? "") == title
        }
        let currentFocus = axElement(app, kAXFocusedUIElementAttribute)
        let sameFocus = initialFocus.map { original in currentFocus.map { CFEqual(original, $0) } ?? false } ?? (currentFocus == nil)
        guard sameWindow(), sameFocus else { throw DeliveryRefusal(reason: "target_changed_during_discovery") }
        if needsActiveResponder {
            let pid = applicationPID(app)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard let target = NSRunningApplication(processIdentifier: pid), target.bundleIdentifier == expectedBundleID,
                      target.activate(options: [.activateIgnoringOtherApps]) else {
                    throw DeliveryRefusal(reason: "codex_activation_failed")
                }
                let activationDeadline = now + 1
                while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                    guard !cancelled, sameWindow() else { throw DeliveryRefusal(reason: "target_changed_during_activation") }
                    let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard active == nil || active == previous else { throw DeliveryRefusal(reason: "foreground_changed_during_activation") }
                    guard now < activationDeadline else { throw DeliveryRefusal(reason: "codex_activation_not_confirmed") }
                    wait(0.02)
                }
            }
        }
        let activatedState = invariants(detailed: focusDiagnostic && !diagnosticActivates)
        guard activatedState.unchanged else {
            var details = activatedState.details
            if let current = axString(candidate, kAXValueAttribute) {
                for (key, value) in draftAXMetadata(candidate, text: current) { details["afterDecision_" + key] = value }
            }
            throw DeliveryRefusal(reason: "composer_changed_during_activation", diagnostics: details)
        }
        let focusBeforeRequest = axElement(app, kAXFocusedUIElementAttribute)
        if !composerHasFocus(candidate, app: app) {
            guard AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw DeliveryRefusal(reason: "composer_focus_failed")
            }
        }
        if focusDiagnostic && !diagnosticActivates {
            let start = Date()
            for index in 0..<11 {
                if index > 0 { wait(0.05) }
                let focused = axElement(app, kAXFocusedUIElementAttribute)
                var state = invariants(detailed: true).details
                state.merge([
                    "phase": "afterFocusRequest",
                    "elapsedMS": String(Int(Date().timeIntervalSince(start) * 1000)),
                    "windowSame": String(sameWindow()),
                    "focusedRole": focused.flatMap { axString($0, kAXRoleAttribute) } ?? "unavailable",
                    "focusedIsComposer": String(focused.map { CFEqual($0, candidate) } ?? false),
                    "composerFocusAttribute": (axValue(candidate, kAXFocusedAttribute) as? NSNumber)?.stringValue ?? "unavailable",
                    "codexFrontmost": String(NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID(app))
                ]) { _, new in new }
                focusSamples.append(state)
            }
        }
        // The AX setter acknowledges the request before Chromium applies focus.
        // Wait for that one request; never retry it or reacquire during a batch.
        let deadline = now + 0.75
        let focusStarted = now
        while true {
            guard !cancelled else { throw DeliveryRefusal(reason: "interrupted") }
            if needsActiveResponder,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != applicationPID(app) {
                throw DeliveryRefusal(reason: "foreground_changed_during_focus")
            }
            let state = invariants()
            if focusDiagnostic && diagnosticActivates {
                var sample = state.details
                sample["phase"] = "productionTimingCheck"
                sample["elapsedMS"] = String(Int((now - focusStarted) * 1000))
                focusSamples.append(sample)
            }
            guard state.unchanged else {
                if focusDiagnostic && diagnosticActivates {
                    // Follow up only AFTER the failed decision. Logging must not
                    // delay the checks that reproduce the real delivery path.
                    wait(0.1)
                    var followup = invariants(detailed: true).details
                    followup["phase"] = "afterFailure100ms"
                    focusSamples.append(followup)
                }
                var details = state.details
                if let current = axString(candidate, kAXValueAttribute) {
                    for (key, value) in draftAXMetadata(candidate, text: current) { details["afterDecision_" + key] = value }
                }
                throw DeliveryRefusal(reason: "composer_changed_during_focus", diagnostics: details)
            }
            if composerHasFocus(candidate, app: app) { break }
            let focused = axElement(app, kAXFocusedUIElementAttribute)
            if let focused, focusBeforeRequest.map({ CFEqual($0, focused) }) != true {
                throw DeliveryRefusal(reason: "target_changed_during_focus")
            }
            guard now < deadline else { throw DeliveryRefusal(reason: "composer_focus_not_confirmed") }
            wait(0.02)
        }
        return candidate
    }

    private func applicationPID(_ app: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return pid
    }

    func observe() throws -> ComposerSnapshot {
        guard !cancelled else { throw DeliveryRefusal(reason: "interrupted") }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID)
        guard applications.count == 1 else { throw DeliveryRefusal(reason: fixturePasteboard == nil ? "codex_app_not_unique" : "fixture_app_not_unique") }
        let running = applications[0]
        if let application, application.processIdentifier != running.processIdentifier { throw DeliveryRefusal(reason: "target_application_changed") }
        let axApp = app ?? AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let focusedWindow = axElement(axApp, kAXFocusedWindowAttribute) ?? axElement(axApp, kAXMainWindowAttribute),
              (axValue(focusedWindow, kAXMinimizedAttribute) as? Bool) != true else {
            throw DeliveryRefusal(reason: "codex_window_unavailable")
        }
        let focusedEditor: AXUIElement
        if let editor {
            guard composerHasFocus(editor, app: axApp) else { throw DeliveryRefusal(reason: "target_editor_changed") }
            focusedEditor = editor
        } else {
            focusedEditor = try acquireComposer(app: axApp, window: focusedWindow)
        }
        if needsActiveResponder,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            throw DeliveryRefusal(reason: "target_application_no_longer_frontmost")
        }
        if let window, !CFEqual(window, focusedWindow) { throw DeliveryRefusal(reason: "target_window_changed") }
        if let editor, !CFEqual(editor, focusedEditor) { throw DeliveryRefusal(reason: "target_editor_changed") }
        guard let text = axString(focusedEditor, kAXValueAttribute) else { throw DeliveryRefusal(reason: "draft_unreadable") }
        let scope = try self.scope ?? findScope(editor: focusedEditor, window: focusedWindow)
        let nodes = try axWalk(scope)
        let textAreas = nodes.filter { axString($0, kAXRoleAttribute) == kAXTextAreaRole }
        let markers = nodes.filter { axString($0, kAXRoleAttribute) == kAXButtonRole && composerMarkers.contains(axLabel($0).lowercased()) }
        guard textAreas.count == 1, CFEqual(textAreas[0], focusedEditor), markers.count == 1 else {
            throw DeliveryRefusal(reason: "composer_scope_changed")
        }
        var attachments: [String: Int] = [:]
        for node in nodes where axString(node, kAXRoleAttribute) == kAXButtonRole {
            let label = axLabel(node)
            // Explicit current English attachment labels; unknown layouts/languages refuse verification.
            if label.hasPrefix("Remove ") { attachments[label, default: 0] += 1 }
        }
        let title = axString(focusedWindow, kAXTitleAttribute) ?? ""
        let identity = "\(running.processIdentifier):\(CFHash(focusedWindow)):\(CFHash(focusedEditor)):\(title)"
        let target = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        self.application = running; self.app = axApp; self.window = focusedWindow; self.editor = focusedEditor; self.scope = scope
        let draft = try captureComposerDraft(focusedEditor, text: text)
        let changed = lastSnapshot.map { $0.draft != draft } ?? false
        let metadata = changed ? draftAXMetadata(focusedEditor, text: text) : [:]
        let snapshot = ComposerSnapshot(target: target, draft: draft, selectionEmpty: axSelectionEmpty(focusedEditor), attachments: attachments, metadata: metadata)
        lastSnapshot = snapshot
        return snapshot
    }
    func prepare() throws {
        guard let app, let menuBar = axElement(app, kAXMenuBarAttribute) else { throw DeliveryRefusal(reason: "menu_bar_unavailable") }
        let names: Set<String> = ["paste", "incolla", "coller", "einsetzen", "einfügen", "pegar", "plakken", "colar"]
        let matches = try axWalk(menuBar).filter {
            axString($0, kAXRoleAttribute) == kAXMenuItemRole && names.contains((axString($0, kAXTitleAttribute) ?? "").lowercased())
        }
        guard matches.count == 1 else { throw DeliveryRefusal(reason: "paste_menu_not_unique") }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(matches[0], &actions) == .success,
              (actions as? [String] ?? []).contains(kAXPressAction) else { throw DeliveryRefusal(reason: "paste_menu_unavailable") }
        pasteItem = matches[0]
    }
    func stage(_ png: Data) throws {
        lease = try ClipboardLease(fixturePasteboard.map { NSPasteboard(name: .init($0)) } ?? .general)
        try lease?.stage(png)
        if testStageHold > 0 {
            print("TEST WINDOW: image staged; holding \(Int(testStageHold)) seconds BEFORE Paste."); fflush(stdout)
            NSSound.beep()
            wait(testStageHold)
        }
    }
    func paste() throws {
        guard !cancelled else { throw DeliveryRefusal(reason: "interrupted_before_paste") }
        guard let expected = lastSnapshot else { throw DeliveryRefusal(reason: "missing_target_snapshot") }
        let current = try observe() // Recheck after the durable journal write too.
        guard current.target == expected.target, current.draft == expected.draft,
              current.attachments == expected.attachments, current.selectionEmpty else {
            throw DeliveryRefusal(reason: "final_target_recheck_failed")
        }
        guard clipboardOwned else { throw DeliveryRefusal(reason: "clipboard_changed_at_paste") }
        guard let pasteItem, AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success else {
            throw DeliveryRefusal(reason: "paste_action_failed")
        }
        if testAfterPasteHold > 0 {
            print("TEST WINDOW: Paste invoked; holding \(Int(testAfterPasteHold)) seconds BEFORE acknowledgement."); fflush(stdout)
            NSSound.beep()
            wait(testAfterPasteHold)
        }
    }
    func restore() -> String { lease?.restore() ?? "not_staged" }
    func wait(_ interval: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(interval)) }
}

func diagnoseComposerFocus(activate: Bool = false) throws {
    let lock = try NativeDeliveryLock()
    defer { lock.release() }
    let adapter = MacDeliveryAdapter(fixturePasteboard: nil)
    adapter.focusDiagnostic = true
    adapter.diagnosticActivates = activate
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
    var initial = ["codexApplicationCount": String(applications.count)]
    if applications.count == 1 {
        let app = AXUIElementCreateApplication(applications[0].processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        initial["codexFrontmost"] = String(NSWorkspace.shared.frontmostApplication?.processIdentifier == applications[0].processIdentifier)
        initial["focusedWindowAvailable"] = String(axElement(app, kAXFocusedWindowAttribute) != nil)
        initial["mainWindowAvailable"] = String(axElement(app, kAXMainWindowAttribute) != nil)
        initial["windowCount"] = String((axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).count)
        initial["focusedRole"] = axElement(app, kAXFocusedUIElementAttribute).flatMap { axString($0, kAXRoleAttribute) } ?? "unavailable"
    }
    var reason = "composer_observed"
    var failureDetails: [String: String] = [:]
    do { _ = try adapter.observe() }
    catch let refusal as DeliveryRefusal { reason = refusal.reason; failureDetails = refusal.diagnostics ?? [:] }
    let report: [String: Any] = ["reason": reason, "initial": initial, "samples": adapter.focusSamples,
                              "failureDetails": failureDetails, "clipboardAccessed": false, "pasteAttempted": false]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent(activate ? ".codex-artifacts/checks/composer-activation-diagnose.json" : ".codex-artifacts/checks/composer-focus-diagnose.json")
    try data.write(to: output, options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}

func writeResult(_ result: DeliveryResult, to url: URL) throws {
    let data = try JSONEncoder().encode(result)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func diagnoseComposer() throws {
    // Structural metadata only. No draft, transcript, button labels or window titles are saved.
    guard let foreground = NSWorkspace.shared.frontmostApplication, foreground.bundleIdentifier == "com.openai.codex" else {
        throw DeliveryRefusal(reason: "codex_not_frontmost")
    }
    let app = AXUIElementCreateApplication(foreground.processIdentifier)
    guard let editor = axElement(app, kAXFocusedUIElementAttribute) else { throw DeliveryRefusal(reason: "no_focused_element") }
    var current: AXUIElement? = editor
    var rows: [[String: Any]] = []
    for depth in 0..<14 {
        guard let node = current else { break }
        let nodes = try axWalk(node)
        rows.append([
            "depth": depth,
            "role": axString(node, kAXRoleAttribute) ?? "unknown",
            "identifier": axString(node, kAXIdentifierAttribute) ?? "",
            "textAreas": nodes.filter { axString($0, kAXRoleAttribute) == kAXTextAreaRole }.count,
            "composerMarkerButtons": nodes.filter { ["add files and more", "add photos and files", "attach files"].contains(axLabel($0).lowercased()) }.count,
            "removeButtons": nodes.filter { axString($0, kAXRoleAttribute) == kAXButtonRole && axLabel($0).hasPrefix("Remove ") }.count,
            "draftReadable": axString(editor, kAXValueAttribute) != nil,
            "selectionEmpty": axSelectionEmpty(editor)
        ])
        if axString(node, kAXRoleAttribute) == kAXWindowRole { break }
        current = axElement(node, kAXParentAttribute)
    }
    let textMetadata = draftAXMetadata(editor, text: axString(editor, kAXValueAttribute) ?? "")
    let report: [String: Any] = ["ancestors": rows, "textMetadata": textMetadata]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent(".codex-artifacts/checks/composer-diagnose.json")
    try data.write(to: reportURL, options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}

func diagnoseClipboardFormats() throws {
    // Report representation metadata only; never print or persist clipboard values.
    let clipboard = NSPasteboard.general
    let before = clipboard.changeCount
    var rows: [[String: Any]] = []
    for (index, item) in (clipboard.pasteboardItems ?? []).enumerated() {
        for type in item.types {
            let data = item.data(forType: type)
            rows.append(["item": index, "type": type.rawValue, "dataReadable": data != nil,
                         "byteCount": data?.count ?? 0])
        }
    }
    let result: [String: Any] = ["formats": rows, "clipboardChangedDuringRead": before != clipboard.changeCount]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}

func platformSelfTest() throws {
    var checks = 0
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw DeliveryRefusal(reason: "platform_test_" + name) }; checks += 1
    }
    let pb = NSPasteboard(name: .init("com.example.CodexScreenshotReceiver.Test." + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let original = NSPasteboardItem()
    original.setString("original\nclipboard 🧗", forType: .string)
    original.setData(Data([0, 255, 1]), forType: .init("com.example.receiver-test"))
    pb.clearContents(); try check(pb.writeObjects([original]), "fixture")
    let png = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("test-image.png"))
    let lease = try ClipboardLease(pb)
    try lease.stage(png)
    try check(lease.owned, "ownership_after_eager_stage")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--read-fixture-pasteboard", pb.name.rawValue]
    let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
    try child.run()
    let deadline = Date().addingTimeInterval(5)
    while child.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    if child.isRunning { child.terminate(); child.waitUntilExit() }
    let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let received = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    try check(child.terminationStatus == 0 && received == digest, "cross_process_eager_png_exact_bytes")
    try check(lease.restore() == "restored", "restoration")
    try check(pb.string(forType: .string) == "original\nclipboard 🧗", "text_round_trip")
    try check(pb.data(forType: .init("com.example.receiver-test")) == Data([0, 255, 1]), "custom_format_round_trip")
    let changed = try ClipboardLease(pb); try changed.stage(png)
    pb.clearContents(); pb.setString("newer clipboard", forType: .string)
    try check(changed.restore() == "newer_preserved", "newer_preserved")
    try check(pb.string(forType: .string) == "newer clipboard", "newer_untouched")
    let stale = try ClipboardLease(pb)
    pb.clearContents(); pb.setString("changed before stage", forType: .string)
    do { try stale.stage(png); throw DeliveryRefusal(reason: "platform_test_stale_stage_accepted") }
    catch let error as DeliveryRefusal { try check(error.reason == "clipboard_changed_before_stage", "stale_snapshot_refused") }
    let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexReceiverLockTest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: lockDirectory) }
    let firstLock = try NativeDeliveryLock(directory: lockDirectory)
    func childLockResult() throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--try-fixture-lock", lockDirectory.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try check(try childLockResult() == "blocked", "cross_process_delivery_lock_excludes_other_queue")
    firstLock.release()
    try check(try childLockResult() == "acquired", "delivery_lock_released_after_completion")
    final class UnreadableProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
    }
    let unreadableProvider = UnreadableProvider(), unreadableItem = NSPasteboardItem()
    unreadableItem.setDataProvider(unreadableProvider, forTypes: [.png])
    pb.clearContents(); try check(pb.writeObjects([unreadableItem]), "unreadable_fixture")
    let unreadableCount = pb.changeCount
    do { _ = try ClipboardLease(pb); throw DeliveryRefusal(reason: "platform_test_unreadable_accepted") }
    catch let error as DeliveryRefusal {
        try check(error.reason == "clipboard_snapshot_incomplete" && error.diagnostics?["unreadableFormat"] == "public.png", "unreadable_payload_refused_with_diagnostic")
    }
    try check(pb.changeCount == unreadableCount, "unreadable_clipboard_unchanged")
    print("PASS: \(checks) private-pasteboard and cross-process lock checks. No general clipboard or Codex access.")
}
