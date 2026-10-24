import AppIntents
import DockGroupsCore

/// Open All for a group.
struct LaunchGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Group"
    static let description = IntentDescription(
        "Opens every app in the group. Apps that are already running come to the front.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Launch \(\.$group)")
    }

    init() {}

    init(group: GroupEntity) {
        self.group = group
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (handler, group) = try GroupIntentSupport.resolve(group, for: "Launch Group")
        let report = await handler.launchAll(group)
        return .result(dialog: "\(report.summary)")
    }
}

/// Close All for a group: asks its running apps to quit, or force quits them — after asking the
/// user, in Siri or Shortcuts, whether to.
struct QuitGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Group"
    static let description = IntentDescription(
        "Quits every running app in the group once you confirm. Apps can still ask to save changes, unless you force quit.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    @Parameter(
        title: "Force Quit",
        description: "Ends the apps right away, without asking to save changes.",
        default: false
    )
    var forceQuit: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Quit \(\.$group)") {
            \.$forceQuit
        }
    }

    init() {}

    init(group: GroupEntity, forceQuit: Bool = false) {
        self.group = group
        self.forceQuit = forceQuit
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Resolved first: nothing is asked about a group that doesn't exist (any more).
        let (handler, group) = try GroupIntentSupport.resolve(group, for: "Quit Group")
        let report = try await handler.quitAll(group, mode: forceQuit ? .force : .graceful, confirm: confirmQuitting)
        return .result(dialog: "\(report.summary)")
    }

    /// Asks in Siri or Shortcuts whether to quit the group's apps, every time — force quitting
    /// included, which the question then warns of. Its buttons are the app's alert's: Quit Apps
    /// (Force Quit Apps, shown as destructive) and Cancel (`IntentConfirming`).
    @MainActor
    private func confirmQuitting(_ confirmation: QuitConfirmation) async throws {
        try await askFirst(
            dialog: confirmation.intentDialog,
            acceptLabel: confirmation.confirmButton,
            denyLabel: confirmation.cancelButton,
            destructive: confirmation.mode == .force
        )
    }
}

extension QuitGroupIntent: IntentConfirming {}

/// Shows a group's popup, centered over the Dock.
struct ShowGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Group"
    static let description = IntentDescription(
        "Shows the group's popup over the Dock, with its apps ready to open.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$group)")
    }

    init() {}

    init(group: GroupEntity) {
        self.group = group
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (handler, group) = try GroupIntentSupport.resolve(group, for: "Show Group")
        handler.showPopup(forGroup: group.id)
        return .result()
    }
}
