import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import ImageIO

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

// Keep the actual decision read and its AX status together. Diagnostics must not
// reread a healthy decision or replace unavailable values with a guessed target.
private func axElementWithStatus(_ element: AXUIElement, _ name: String) -> (element: AXUIElement?, status: AXError) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, status) }
    let element = value as! AXUIElement
    return (element, status)
}

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
/// A private, independently named snapshot outlives clipboard restoration and
/// process exit so asynchronous file-copy readers keep the exact eager bytes.
/// Canonical UUID names are covered by the receiver's 30-day orphan retention.
private func persistOriginalSnapshot(_ image: OriginalImage) throws -> URL {
    let directory = image.fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw DeliveryRefusal(reason: "image_snapshot_directory_unavailable") }
    defer { close(directoryFD) }
    var directoryInfo = stat()
    guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
          directoryInfo.st_uid == getuid() else { throw DeliveryRefusal(reason: "unsafe_image_snapshot_directory") }
    let name = UUID().uuidString.lowercased() + "." + image.type.fileExtension
    let url = directory.appendingPathComponent(name)
    let descriptor = openat(directoryFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DeliveryRefusal(reason: "image_snapshot_unavailable") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
        guard image.data.count <= ImageLimits.maxBytes else { throw DeliveryRefusal(reason: "image_size_limit") }
        try handle.write(contentsOf: image.data)
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        let verified = try handle.read(upToCount: image.data.count + 1) ?? Data()
        var info = stat(), named = stat()
        guard verified.count == image.data.count, SHA256.hash(data: verified) == SHA256.hash(data: image.data),
              fstat(descriptor, &info) == 0, lstat(url.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_uid == getuid(), named.st_mode & 0o077 == 0,
              named.st_ino == info.st_ino, named.st_dev == info.st_dev, fsync(directoryFD) == 0 else {
            throw DeliveryRefusal(reason: "image_snapshot_checksum_changed")
        }
        return url
    } catch {
        unlinkat(directoryFD, name, 0)
        throw error
    }
}

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
            var missing: [NSPasteboard.PasteboardType] = []
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
                else { missing.append(type) }
            }
            for type in missing {
                guard let data = Self.recoverTextRepresentation(type, from: copy) ?? Self.recoverImageRepresentation(type, from: copy) else {
                    throw DeliveryRefusal(reason: "clipboard_snapshot_incomplete", diagnostics: [
                        "unreadableFormat": type.rawValue,
                        "readableFormats": copy.keys.map(\.rawValue).sorted().joined(separator: ","),
                        "recovery": "Copy some plain text, then explicitly retry. The unreadable clipboard was left unchanged."
                    ])
                }
                copy[type] = data
            }
            return copy
        }
        guard pasteboard.changeCount == initialCount else { throw DeliveryRefusal(reason: "clipboard_changed_during_snapshot") }
    }
    fileprivate static func recoverTextRepresentation(_ type: NSPasteboard.PasteboardType,
                                                  from values: [NSPasteboard.PasteboardType: Data]) -> Data? {
        let external = NSPasteboard.PasteboardType("public.utf16-external-plain-text")
        if type == external, let bytes = values[.string], let text = String(data: bytes, encoding: .utf8),
           text.data(using: .utf8) == bytes {
            return text.data(using: .utf16)
        }
        if type == .string, let bytes = values[external], bytes.count >= 2, bytes.count.isMultiple(of: 2),
           bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]),
           let text = String(data: bytes, encoding: .utf16),
           text.data(using: bytes.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : .utf16BigEndian) == Data(bytes.dropFirst(2)) {
            return text.data(using: .utf8)
        }
        return nil
    }
    private static func recoverImageRepresentation(_ type: NSPasteboard.PasteboardType,
                                                   from values: [NSPasteboard.PasteboardType: Data]) -> Data? {
        // iPhone clipboard items can supply their original HEIC while advertising
        // PNG/JPEG promises that never materialize. Keep every readable format
        // byte-for-byte and eagerly fulfill only these known image alternatives.
        // Unknown/missing formats and images we cannot decode still block safely.
        guard ["public.png", "public.jpeg"].contains(type.rawValue) else { return nil }
        for sourceType in ["public.png", "public.tiff", "public.heic", "public.heif", "public.jpeg"] {
            guard let bytes = values[.init(sourceType)],
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1 else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.rawValue as CFString, 1, nil) else { continue }
            // ImageIO retains source image properties, including orientation and
            // color profile. Only the unavailable alternate representation changes.
            let properties = type.rawValue == "public.jpeg" ? [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary : nil
            CGImageDestinationAddImageFromSource(destination, source, 0, properties)
            if CGImageDestinationFinalize(destination) { return data as Data }
        }
        return nil
    }
    func stage(_ image: OriginalImage) throws {
        let snapshot = try persistOriginalSnapshot(image)
        guard pasteboard.changeCount == initialCount else { throw DeliveryRefusal(reason: "clipboard_changed_before_stage") }
        let item = NSPasteboardItem()
        // File-copy semantics only: raw bitmap types let Chromium transcode the image.
        // This eager URL has no lazy provider and its private file is retained.
        guard item.setString(snapshot.absoluteString, forType: .fileURL) else { throw DeliveryRefusal(reason: "clipboard_file_url_failed") }
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
        let acquisitionStarted = now
        let initialFocusRead = axElementWithStatus(app, kAXFocusedUIElementAttribute)
        let initialFocus = initialFocusRead.element
        let title = axString(window, kAXTitleAttribute) ?? ""
        var activationDetails: [String: String] = [:]
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
        func invariants(detailed: Bool = false) -> (unchanged: Bool, window: ActivationWindowIdentity, contentUnchanged: Bool, details: [String: String]) {
            let focusedWindowRead = axElementWithStatus(app, kAXFocusedWindowAttribute)
            let mainWindowRead = axElementWithStatus(app, kAXMainWindowAttribute)
            let focusedWindow = focusedWindowRead.element
            let mainWindow = mainWindowRead.element
            let currentWindow = focusedWindow ?? mainWindow
            let windowSame = currentWindow.map { CFEqual($0, window) } ?? false
            let windowIdentity: ActivationWindowIdentity = currentWindow == nil ? .unavailable : windowSame ? .same : .changed
            let titleSame = (axString(window, kAXTitleAttribute) ?? "") == title
            let after = axString(candidate, kAXValueAttribute)
            let projected = after.flatMap { try? captureComposerDraft(candidate, text: $0) }
            let draftSame = projected == draft
            let counts = try? attachmentCounts(scope)
            let attachmentsSame = counts == attachments
            let selection = axSelectionState(candidate)
            let selectionEmpty = selection.empty
            var details = ["windowObjectSame": String(windowSame), "windowTitleSame": String(titleSame),
                           "focusedWindowAvailable": String(focusedWindow != nil), "mainWindowAvailable": String(mainWindow != nil),
                           "windowIdentity": windowIdentity == .same ? "same" : windowIdentity == .unavailable ? "unavailable" : "changed",
                           "draftReadable": String(after != nil), "draftSame": String(draftSame),
                           "draftBeforeBytes": String(draft.count), "rawBeforeBytes": String(text.utf8.count),
                           "draftAfterBytes": projected.map { String($0.count) } ?? "unavailable",
                           "rawAfterBytes": after.map { String($0.utf8.count) } ?? "unavailable",
                           "attachmentsReadable": String(counts != nil), "attachmentsSame": String(attachmentsSame),
                           "selectionEmpty": String(selectionEmpty), "selectionReadable": String(selection.readable),
                           "selectionLength": selection.length.map { String($0) } ?? "unavailable"]
            details["focusedWindowAXStatus"] = String(focusedWindowRead.status.rawValue)
            details["mainWindowAXStatus"] = String(mainWindowRead.status.rawValue)
            details["acquisitionElapsedMS"] = String(Int((now - acquisitionStarted) * 1000))
            details.merge(activationDetails) { _, new in new }
            if detailed, let after { details.merge(draftAXMetadata(candidate, text: after)) { _, new in new } }
            let contentUnchanged = titleSame && draftSame && attachmentsSame && selectionEmpty
            return (windowSame && contentUnchanged, windowIdentity, contentUnchanged, details)
        }
        if focusDiagnostic {
            var baseline = draftAXMetadata(candidate, text: text)
            baseline["phase"] = "beforeActivation"; baseline["draftBytes"] = String(draft.count)
            focusSamples.append(baseline)
        }
        var discoveryWindowDetails: [String: String] = [:]
        func sameWindow() -> Bool {
            let focused = axElementWithStatus(app, kAXFocusedWindowAttribute)
            let main = focused.element == nil ? axElementWithStatus(app, kAXMainWindowAttribute) : nil
            let current = focused.element ?? main?.element
            let equal = current.map { CFEqual($0, window) } ?? false
            // Preserve the original short circuit: no title read without equality.
            let titleSame = equal && (axString(window, kAXTitleAttribute) ?? "") == title
            discoveryWindowDetails = ["discoveryFocusedWindowAXStatus": String(focused.status.rawValue),
                "discoveryMainWindowAXStatus": main.map { String($0.status.rawValue) } ?? "not_read_focused_window_available",
                "discoveryWindowSource": focused.element != nil ? "focused" : current != nil ? "main" : "none",
                "discoveryWindowEqual": String(equal), "discoveryTitleSame": equal ? String(titleSame) : "not_read_window_not_equal",
                "discoverySameWindow": String(equal && titleSame)]
            return equal && titleSame
        }
        let currentFocusRead = axElementWithStatus(app, kAXFocusedUIElementAttribute)
        let currentFocus = currentFocusRead.element
        let sameFocus = initialFocus.map { original in currentFocus.map { CFEqual(original, $0) } ?? false } ?? (currentFocus == nil)
        guard sameWindow(), sameFocus else {
            var details = discoveryWindowDetails
            details["initialFocusedUIAXStatus"] = String(initialFocusRead.status.rawValue)
            details["currentFocusedUIAXStatus"] = String(currentFocusRead.status.rawValue)
            details["discoverySameFocus"] = String(sameFocus)
            if let initialFocus, let currentFocus {
                details["focusedUIEqual"] = String(CFEqual(initialFocus, currentFocus))
            } else { details["focusedUIEqual"] = "not_comparable" }
            details["initialFocusedUIRole"] = initialFocus.flatMap { axString($0, kAXRoleAttribute) } ?? "unavailable"
            details["currentFocusedUIRole"] = currentFocus.flatMap { axString($0, kAXRoleAttribute) } ?? "unavailable"
            details["targetPID"] = String(applicationPID(app))
            details["failureForegroundPID"] = NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) } ?? "none"
            details["acquisitionElapsedMS"] = String(Int((now - acquisitionStarted) * 1000))
            // Role metadata is deliberately read only after the refusal decision.
            throw DeliveryRefusal(reason: "target_changed_during_discovery", diagnostics: details)
        }
        if needsActiveResponder {
            let pid = applicationPID(app)
            let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
            activationDetails = ["targetPID": String(pid), "previousForegroundPID": previous.map(String.init) ?? "none",
                "activationRequestedCount": "0", "activationAccepted": "not_requested"]
            if previous != pid {
                guard let target = NSRunningApplication(processIdentifier: pid), target.bundleIdentifier == expectedBundleID else {
                    throw DeliveryRefusal(reason: "codex_activation_failed", diagnostics: activationDetails)
                }
                activationDetails["activationRequestedCount"] = "1"
                let accepted = target.activate(options: [.activateIgnoringOtherApps])
                activationDetails["activationAccepted"] = String(accepted)
                guard accepted else { throw DeliveryRefusal(reason: "codex_activation_failed", diagnostics: activationDetails) }
            }
            // Workspace activation acknowledgement can precede AX window readiness.
            // Wait only for missing window values; the original window/editor stay
            // pinned and a different window or any content change refuses at once.
            try ComposerActivationGuard.waitUntilReady(now: { self.now }, wait: { self.wait($0) }) {
                guard !self.cancelled else { throw DeliveryRefusal(reason: "interrupted") }
                let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard active == pid || active == nil || active == previous else {
                    var details = activationDetails
                    details["failureForegroundPID"] = active.map(String.init) ?? "none"
                    throw DeliveryRefusal(reason: "foreground_changed_during_activation", diagnostics: details)
                }
                let state = invariants()
                if self.focusDiagnostic {
                    var sample = state.details
                    sample["phase"] = "activationReadiness"
                    sample["codexFrontmost"] = String(active == pid)
                    self.focusSamples.append(sample)
                }
                var details = state.details
                details["currentForegroundPID"] = active.map(String.init) ?? "none"
                return ComposerActivationObservation(window: state.window, foregroundReady: active == pid,
                    contentUnchanged: state.contentUnchanged, diagnostics: details)
            }
        } else {
            let activatedState = invariants(detailed: focusDiagnostic && !diagnosticActivates)
            guard activatedState.unchanged else {
                var details = activatedState.details
                if let current = axString(candidate, kAXValueAttribute) {
                    for (key, value) in draftAXMetadata(candidate, text: current) { details["afterDecision_" + key] = value }
                }
                throw DeliveryRefusal(reason: "composer_changed_during_activation", diagnostics: details)
            }
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
        // This best-effort WindowServer flag improves refusal specificity. It is
        // never an authorization gate: false/missing/unknown retain every AX,
        // destination, draft, selection and attachment guard below. Check each
        // observation so locking during delivery also stops the existing flow.
        if fixturePasteboard == nil,
           let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           MacSessionLockState.parse(session["CGSSessionScreenIsLocked"]) == .locked {
            throw DeliveryRefusal(reason: "mac_screen_locked")
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID)
        guard applications.count == 1 else { throw DeliveryRefusal(reason: fixturePasteboard == nil ? "codex_app_not_unique" : "fixture_app_not_unique") }
        let running = applications[0]
        if let application, application.processIdentifier != running.processIdentifier { throw DeliveryRefusal(reason: "target_application_changed") }
        let axApp = app ?? AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        let initialFocused = axElementWithStatus(axApp, kAXFocusedWindowAttribute)
        let initialMain = initialFocused.element == nil ? axElementWithStatus(axApp, kAXMainWindowAttribute) : nil
        func initialWindowDetails() -> [String: String] {
            ["initialFocusedWindowAXStatus": String(initialFocused.status.rawValue),
             "initialMainWindowAXStatus": initialMain.map { String($0.status.rawValue) } ?? "not_read_focused_window_available",
             "targetPID": String(running.processIdentifier),
             "failureForegroundPID": NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) } ?? "none"]
        }
        guard let focusedWindow = initialFocused.element ?? initialMain?.element,
              (axValue(focusedWindow, kAXMinimizedAttribute) as? Bool) != true else {
            throw DeliveryRefusal(reason: "codex_window_unavailable", diagnostics: initialWindowDetails())
        }
        let focusedEditor: AXUIElement
        if let editor {
            guard composerHasFocus(editor, app: axApp) else { throw DeliveryRefusal(reason: "target_editor_changed") }
            focusedEditor = editor
        } else {
            do { focusedEditor = try acquireComposer(app: axApp, window: focusedWindow) }
            catch let refusal as DeliveryRefusal {
                var details = initialWindowDetails()
                details.merge(refusal.diagnostics ?? [:]) { _, new in new }
                throw DeliveryRefusal(reason: refusal.reason, diagnostics: details)
            }
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
    func stage(_ image: OriginalImage) throws {
        lease = try ClipboardLease(fixturePasteboard.map { NSPasteboard(name: .init($0)) } ?? .general)
        try lease?.stage(image)
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
    var result: [String: Any] = ["formats": rows]
    do {
        let snapshot = try ClipboardLease(clipboard) // Read-only; never stages or restores.
        result["snapshotReady"] = true
        result["recoveredImageFormats"] = rows.filter { row in
            guard row["dataReadable"] as? Bool == false,
                  let index = row["item"] as? Int, let type = row["type"] as? String,
                  snapshot.saved.indices.contains(index) else { return false }
            return snapshot.saved[index][.init(type)] != nil
        }.map { ["item": $0["item"]!, "type": $0["type"]!] }
    } catch let refusal as DeliveryRefusal {
        result["snapshotReady"] = false; result["reason"] = refusal.reason
    }
    result["clipboardChangedDuringRead"] = before != clipboard.changeCount
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}

func originalFileSelfTest(_ image: OriginalImage) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Codex Original 🧗 " + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source with space 🧗." + image.type.fileExtension)
    try image.data.write(to: source)
    let eager = OriginalImage(data: image.data, fileURL: source, type: image.type)
    // Eager bytes, rather than a later reread of the source, own delivery content.
    try Data("source changed after validation".utf8).write(to: source)
    let board = NSPasteboard(name: .init("com.example.CodexScreenshotReceiver.Test." + UUID().uuidString))
    defer { board.releaseGlobally() }
    board.clearContents(); board.setString("original fixture clipboard", forType: .string)
    let lease = try ClipboardLease(board)
    try lease.stage(eager)
    let items = board.pasteboardItems ?? []
    guard items.count == 1, Set(items[0].types) == [.fileURL],
          let value = items[0].string(forType: .fileURL), let snapshot = URL(string: value), snapshot.isFileURL,
          snapshot != source, snapshot.pathExtension == image.type.fileExtension else {
        throw DeliveryRefusal(reason: "platform_test_original_file_types")
    }
    let child = Process(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--read-fixture-pasteboard", board.name.rawValue]
    child.standardOutput = output; child.standardError = FileHandle.nullDevice
    try child.run()
    let deadline = Date().addingTimeInterval(5)
    while child.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    if child.isRunning { child.terminate(); child.waitUntilExit() }
    let received = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
    guard child.terminationStatus == 0, received == expected, lease.restore() == "restored",
          board.string(forType: .string) == "original fixture clipboard",
          try Data(contentsOf: snapshot) == image.data else {
        throw DeliveryRefusal(reason: "platform_test_original_file_bytes_or_lifetime")
    }
    print("Original file private-pasteboard round trip passed: \(image.type.fileExtension), exact SHA256, file-url only, retained after restore")
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
    let selfTestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Codex Original 🧗 " + UUID().uuidString)
    try FileManager.default.createDirectory(at: selfTestDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: selfTestDirectory) }
    let selfTestSource = selfTestDirectory.appendingPathComponent("source.png")
    let lease = try ClipboardLease(pb)
    let originalImage = OriginalImage(data: png, fileURL: selfTestSource, type: .png)
    try lease.stage(originalImage)
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
    try check(child.terminationStatus == 0 && received == digest, "cross_process_original_file_exact_bytes")
    try check(lease.restore() == "restored", "restoration")
    try check(pb.string(forType: .string) == "original\nclipboard 🧗", "text_round_trip")
    try check(pb.data(forType: .init("com.example.receiver-test")) == Data([0, 255, 1]), "custom_format_round_trip")
    let changed = try ClipboardLease(pb); try changed.stage(originalImage)
    pb.clearContents(); pb.setString("newer clipboard", forType: .string)
    try check(changed.restore() == "newer_preserved", "newer_preserved")
    try check(pb.string(forType: .string) == "newer clipboard", "newer_untouched")
    let stale = try ClipboardLease(pb)
    pb.clearContents(); pb.setString("changed before stage", forType: .string)
    do { try stale.stage(originalImage); throw DeliveryRefusal(reason: "platform_test_stale_stage_accepted") }
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
    let textProvider = UnreadableProvider()
    let utf16External = NSPasteboard.PasteboardType("public.utf16-external-plain-text")
    let text = "clipboard\r\n🧗 e\u{301} العربية\u{0}tail"
    let utf8Bytes = Data(text.utf8)
    let opaqueType = NSPasteboard.PasteboardType("com.example.text-metadata")
    let opaqueBytes = Data([0, 255, 42])
    let promisedText = NSPasteboardItem()
    promisedText.setDataProvider(textProvider, forTypes: [utf16External])
    promisedText.setData(utf8Bytes, forType: .string)
    promisedText.setData(opaqueBytes, forType: opaqueType)
    pb.clearContents(); try check(pb.writeObjects([promisedText]), "promised_utf16_fixture")
    let textCount = pb.changeCount
    let textLease = try ClipboardLease(pb)
    try check(pb.changeCount == textCount, "text_recovery_does_not_modify_clipboard")
    try textLease.stage(originalImage)
    try check(textLease.restore() == "restored", "promised_utf16_restored")
    let restoredText = pb.pasteboardItems![0]
    try check(restoredText.data(forType: .string) == utf8Bytes, "readable_utf8_bytes_preserved")
    try check(restoredText.data(forType: opaqueType) == opaqueBytes, "text_metadata_bytes_preserved")
    try check(restoredText.data(forType: utf16External).flatMap { String(data: $0, encoding: .utf16) } == text,
              "utf16_recovery_preserves_unicode_and_control_characters")
    let reverseText = NSPasteboardItem()
    reverseText.setDataProvider(textProvider, forTypes: [.string])
    let utf16Bytes = Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!
    reverseText.setData(utf16Bytes, forType: utf16External)
    pb.clearContents(); try check(pb.writeObjects([reverseText]), "promised_utf8_fixture")
    let reverseLease = try ClipboardLease(pb)
    try reverseLease.stage(originalImage)
    try check(reverseLease.restore() == "restored", "promised_utf8_restored")
    try check(pb.pasteboardItems![0].data(forType: .string) == utf8Bytes &&
              pb.pasteboardItems![0].data(forType: utf16External) == utf16Bytes, "reverse_text_recovery_preserves_bytes")
    let invalidTexts: [(NSPasteboard.PasteboardType, NSPasteboard.PasteboardType, Data)] = [
        (.string, utf16External, Data([0xc3, 0x28])),
        (utf16External, .string, Data([0xff, 0xfe, 0x00, 0xd8])),
        (utf16External, .string, Data([0x41, 0x00])),
        (utf16External, .string, Data([0xff, 0xfe, 0x00]))
    ]
    for (source, target, bytes) in invalidTexts {
        try check(ClipboardLease.recoverTextRepresentation(target, from: [source: bytes]) == nil,
                  "invalid_encoding_is_never_recovered")
        let corruptText = NSPasteboardItem()
        corruptText.setData(bytes, forType: source)
        corruptText.setDataProvider(textProvider, forTypes: [target])
        pb.clearContents(); try check(pb.writeObjects([corruptText]), "corrupt_text_fixture")
        let count = pb.changeCount
        // AppKit can fulfill a text alternate itself before our snapshot reads
        // it. Readable formats are preserved verbatim, even if another format
        // contains invalid bytes; recovery only handles unavailable formats.
        if pb.pasteboardItems![0].data(forType: target) == nil {
            do { _ = try ClipboardLease(pb); throw DeliveryRefusal(reason: "platform_test_corrupt_text_accepted") }
            catch let error as DeliveryRefusal { try check(error.reason == "clipboard_snapshot_incomplete", "corrupt_text_refused") }
        } else {
            let readable = try ClipboardLease(pb)
            try check(readable.saved[0][source] == bytes, "readable_invalid_source_preserved_verbatim")
        }
        try check(pb.changeCount == count, "corrupt_text_clipboard_unchanged")
    }
    // Reproduce an iPhone clipboard: readable HEIC, promised but unavailable
    // PNG/JPEG, and CoreDevice metadata. Snapshotting must preserve usable data
    // and restore working alternate image representations after a drop.
    let heic = NSMutableData()
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let destination = CGImageDestinationCreateWithData(heic, "public.heic" as CFString, 1, nil) else {
        throw DeliveryRefusal(reason: "platform_test_heic_fixture")
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try check(CGImageDestinationFinalize(destination), "heic_fixture_encoded")
    let heicType = NSPasteboard.PasteboardType("public.heic")
    let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    let syncType = NSPasteboard.PasteboardType("com.apple.coredevice.dtpasteboardd.sync")
    let syncData = Data("synthetic device metadata".utf8)
    let imageProvider = UnreadableProvider()
    func promisedImage() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Register missing types first: recovery must not depend on type order.
        item.setDataProvider(imageProvider, forTypes: [.png, jpegType])
        item.setData(heic as Data, forType: heicType)
        item.setData(syncData, forType: syncType)
        return item
    }
    let secondItem = NSPasteboardItem(); secondItem.setString("second item", forType: .string)
    pb.clearContents(); try check(pb.writeObjects([promisedImage(), secondItem]), "promised_image_fixture")
    let promisedCount = pb.changeCount
    let imageLease = try ClipboardLease(pb)
    try check(pb.changeCount == promisedCount, "image_recovery_does_not_modify_clipboard")
    try imageLease.stage(originalImage)
    try check(imageLease.restore() == "restored", "promised_image_restored")
    let restored = pb.pasteboardItems ?? []
    try check(restored.count == 2 && restored[1].string(forType: .string) == "second item", "image_recovery_preserves_items")
    try check(restored[0].data(forType: heicType) == heic as Data, "heic_original_bytes_preserved")
    try check(restored[0].data(forType: syncType) == syncData, "device_metadata_preserved")
    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(heic, nil)!, 0, nil)! as NSDictionary
    for type in [NSPasteboard.PasteboardType.png, jpegType] {
        guard let bytes = restored[0].data(forType: type),
              let decoded = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as NSDictionary? else {
            throw DeliveryRefusal(reason: "platform_test_recovered_image_unreadable")
        }
        try check(CGImageSourceGetType(decoded) as String? == type.rawValue && CGImageSourceCreateImageAtIndex(decoded, 0, nil) != nil,
                  "recovered_image_decodes_" + type.rawValue)
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
            try check(properties[key] as? Int == sourceProperties[key] as? Int, "recovered_image_geometry_" + type.rawValue)
        }
    }
    pb.clearContents(); try check(pb.writeObjects([promisedImage()]), "promised_newer_fixture")
    let imageChanged = try ClipboardLease(pb); try imageChanged.stage(originalImage)
    pb.clearContents(); pb.setString("newer clipboard", forType: .string)
    try check(imageChanged.restore() == "newer_preserved" && pb.string(forType: .string) == "newer clipboard",
              "image_recovery_preserves_newer_clipboard")
    let customMissing = promisedImage()
    customMissing.setDataProvider(imageProvider, forTypes: [.init("com.example.missing-private-data")])
    pb.clearContents(); try check(pb.writeObjects([customMissing]), "missing_custom_fixture")
    let customCount = pb.changeCount
    do { _ = try ClipboardLease(pb); throw DeliveryRefusal(reason: "platform_test_missing_custom_accepted") }
    catch let error as DeliveryRefusal {
        try check(error.reason == "clipboard_snapshot_incomplete", "missing_custom_refused")
    }
    try check(pb.changeCount == customCount, "missing_custom_clipboard_unchanged")
    let corruptImage = NSPasteboardItem()
    corruptImage.setData(Data("not an image".utf8), forType: heicType)
    corruptImage.setDataProvider(imageProvider, forTypes: [.png])
    pb.clearContents(); try check(pb.writeObjects([corruptImage]), "corrupt_image_fixture")
    let corruptCount = pb.changeCount
    do { _ = try ClipboardLease(pb); throw DeliveryRefusal(reason: "platform_test_corrupt_image_accepted") }
    catch let error as DeliveryRefusal {
        try check(error.reason == "clipboard_snapshot_incomplete", "corrupt_image_refused")
    }
    try check(pb.changeCount == corruptCount, "corrupt_clipboard_unchanged")
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
