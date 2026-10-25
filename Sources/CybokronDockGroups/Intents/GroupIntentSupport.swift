import AppIntents
import DockGroupsCore
import OSLog

/// What Siri, Spotlight and the Shortcuts app can ask the running app to do with a group.
@MainActor
protocol GroupIntentHandling: AnyObject {
    var groups: [DockGroup] { get }
    /// The archived groups: only so saved shortcuts and Focus filters naming one show its name, and
    /// running them says it's archived. Nothing is done with them.
    var archivedGroups: [ArchivedGroup] { get }
    /// Shows the group's popup, centered over the Dock.
    func showPopup(forGroup id: DockGroup.ID)
    /// Open All, without alerts: the result goes back to the caller.
    func launchAll(_ group: DockGroup) async -> LaunchReport
    /// Close All, without the app's alerts: `confirm` asks in Siri or Shortcuts first, and throws
    /// when the user declines; the apps quit only once it returns.
    func quitAll(_ group: DockGroup, mode: QuitMode, confirm: (QuitConfirmation) async throws -> Void) async throws -> QuitReport
    /// Start (`ContextSwitcher`, triggered by Siri or Shortcuts), without the app's alerts:
    /// `confirm` asks there first when it would quit apps, and throws when the user declines —
    /// then nothing is done.
    func start(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport
    /// Finish, as `start`.
    func finish(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport
    /// New Group from Open Apps, without a sheet (capture spec §2.7): the open apps that would start
    /// selected, never the Shortcuts app, in a new group named `name` (the suggestion when blank or
    /// `nil`). `onlyAppsWithWindows`: the window option, the remembered one when `nil`. Nothing is
    /// opened, hidden or quit.
    func captureNewGroup(named name: String?, onlyAppsWithWindows: Bool?) -> CaptureOutcome
    /// Add Open Apps to Group, without a sheet: as `captureNewGroup`, adding the apps `group`
    /// doesn't have yet.
    func captureOpenApps(into group: DockGroup, onlyAppsWithWindows: Bool?) -> CaptureOutcome
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

    /// The active and the archived groups, for looking groups up by identifier; read from disk if the
    /// app delegate isn't set up yet.
    static var storedGroups: StoredGroups {
        if let handler {
            return StoredGroups(active: handler.groups, archived: handler.archivedGroups)
        }
        return (try? JSONFileGroupPersistence().loadStoredGroups()) ?? StoredGroups()
    }

    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Intents")

    /// The handler and the group behind `entity`, as it is now. `action` names the intent in the log.
    static func resolve(_ entity: GroupEntity, for action: String) throws -> (GroupIntentHandling, DockGroup) {
        let handler = try readyHandler(for: action)
        guard let group = handler.groups.first(where: { $0.id == entity.id }) else {
            if let archived = handler.archivedGroups.first(where: { $0.id == entity.id }) {
                logger.error("\(action, privacy: .public): group \(entity.id, privacy: .public) is archived")
                throw GroupIntentError.groupArchived(name: archived.group.name)
            }
            logger.error("\(action, privacy: .public): no group \(entity.id, privacy: .public)")
            throw GroupIntentError.groupNotFound(name: entity.name)
        }
        logger.notice("\(action, privacy: .public) for group \(group.id, privacy: .public)")
        return (handler, group)
    }

    /// The handler, for an intent that names no group; throws `notReady` until the app delegate is
    /// set up. `action` names the intent in the log.
    static func readyHandler(for action: String) throws -> GroupIntentHandling {
        guard let handler else {
            logger.error("\(action, privacy: .public): the app isn't ready")
            throw GroupIntentError.notReady
        }
        return handler
    }
}

enum GroupIntentError: Error, CustomLocalizedStringResourceConvertible {
    case groupNotFound(name: String)
    /// The group is archived (spec §2.11): nothing is done until it's restored.
    case groupArchived(name: String)
    case notReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .groupNotFound(let name):
            return "There's no group named “\(name)”. It may have been renamed or deleted."
        case .groupArchived(let name):
            return "“\(name)” is archived. Restore it in Cybokron Dock Groups to use it."
        case .notReady:
            return "Cybokron Dock Groups is still starting. Try again in a moment."
        }
    }
}
