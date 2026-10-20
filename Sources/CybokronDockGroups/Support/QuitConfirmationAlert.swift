import AppKit
import DockGroupsCore

/// Asks, in an alert, whether a `cybokrondockgroups://quit/…` link may quit a group's apps
/// (`GroupQuitRequests`). Only a click on the quit button says yes: Return doesn't, and Escape
/// cancels, so a page or script that also sends key presses can't answer for the user. The quit
/// button is disabled (not hidden: VoiceOver still reads it) for
/// `QuitConfirmation.confirmButtonDelay` after the alert appears, so a click already on its way
/// can't land on it; Cancel and Escape work at once.
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
        quit.isEnabled = false
        cancel.keyEquivalent = "\u{1b}"
        // runModal runs the main run loop in the modal panel mode, which .common includes.
        let enable = Timer(timeInterval: QuitConfirmation.confirmButtonDelay, repeats: false) { [weak quit] _ in
            MainActor.assumeIsolated { quit?.isEnabled = true }
        }
        RunLoop.main.add(enable, forMode: .common)
        defer { enable.invalidate() }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
