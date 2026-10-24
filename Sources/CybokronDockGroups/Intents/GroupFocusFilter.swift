import AppIntents
import DockGroupsCore
import OSLog

/// What a Focus filter does with its group when its Focus turns on (`FocusGroupAction`): only Start,
/// Open All or Show Popup — a Focus never quits apps. The raw values are what macOS keeps in its
/// Focus settings: never change them.
enum FocusFilterAction: String, AppEnum {
    case start
    case openAll
    case showPopup

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [FocusFilterAction: DisplayRepresentation] = [
        .start: "Start",
        .openAll: "Open All",
        .showPopup: "Show Popup",
    ]

    var groupAction: FocusGroupAction { FocusGroupAction(rawValue: rawValue) ?? .start }
}

/// The app's Focus filter (spec §2.10, §3.6): in System Settings → Focus → a Focus → Focus Filters →
/// Add Filter, it names a group, what happens when the Focus turns on, and whether the group is
/// finished — by hiding its apps — when the Focus turns off (off by default, DECISION 3). macOS
/// keeps these values with the Focus; the app stores none of them.
///
/// macOS calls `perform()` while the app runs: with these values when the Focus turns on, with the
/// defaults (no group) when it turns off. Without an App Intents extension it doesn't launch the app
/// for it (docs/design/focus-spike.md, D-A1). The calls go to `FocusRequestCoordinator`, which
/// settles them and starts, opens or shows the group with trigger `.focus`: nothing is ever quit.
/// Only the main app declares it — standalone groups' apps have no App Intents metadata.
struct GroupFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Start a Group"
    static let description: IntentDescription? = IntentDescription(
        "Starts, opens or shows a group of Cybokron Dock Groups when this Focus turns on. A Focus never quits apps."
    )

    @Parameter(title: "Group")
    var group: GroupEntity?

    @Parameter(title: "When This Focus Turns On", default: .start)
    var action: FocusFilterAction

    @Parameter(title: "Finish the Group When This Focus Turns Off", default: false)
    var finishesWhenFocusEnds: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let group else {
            return DisplayRepresentation(title: "No group", subtitle: "Choose the group this Focus starts")
        }
        let title: LocalizedStringResource
        switch action {
        case .start: title = "Start “\(group.name)”"
        case .openAll: title = "Open All in “\(group.name)”"
        case .showPopup: title = "Show “\(group.name)”"
        }
        let finishes = action == .start && finishesWhenFocusEnds
        return DisplayRepresentation(title: title, subtitle: finishes ? "Finishes it when the Focus turns off" : nil)
    }

    /// What this filter asks for, as the coordinator takes it.
    var request: FocusRequest {
        FocusRequest(groupID: group?.id, action: action.groupAction, finishesWhenFocusEnds: finishesWhenFocusEnds)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusFilterBridge.receive(request)
        return .result()
    }
}

/// Connects the Focus filter, which the system creates on its own, to the app: its calls go to one
/// `FocusRequestCoordinator`, whose handler the app delegate sets once the groups are loaded (calls
/// before that wait there).
@MainActor
enum FocusFilterBridge {
    static let coordinator = FocusRequestCoordinator()
    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Focus")

    static func receive(_ request: FocusRequest) {
        // The group by identifier only; the action is the app's, not the user's data.
        logger.notice("Focus filter: group \(request.groupID?.uuidString ?? "none", privacy: .public), \(request.action.rawValue, privacy: .public), finishes when it ends: \(request.finishesWhenFocusEnds)")
        coordinator.receive(request)
    }

    /// What the current Focus's filter asks for (`SetFocusFilterIntent.current`), for Settings;
    /// `nil` when no Focus with the filter is on or it can't be read.
    static func currentRequest() async -> FocusRequest? {
        do {
            return try await GroupFocusFilter.current.request
        } catch {
            logger.debug("No current Focus filter: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
