import AppIntents
import DockGroupsCore

/// New Group from Open Apps, without the sheet (capture spec §1.10, §2.7): makes a group of the
/// open apps that would start selected in it — never the Shortcuts app, protected apps or (with the
/// window option) apps without an open window — and returns it, so a shortcut can go on with Launch
/// Group. Nothing is opened, hidden or quit, so nothing is asked first.
struct CaptureOpenAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "New Group from Open Apps"
    static let description = IntentDescription(
        "Makes a group of the apps that are open now, up to 50, named after them unless you give a name. Protected apps and the Shortcuts app are left out. Nothing is opened or quit.",
        categoryName: "Groups"
    )

    @Parameter(title: "Name", description: "The new group's name. When empty, it's named after its apps, such as “Xcode +3”.")
    var name: String?

    @Parameter(
        title: "Only Apps with Open Windows",
        description: "Leaves out the apps that seem to have no open window. When not set, the choice last made in the capture sheet."
    )
    var onlyAppsWithWindows: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("New group from open apps named \(\.$name)") {
            \.$onlyAppsWithWindows
        }
    }

    init() {}

    init(name: String? = nil, onlyAppsWithWindows: Bool? = nil) {
        self.name = name
        self.onlyAppsWithWindows = onlyAppsWithWindows
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GroupEntity?> & ProvidesDialog {
        let handler = try GroupIntentSupport.readyHandler(for: "New Group from Open Apps")
        let outcome = handler.captureNewGroup(named: name, onlyAppsWithWindows: onlyAppsWithWindows)
        return .result(value: outcome.createdGroup.map(GroupEntity.init(group:)), dialog: "\(outcome.summary)")
    }
}

/// Add Open Apps to Group, without the sheet: adds the open apps the group doesn't have yet and
/// that would start selected in the sheet, after its items. An archived group gives the usual
/// error and is left as it is. Nothing is opened, hidden or quit.
struct AddOpenAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Open Apps to Group"
    static let description = IntentDescription(
        "Adds the apps that are open now to the group, after its items, up to 50. Protected apps, the Shortcuts app and the apps it has already are left out. Nothing is opened or quit.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    @Parameter(
        title: "Only Apps with Open Windows",
        description: "Leaves out the apps that seem to have no open window. When not set, the choice last made in the capture sheet."
    )
    var onlyAppsWithWindows: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Add open apps to \(\.$group)") {
            \.$onlyAppsWithWindows
        }
    }

    init() {}

    init(group: GroupEntity, onlyAppsWithWindows: Bool? = nil) {
        self.group = group
        self.onlyAppsWithWindows = onlyAppsWithWindows
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Resolved first: an archived or deleted group gives its error, and nothing is read.
        let (handler, resolved) = try GroupIntentSupport.resolve(group, for: "Add Open Apps to Group")
        let outcome = handler.captureOpenApps(into: resolved, onlyAppsWithWindows: onlyAppsWithWindows)
        if outcome == .unavailableGroup {
            // Archived or deleted in between: the same error as when it was before.
            _ = try GroupIntentSupport.resolve(group, for: "Add Open Apps to Group")
        }
        return .result(dialog: "\(outcome.summary)")
    }
}
