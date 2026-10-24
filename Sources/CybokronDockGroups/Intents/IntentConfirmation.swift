import AppIntents
import DockGroupsCore

/// The question an intent asks in Siri or the Shortcuts app before it quits apps — Quit Group,
/// Start Group and Finish Group alike (spec §3.8): `requestConfirmation(actionName:dialog:)` on
/// macOS 15 and later, the variant later SDKs deprecate on macOS 14 (`MacOS14Confirming`). The
/// buttons are the app's alert's; destructive only for force quitting, which only Quit Group does.
/// Declining throws; the error isn't caught, so it ends the intent the way the system ends a
/// declined confirmation, and nothing is done.
protocol IntentConfirming: AppIntent, MacOS14Confirming {}

extension IntentConfirming {
    @MainActor
    func askFirst(dialog: String, acceptLabel: String, denyLabel: String, destructive: Bool = false) async throws {
        let action = ConfirmationActionName.custom(
            acceptLabel: "\(acceptLabel)",
            acceptAlternatives: [],
            denyLabel: "\(denyLabel)",
            denyAlternatives: [],
            destructive: destructive
        )
        let dialog: IntentDialog = "\(dialog)"
        if #available(macOS 15, *) {
            try await requestConfirmation(actionName: action, dialog: dialog)
        } else {
            try await (self as MacOS14Confirming).requestConfirmationOnMacOS14(actionName: action, dialog: dialog)
        }
    }

    /// Asks before a transition quits apps: its title and which apps quit, with Quit and Switch
    /// (Quit Apps when finishing) and Cancel. Siri has no "Hide Instead": declining stops it.
    @MainActor
    func askFirst(_ confirmation: TransitionConfirmation) async throws {
        try await askFirst(dialog: confirmation.intentDialog, acceptLabel: confirmation.confirmButton, denyLabel: confirmation.cancelButton)
    }
}

/// macOS 14 has only the confirmation that later SDKs deprecate,
/// `requestConfirmation(result:confirmationActionName:showPrompt:)`. Called through this protocol,
/// from a method marked deprecated itself, it doesn't warn in the build; macOS 15 and later use
/// `requestConfirmation(actionName:dialog:)`. Each intent implements it itself (a deprecated
/// default implementation would warn), with `confirmOnMacOS14`.
protocol MacOS14Confirming {
    func requestConfirmationOnMacOS14(actionName: ConfirmationActionName, dialog: IntentDialog) async throws
}

@available(*, deprecated, message: "macOS 14 only: use requestConfirmation(actionName:dialog:)")
private func confirmOnMacOS14(_ intent: some AppIntent, actionName: ConfirmationActionName, dialog: IntentDialog) async throws {
    try await intent.requestConfirmation(result: .result(dialog: dialog), confirmationActionName: actionName, showPrompt: true)
}

extension QuitGroupIntent: MacOS14Confirming {
    @available(*, deprecated, message: "macOS 14 only: use requestConfirmation(actionName:dialog:)")
    func requestConfirmationOnMacOS14(actionName: ConfirmationActionName, dialog: IntentDialog) async throws {
        try await confirmOnMacOS14(self, actionName: actionName, dialog: dialog)
    }
}

extension StartGroupIntent: MacOS14Confirming {
    @available(*, deprecated, message: "macOS 14 only: use requestConfirmation(actionName:dialog:)")
    func requestConfirmationOnMacOS14(actionName: ConfirmationActionName, dialog: IntentDialog) async throws {
        try await confirmOnMacOS14(self, actionName: actionName, dialog: dialog)
    }
}

extension FinishGroupIntent: MacOS14Confirming {
    @available(*, deprecated, message: "macOS 14 only: use requestConfirmation(actionName:dialog:)")
    func requestConfirmationOnMacOS14(actionName: ConfirmationActionName, dialog: IntentDialog) async throws {
        try await confirmOnMacOS14(self, actionName: actionName, dialog: dialog)
    }
}
