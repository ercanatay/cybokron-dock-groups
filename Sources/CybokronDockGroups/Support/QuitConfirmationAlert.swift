import AppKit
import DockGroupsCore

/// Asks, in an alert, whether a `cybokrondockgroups://quit/…` link may quit a group's apps
/// (`GroupQuitRequests`). Only a click on the quit button says yes: Return doesn't, and Escape
/// cancels, so a page or script that also sends key presses can't answer for the user.
@MainActor
final class QuitConfirmationAlert: QuitConfirmationPrompting {
    func confirm(_ confirmation: QuitConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = confirmation.mode == .force ? .critical : .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        let quit = alert.addButton(withTitle: confirmation.confirmButton)
        let cancel = alert.addButton(withTitle: confirmation.cancelButton)
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
