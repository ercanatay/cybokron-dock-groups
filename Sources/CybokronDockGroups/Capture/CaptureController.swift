import AppKit
import DockGroupsCore
import OSLog

/// A capture the group window is asked to show: where the apps go, and the open apps as they were
/// read when the user asked (`CaptureController.snapshot()`).
struct CaptureRequest: Identifiable, Equatable {
    let id = UUID()
    let target: CaptureTarget
    let snapshot: OpenAppsSnapshot
}

/// Capturing the open apps in the main app (capture spec §2.3, §2.6): remembers the order apps came
/// to the front, reads the open apps when the user asks, plans what the sheet lists, keeps the
/// sheet's two settings, and adds what the user chose.
///
/// Everything it reads needs no permission: `NSWorkspace`'s running apps and activation
/// notifications, and the window list's owner, layer, bounds, alpha and on-screen fields
/// (`SystemOpenAppsReader`). It never opens, hides or quits anything. Standalone groups' own apps
/// don't capture: only the main app runs this.
@MainActor
final class CaptureController {
    private let store: GroupStore
    private let preferences: PreferencesStore
    private let reader: OpenAppsReading
    private let workspace: NSWorkspace
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    /// The order apps came to the front since this app started; never saved.
    private(set) var history = ActivationHistory()
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Capture")

    init(
        store: GroupStore,
        preferences: PreferencesStore,
        reader: OpenAppsReading? = nil,
        workspace: NSWorkspace = .shared
    ) {
        self.store = store
        self.preferences = preferences
        self.reader = reader ?? SystemOpenAppsReader(workspace: workspace)
        self.workspace = workspace
    }

    /// Starts remembering activations, beginning with the app in front now.
    func start() {
        guard observer == nil else { return }
        if let front = workspace.frontmostApplication {
            record(front)
        }
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.record(application) }
        }
    }

    /// Regular apps only, and never this app: so "most recently used" from the group window is the
    /// app the user was in before it.
    private func record(_ application: NSRunningApplication) {
        guard application.processIdentifier != ownProcessIdentifier,
              application.activationPolicy == .regular,
              let identity = RunningAppSnapshot.identity(bundleIdentifier: application.bundleIdentifier, bundleURL: application.bundleURL)
        else { return }
        history.recordActivation(ofIdentity: identity)
    }

    /// The open apps now. Called in the action that asks for capture, before the group window
    /// brings the app to the front, so the app the user was in is still the front one.
    func snapshot() -> OpenAppsSnapshot {
        reader.snapshot(history: history)
    }

    // MARK: - The sheet

    /// The sheet's order and window option, as last chosen (`preferences.json`, `"capture"`).
    var settings: CaptureSettings {
        get { preferences.preferences.capture }
        set { preferences.update { $0.capture = newValue } }
    }

    /// What the sheet lists for `request` with `settings`: the target group's items are shown as
    /// such, the protected apps start unselected.
    func plan(for request: CaptureRequest, settings: CaptureSettings) -> CapturePlan {
        let targetItems: [GroupItem]
        if case .group(let id) = request.target {
            targetItems = store.group(withID: id)?.apps ?? []
        } else {
            targetItems = []
        }
        return CapturePlanner.plan(
            request.snapshot,
            settings: settings,
            target: request.target,
            targetItems: targetItems,
            protectedApps: preferences.preferences.protectedApps
        )
    }

    /// The name offered for a new group of `items`, unique among the active and archived groups.
    func suggestedName(for items: [GroupItem]) -> String {
        CapturePlanner.suggestedName(for: items, taken: store.takenNames)
    }

    /// The name of the group apps are added to; `nil` when it isn't an active group (any more).
    func groupName(of target: CaptureTarget) -> String? {
        guard case .group(let id) = target else { return nil }
        return store.group(withID: id)?.name
    }

    /// Adds what the user chose (`GroupStore.capture`): a new group named as typed — the
    /// suggestion when the name is blank — or the apps the group doesn't have yet. Logs counts and
    /// group identifiers only.
    func commit(_ items: [GroupItem], into target: CaptureTarget, typedName: String) -> CaptureResult {
        let name = CapturePlanner.groupName(typed: typedName, items: items, taken: store.takenNames)
        let result = store.capture(items, into: target, named: name)
        switch result {
        case .created(let group):
            logger.notice("Captured \(group.apps.count) apps into a new group \(group.id, privacy: .public)")
        case .added(let count, let id):
            logger.notice("Captured \(count) apps into group \(id, privacy: .public)")
        case .unavailableGroup:
            logger.notice("Capture: the group was archived or deleted meanwhile; nothing was added")
        }
        return result
    }
}
