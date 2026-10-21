import AppKit
import Carbon

@main struct PresentationTestMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func event(_ id: AEEventID = kAEOpenApplication) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        let login = event()
        login.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        let marker = event()
        marker.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)
        let reopen = event(kAEReopenApplication)
        reopen.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        check(AppPresentation.isLoginLaunch(login), "login launch reason must be recognized")
        check(AppPresentation.isLoginLaunch(marker), "login marker must be recognized")
        check(!AppPresentation.isLoginLaunch(nil), "manual launch without event")
        check(!AppPresentation.isLoginLaunch(event()), "ordinary open event")
        check(!AppPresentation.isLoginLaunch(reopen), "reopen must remain a manual request")
        check(!AppPresentation.shouldShowWindow(loginLaunch: true, arguments: []), "login must stay hidden")
        check(!AppPresentation.shouldShowWindow(loginLaunch: false, arguments: ["app", "--background"]), "background launch must stay hidden")
        check(AppPresentation.shouldShowWindow(loginLaunch: false, arguments: ["app"]), "manual launch must show window")
        let alert = AppPresentation.quitAlert()
        check(alert.buttons.map(\.title) == ["Keep Running", "Quit Codex Drop"], "separate cancel and quit choices")
        check(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty, "Return must keep receiver running")
        check(alert.buttons[1].hasDestructiveAction, "quit must be marked destructive")
        check(alert.informativeText.contains("iPhone") && alert.informativeText.contains("won’t reach Codex"), "explain the consequence")
        // Exercise both AppKit modal responses using only this fixture's alerts.
        for (index, response) in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn].enumerated() {
            let dialog = AppPresentation.quitAlert()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dialog.buttons[index].performClick(nil) }
            check(dialog.runModal() == response, "modal must return the selected choice")
        }
        print("Presentation checks passed: \(checks) (login/manual launch, safe default, both quit dialog choices).")
    }
}
