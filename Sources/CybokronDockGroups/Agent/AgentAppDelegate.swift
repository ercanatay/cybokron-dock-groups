import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Runs the app as a standalone group's agent: the small app with the group's own Dock icon.
///
/// Started from its Dock tile, the agent shows the group's popup over the Dock; clicking the tile
/// again hides it, and clicking it with ⌥ held opens all of the group's apps right away. The popup
/// opens apps, Open All, Hide All and Close All as in the main app, but doesn't change the group:
/// reordering and removing apps happen in the main app.
///
/// The group comes from the bundle's `group-config.json` only, so the agent works while the main
/// app isn't running; the main app rewrites the file when the group changes and tells the agent
/// with `AgentNotification.configurationChanged`. Agents have no menu bar item, global shortcuts,
/// App Intents, launch statistics or links: those belong to the main app.
@MainActor
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    /// A click on the Dock tile closes an open popup as an outside click before the reopen request
    /// of the same click arrives; a reopen this soon after such a close doesn't show it again.
    private static let reopenAfterCloseGrace: TimeInterval = 0.6

    private let groupID: DockGroup.ID
    private var bundleURL = Bundle.main.bundleURL
    private let launcher = GroupLauncher()
    private let terminator = GroupTerminator()
    private let icons = WorkspaceAppIconProvider()
    private var store: GroupStore?
    private var preferences: PreferencesStore?
    private var popupController: PopupPanelController?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Agent")

    init(groupID: DockGroup.ID) {
        self.groupID = groupID
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration: AgentConfiguration
        do {
            configuration = try loadConfiguration()
        } catch {
            logger.error("Agent \(self.groupID, privacy: .public) can't start: \(String(describing: error), privacy: .public)")
            presentDamagedBundleAlert(error)
            NSApp.terminate(nil)
            return
        }
        logger.notice("Agent started for group \(self.groupID, privacy: .public)")
        setUp(with: configuration)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(configurationChanged(_:)),
            name: AgentNotification.configurationChanged,
            object: groupID.uuidString,
            suspensionBehavior: .deliverImmediately
        )
        respondToTileClick()
    }

    /// A click on the Dock tile while the agent runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        respondToTileClick()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Tile clicks

    private func respondToTileClick() {
        guard let popupController, let group = store?.group(withID: groupID) else {
            NSSound.beep()
            return
        }
        if NSEvent.modifierFlags.contains(.option) {
            popupController.close(reason: .appAction)
            openAll(group)
            return
        }
        if popupController.isShown {
            popupController.close(reason: .toggled)
            return
        }
        if let last = popupController.lastClose,
           [.outsideClick, .lostFocus].contains(last.reason),
           Date().timeIntervalSince(last.date) < Self.reopenAfterCloseGrace {
            logger.debug("The tile click closed the popup")
            return
        }
        if NSApp.isHidden {
            // Hidden when the popup closed last; a hidden app's windows stay off screen.
            NSApp.unhideWithoutActivation()
        }
        popupController.show(groupID: groupID)
    }

    // MARK: - Configuration

    private var configurationURL: URL {
        AgentBundleLayout(bundleURL: bundleURL).configurationURL
    }

    private func loadConfiguration() throws -> AgentConfiguration {
        let configuration = try AgentConfiguration.load(from: configurationURL)
        guard configuration.group.id == groupID else {
            throw AgentLaunchError.groupMismatch
        }
        return configuration
    }

    private func setUp(with configuration: AgentConfiguration) {
        let store = GroupStore(persistence: FixedGroupPersistence(groups: [configuration.group]), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: FixedPreferencesPersistence(preferences: configuration.preferences), saveDelay: .zero)
        let tiles = TileImageCache(iconProvider: icons)
        let popupController = PopupPanelController(
            store: store,
            preferences: preferences,
            tiles: tiles,
            icons: icons,
            runningApps: RunningAppsMonitor(),
            mostUsed: nil,
            allowsEditing: false,
            actions: PopupPanelController.Actions(
                open: { [weak self] app, group in self?.open(app, in: group) },
                openAll: { [weak self] group in self?.openAll(group) },
                closeAll: { [weak self] group, mode in self?.closeAll(group, mode: mode) },
                hideAll: { [weak self] group in self?.hideAll(group) },
                manageGroups: { [weak self] in self?.openMainApp() }
            )
        )
        popupController.onClose = { reason in
            // The agent was brought forward by the tile click; give the focus back to the app the
            // user was in. Clicks elsewhere and opened apps move the focus on their own.
            if [.escape, .toggled, .requested, .groupDeleted].contains(reason), NSApp.isActive {
                NSApp.hide(nil)
            }
        }
        self.store = store
        self.preferences = preferences
        self.popupController = popupController
    }

    /// Delivered on the main thread, where the observer was added.
    @objc private func configurationChanged(_ notification: Notification) {
        if let path = notification.userInfo?[AgentNotification.bundlePathKey] as? String {
            bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        do {
            let configuration = try loadConfiguration()
            store?.updateGroup(groupID) { $0 = configuration.group }
            preferences?.update { $0 = configuration.preferences }
            logger.notice("Agent \(self.groupID, privacy: .public) reloaded its configuration")
        } catch {
            logger.error("Agent \(self.groupID, privacy: .public): reloading the configuration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    private func open(_ app: AppReference, in group: DockGroup) {
        Task { @MainActor in
            LaunchReportPresenter.presentProblems(in: await launcher.open(app, inGroup: group))
        }
    }

    private func openAll(_ group: DockGroup) {
        Task { @MainActor in
            LaunchReportPresenter.presentProblems(in: await launcher.openAll(group))
        }
    }

    private func closeAll(_ group: DockGroup, mode: QuitMode) {
        LaunchReportPresenter.presentProblems(in: terminator.closeAll(group, mode: mode))
    }

    private func hideAll(_ group: DockGroup) {
        LaunchReportPresenter.presentProblems(in: terminator.hideAll(group))
    }

    /// Groups are edited in the main app: open its group window.
    private func openMainApp() {
        guard let url = URL(string: "cybokrondockgroups://groups") else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentDamagedBundleAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This group's app can't open its group."
        alert.informativeText = "\(error.localizedDescription)\n\nIn Cybokron Dock Groups, turn Standalone off and on again for the group to rebuild its app."
        NSApp.activate()
        alert.runModal()
    }
}

enum AgentLaunchError: LocalizedError {
    case groupMismatch

    var errorDescription: String? {
        "The app's settings belong to another group."
    }
}

/// The agent's one group, kept in memory: the main app owns the saved group list.
private struct FixedGroupPersistence: GroupPersisting {
    let groups: [DockGroup]

    func loadGroups() throws -> [DockGroup] { groups }
    func saveGroups(_ groups: [DockGroup]) throws {}
    func preserveUnreadableData() throws -> URL? { nil }
}

/// The preferences snapshot from the agent's configuration, kept in memory.
private struct FixedPreferencesPersistence: PreferencesPersisting {
    let preferences: PopupPreferences

    func loadPreferences() throws -> PopupPreferences? { preferences }
    func savePreferences(_ preferences: PopupPreferences) throws {}
    func preserveUnreadableData() throws -> URL? { nil }
}
