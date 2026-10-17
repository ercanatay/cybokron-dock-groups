import AppIntents
import DockGroupsCore
import OSLog

/// What Siri, Spotlight and the Shortcuts app can ask the running app to do with a group.
@MainActor
protocol GroupIntentHandling: AnyObject {
    var groups: [DockGroup] { get }
    /// Shows the group's popup, centered over the Dock.
    func showPopup(forGroup id: DockGroup.ID)
    /// Open All, without alerts: the result goes back to the caller.
    func launchAll(_ group: DockGroup) async -> LaunchReport
    /// Close All, without alerts.
    func quitAll(_ group: DockGroup, mode: QuitMode) -> QuitReport
}

/// Connects the intents, which the system creates on its own, to the app's objects.
@MainActor
enum GroupIntentSupport {
    /// Set by the app delegate when the app starts.
    static weak var handler: GroupIntentHandling?

    /// The current groups; read from disk if the app delegate isn't set up yet.
    static var groups: [DockGroup] {
        if let handler {
            return handler.groups
        }
        return (try? JSONFileGroupPersistence().loadGroups()) ?? []
    }

    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Intents")

    /// The handler and the group behind `entity`, as it is now. `action` names the intent in the log.
    static func resolve(_ entity: GroupEntity, for action: String) throws -> (GroupIntentHandling, DockGroup) {
        guard let handler else {
            logger.error("\(action, privacy: .public): the app isn't ready")
            throw GroupIntentError.notReady
        }
        guard let group = handler.groups.first(where: { $0.id == entity.id }) else {
            logger.error("\(action, privacy: .public): no group \(entity.id, privacy: .public)")
            throw GroupIntentError.groupNotFound(name: entity.name)
        }
        logger.notice("\(action, privacy: .public) for group \(group.id, privacy: .public)")
        return (handler, group)
    }
}

enum GroupIntentError: Error, CustomLocalizedStringResourceConvertible {
    case groupNotFound(name: String)
    case notReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .groupNotFound(let name):
            return "There's no group named “\(name)”. It may have been renamed or deleted."
        case .notReady:
            return "Cybokron Dock Groups is still starting. Try again in a moment."
        }
    }
}
