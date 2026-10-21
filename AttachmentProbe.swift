import AppKit
import ApplicationServices
import Foundation

// User-run probe only. No Return key, send action, draft rewrite, or automatic undo.
enum ProbeError: Error, CustomStringConvertible {
    case refused(String)
    var description: String { switch self { case .refused(let text): return text } }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.refused(message) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
    var stack = [root], result: [AXUIElement] = []
    var visited = Set<AXUIElement>()
    while let next = stack.popLast() {
        guard visited.insert(next).inserted else { continue }
        result.append(next)
        try require(result.count <= 12_000, "Accessibility tree exceeds the probe's limit; nothing was pasted.")
        stack.append(contentsOf: attribute(next, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return result
}

func selectionIsEmpty(_ element: AXUIElement) -> Bool {
    if let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        if AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) {
            return range.length == 0
        }
    }
    if let selected = stringAttribute(element, kAXSelectedTextAttribute) { return selected.isEmpty }
    return false // Unknown selection is not safe enough to paste over.
}

func draftUnchanged(_ before: String, _ after: String?) -> Bool {
    guard let after else { return false }
    return before.utf8.elementsEqual(after.utf8)
}
func shouldRestoreClipboard(expected: Int, current: Int) -> Bool { expected == current }

func pasteMenuItem(_ app: AXUIElement) throws -> AXUIElement {
    guard let menuBar = elementAttribute(app, kAXMenuBarAttribute) else {
        throw ProbeError.refused("Codex does not expose its menu bar. Nothing was pasted.")
    }
    let matches = try descendants(menuBar).filter { element in
        guard stringAttribute(element, kAXRoleAttribute) == kAXMenuItemRole else { return false }
        let title = stringAttribute(element, kAXTitleAttribute)?.lowercased() ?? ""
        // Match the actual command name, never an arbitrary Command-V binding.
        // Unrecognized languages fail closed rather than guessing an action.
        return ["paste", "incolla", "coller", "einsetzen", "einfügen", "pegar", "plakken", "colar"].contains(title)
    }
    try require(matches.count == 1, "Could not uniquely identify the plain Paste menu command. Nothing was pasted.")
    let item = matches[0]
    var actions: CFArray?
    try require(AXUIElementCopyActionNames(item, &actions) == .success &&
                (actions as? [String] ?? []).contains(kAXPressAction), "Paste menu command cannot be invoked. Nothing was pasted.")
    return item
}

// Only labels for buttons/images are inspected; draft/transcript text is never printed.
func attachmentIndicators(_ root: AXUIElement) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for element in try descendants(root) {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        guard [kAXButtonRole, kAXImageRole].contains(role) else { continue }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { stringAttribute(element, $0) }.joined(separator: " ").lowercased()
        if label.contains("remove") || label.contains("attachment") || label.contains("image.png") {
            result[role + ":" + label, default: 0] += 1
        }
    }
    return result
}

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int

    init(_ pasteboard: NSPasteboard) throws {
        changeCount = pasteboard.changeCount
        items = try (pasteboard.pasteboardItems ?? []).map { item in
            var result: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw ProbeError.refused("A clipboard format cannot be backed up; nothing was pasted.")
                }
                result[type] = data
            }
            return result
        }
        try require(pasteboard.changeCount == changeCount, "Clipboard changed while being backed up; try again.")
    }

    func restore(_ pasteboard: NSPasteboard, expected: Int) -> String {
        guard shouldRestoreClipboard(expected: expected, current: pasteboard.changeCount) else {
            return "Clipboard changed elsewhere; left the newer clipboard intact."
        }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
            ? "Previous clipboard restored." : "WARNING: clipboard restoration failed."
    }
}

func testImage() throws -> Data {
    let image = NSImage(size: NSSize(width: 600, height: 360))
    image.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.25, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 360)).fill()
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white]
    let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.white]
    ("CODEX ATTACHMENT TEST" as NSString).draw(at: NSPoint(x: 36, y: 230), withAttributes: title)
    ("Unsent image / safe to remove" as NSString).draw(at: NSPoint(x: 36, y: 170), withAttributes: detail)
    (UUID().uuidString.prefix(8).description as NSString).draw(at: NSPoint(x: 36, y: 70), withAttributes: detail)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ProbeError.refused("Could not generate the test image.")
    }
    return png
}

func runSelfTests() throws {
    var count = 0
    func check(_ condition: Bool, _ name: String) throws {
        try require(condition, "Self-test failed: " + name); count += 1
    }
    try check(draftUnchanged("existing draft\nsecond line 🧗", "existing draft\nsecond line 🧗"), "multiline draft preserved")
    try check(!draftUnchanged("existing draft", ""), "cleared draft detected")
    try check(!draftUnchanged("existing draft", "existing draftimage.png"), "inserted text detected")
    try check(!draftUnchanged("existing draft", nil), "unreadable draft rejected")
    try check(draftUnchanged("", ""), "empty draft supported")
    try check(!draftUnchanged("é", "e\u{301}"), "Unicode normalization changes detected")
    try check(shouldRestoreClipboard(expected: 10, current: 10), "own clipboard eligible for restoration")
    try check(!shouldRestoreClipboard(expected: 10, current: 11), "newer clipboard preserved")
    // Exercise the real snapshot/restore code using an isolated pasteboard,
    // never NSPasteboard.general or the user's clipboard.
    let isolated = NSPasteboard.withUniqueName()
    defer { isolated.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("multiline\ndraft 🧗", forType: .string)
    first.setData(Data([0, 1, 255]), forType: NSPasteboard.PasteboardType("com.example.probe-test"))
    let second = NSPasteboardItem()
    second.setData(Data([9, 8, 7]), forType: .png)
    try check(isolated.writeObjects([first, second]), "isolated clipboard fixture")
    let saved = try ClipboardSnapshot(isolated)
    isolated.clearContents()
    isolated.setData(Data([4, 5]), forType: .png)
    let restored = saved.restore(isolated, expected: isolated.changeCount)
    try check(restored == "Previous clipboard restored.", "actual clipboard restoration")
    let roundTrip = try ClipboardSnapshot(isolated)
    try check(roundTrip.items == saved.items, "all clipboard items and formats round-trip exactly")
    isolated.clearContents()
    isolated.setString("newer copy", forType: .string)
    let skipped = saved.restore(isolated, expected: saved.changeCount)
    try check(skipped.contains("newer clipboard"), "newer clipboard restoration refused")
    try check(isolated.string(forType: .string) == "newer copy", "newer clipboard contents retained")
    let image = try testImage()
    try check(Array(image.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "generated image is PNG")
    try image.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("test-image.png"))
    print("PASS: \(count) checks, including isolated clipboard round-trip and PNG generation.")
    print("No system clipboard or Accessibility access; no UI interaction. Preview saved as test-image.png.")
}

func runProbe(inspectOnly: Bool) throws {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    try require(AXIsProcessTrustedWithOptions(options),
                "Accessibility access is required. Enable the launching terminal/helper in System Settings → Privacy & Security → Accessibility, then rerun. No paste was attempted.")
    print("In 8 seconds: switch to Codex, select the target thread, and click its MAIN composer.")
    print("Leave the caret collapsed (no selected text), then keep hands off until the check finishes.")
    fflush(stdout)
    for remaining in stride(from: 8, through: 1, by: -1) { print("\(remaining)…"); fflush(stdout); Thread.sleep(forTimeInterval: 1) }

    guard let application = NSWorkspace.shared.frontmostApplication else { throw ProbeError.refused("No frontmost application.") }
    try require(application.bundleIdentifier == "com.openai.codex", "Codex is not frontmost. Nothing was pasted.")
    let app = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 2)
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute),
          let editor = elementAttribute(app, kAXFocusedUIElementAttribute) else {
        throw ProbeError.refused("No focused Codex window/text field. Click the main composer and rerun.")
    }
    let role = stringAttribute(editor, kAXRoleAttribute) ?? "unknown"
    print("Target PID: \(application.processIdentifier); focused role: \(role)")
    try require(role == kAXTextAreaRole, "Focused element is not a text area. Click the main composer and rerun.")
    try require(try descendants(window).contains(where: { CFEqual($0, editor) }), "Focused editor is outside the selected window.")
    guard let draft = stringAttribute(editor, kAXValueAttribute) else {
        throw ProbeError.refused("The editor does not expose its draft text; cannot verify preservation. Nothing was pasted.")
    }
    try require(selectionIsEmpty(editor), "Selection is nonempty or unreadable. Click once to place a caret, then rerun.")
    print("Draft snapshot: \(draft.utf16.count) UTF-16 units. Contents kept in memory only.")
    if inspectOnly { print("INSPECTION ONLY: target readable; no image generated, clipboard change, or paste."); return }

    let beforeIndicators = try attachmentIndicators(window)
    let png = try testImage()
    let paste = try pasteMenuItem(app)
    let pasteboard = NSPasteboard.general
    let saved = try ClipboardSnapshot(pasteboard)
    var ownedChangeCount: Int?
    defer { if let expected = ownedChangeCount { print(saved.restore(pasteboard, expected: expected)) } }

    // Recheck focus and draft immediately before the only mutation.
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                "Application focus changed; nothing was pasted.")
    guard let currentWindow = elementAttribute(app, kAXFocusedWindowAttribute), CFEqual(currentWindow, window),
          let currentEditor = elementAttribute(app, kAXFocusedUIElementAttribute), CFEqual(currentEditor, editor) else {
        throw ProbeError.refused("Window/editor focus changed; nothing was pasted.")
    }
    try require(draftUnchanged(draft, stringAttribute(editor, kAXValueAttribute)) && selectionIsEmpty(editor),
                "Draft or selection changed; nothing was pasted.")
    try require(pasteboard.changeCount == saved.changeCount, "Clipboard changed; nothing was pasted.")
    pasteboard.clearContents()
    ownedChangeCount = pasteboard.changeCount
    try require(pasteboard.setData(png, forType: .png), "Could not write the test image to the clipboard.")
    ownedChangeCount = pasteboard.changeCount
    try require(AXUIElementPerformAction(paste, kAXPressAction as CFString) == .success,
                "Paste menu command failed. Inspect the composer manually; no retry or undo was attempted.")
    print("Invoked ONE Paste menu command in Codex. No keystrokes or Send action were issued.")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 2.5)

    guard let afterWindow = elementAttribute(app, kAXFocusedWindowAttribute), CFEqual(afterWindow, window),
          let afterEditor = elementAttribute(app, kAXFocusedUIElementAttribute), CFEqual(afterEditor, editor) else {
        throw ProbeError.refused("INCONCLUSIVE: focus changed after paste. Check the thumbnail/draft manually; no undo was attempted.")
    }
    try require(draftUnchanged(draft, stringAttribute(editor, kAXValueAttribute)),
                "FAIL: draft text changed or became unreadable. Inspect it manually; no automatic undo or rewrite was attempted.")
    print("PASS: draft text is byte-for-byte equal to the pre-paste snapshot.")
    let afterIndicators = try attachmentIndicators(window)
    let additions = afterIndicators.reduce(0) { $0 + max(0, $1.value - (beforeIndicators[$1.key] ?? 0)) }
    if additions > 0 {
        print("Found \(additions) additional attachment-related Accessibility indicator(s).")
    } else {
        print("Attachment visibility was NOT confirmed through Accessibility.")
    }
    print("VISUAL CHECK REQUIRED: confirm the blue test-image thumbnail appears in this thread's UNSENT composer.")
    print("This probe never reads a thread ID. Targeting is the frontmost window's focused text area.")
}

do {
    let arguments = Set(CommandLine.arguments.dropFirst())
    try require(arguments.isSubset(of: ["--self-test", "--inspect", "--help"]), "Unknown argument. Use --inspect, --self-test, or --help.")
    try require(arguments.count <= 1, "Choose only one mode: --inspect, --self-test, or --help.")
    if arguments.contains("--help") {
        print("AttachmentProbe [--inspect | --self-test]\nDefault: 8-second countdown, then paste a generated image into the focused Codex composer. Never sends.\n--inspect: inspect target/draft readability without touching clipboard or UI.\n--self-test: isolated clipboard/image checks; no system clipboard or UI interaction.")
    } else if arguments.contains("--self-test") { try runSelfTests() }
    else { try runProbe(inspectOnly: arguments.contains("--inspect")) }
} catch {
    fputs("\nSTOP: \(error)\n", stderr)
    exit(1)
}
