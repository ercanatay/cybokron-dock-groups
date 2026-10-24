import AppIntents
import DockGroupsCore

/// Start for a group (spec §2.7): opens its items as Open All does and puts the group started
/// before it away, as the group's settings say. When that would quit apps it asks first, in Siri
/// or Shortcuts; declining does nothing at all. Nothing is ever force quit.
struct StartGroupIntent: AppIntent, IntentConfirming {
    static let title: LocalizedStringResource = "Start Group"
    static let description = IntentDescription(
        "Opens the group's items and puts the group started before it away, as the group's settings say: by default its apps are hidden. Asks first when that would quit apps.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$group)")
    }

    init() {}

    init(group: GroupEntity) {
        self.group = group
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Resolved first: nothing is asked about a group that doesn't exist (any more).
        let (handler, group) = try GroupIntentSupport.resolve(group, for: "Start Group")
        let report = try await handler.start(group) { confirmation in
            try await askFirst(confirmation)
        }
        return .result(dialog: "\(report.summary)")
    }
}

/// Finish for a group: hides (or quits, or leaves) its running apps as its settings say and, when
/// it's the current group, shows the group started before it again. Asks first when that would
/// quit apps; never launches or force quits anything.
struct FinishGroupIntent: AppIntent, IntentConfirming {
    static let title: LocalizedStringResource = "Finish Group"
    static let description = IntentDescription(
        "Puts the group's apps away, as the group's settings say: by default they're hidden, and the group started before it is shown again. Asks first when that would quit apps.",
        categoryName: "Groups"
    )

    @Parameter(title: "Group", requestValueDialog: "Which group?")
    var group: GroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Finish \(\.$group)")
    }

    init() {}

    init(group: GroupEntity) {
        self.group = group
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (handler, group) = try GroupIntentSupport.resolve(group, for: "Finish Group")
        let report = try await handler.finish(group) { confirmation in
            try await askFirst(confirmation)
        }
        return .result(dialog: "\(report.summary)")
    }
}
