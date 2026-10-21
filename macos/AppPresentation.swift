import AppKit
import Carbon

@MainActor enum AppPresentation {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == kAEOpenApplication else { return false }
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem ||
            event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }

    static func shouldShowWindow(loginLaunch: Bool, arguments: [String]) -> Bool {
        !loginLaunch && !arguments.contains("--background")
    }

    static func quitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Codex Drop?"
        alert.informativeText = "Screenshots shared from your iPhone won’t reach Codex while Codex Drop is quit. Open Codex Drop again to resume receiving."
        alert.addButton(withTitle: "Keep Running").keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: "Quit Codex Drop")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        return alert
    }
}
