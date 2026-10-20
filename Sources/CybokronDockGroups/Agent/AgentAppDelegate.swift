import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Runs the app as a standalone group's agent: the small app with the group's own Dock icon.
///
/// Started from its Dock tile, the agent shows the group's popup over the Dock — above the tile when
/// the group's position is "above the clicked icon" (`DockTileLocator`); clicking the tile again
/// hides it, and clicking it with ⌥ held opens all of the group's apps right away. The popup opens
/// apps, Open All, Hide All and Close All as in the main app, but doesn't change the group:
/// reordering and removing apps happen in the main app. Restoring a running app's minimized windows
/// needs Accessibility access for the agent itself; it never asks for it.
///
/// Right-clicking (or Control-clicking) the tile shows the group's apps — checked while running —
/// with Open All, Hide All and Close All (`applicationDockMenu(_:)`). The Dock asks only apps it
/// shows as running for such a menu, so while `PopupPreferences.showsStandaloneDockMenus` is on the
/// agent runs as a regular app: a running indicator under its tile, an entry in the app switcher
/// and, while the popup is open, a menu bar with Hide and Quit. With it off, the agent stays out of
/// both, like the `LSUIElement` app its bundle declares, and the Dock shows only its own items.
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
    private let runningApps = RunningAppsMonitor()
    /// Read before the app finishes launching, so the activation policy is in place first.
    private var launchConfiguration: Result<AgentConfiguration, Error>?
    private var store: GroupStore?
    private var preferences: PreferencesStore?
    private var popupController: PopupPanelController?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Agent")

    init(groupID: DockGroup.ID) {
        self.groupID = groupID
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let configuration = Result { try loadConfiguration() }
        launchConfiguration = configuration
        if case .success(let configuration) = configuration {
            applyDockPresence(for: configuration)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration: AgentConfiguration
        do {
            configuration = try (launchConfiguration ?? Result { try loadConfiguration() }).get()
            launchConfiguration = nil
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
        popupController.show(groupID: groupID, source: tileSource(for: group))
    }

    /// The tile the popup opens above, looked up only when the group's position asks for it.
    private func tileSource(for group: DockGroup) -> PopupSource {
        guard preferences?.preferences.resolved(with: group.popup).anchor == .dockIcon else { return .unspecified }
        return DockTileLocator.source(forTileOf: bundleURL)
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
            runningApps: runningApps,
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

    /// Delivered on the main thread, where the observer was added. Any process can post the
    /// notification, so a new bundle path is followed only when it's an agent bundle in the agents
    /// folder with this agent's own bundle identifier (`AgentNotification.acceptedBundleURL`);
    /// otherwise the notification is ignored.
    @objc private func configurationChanged(_ notification: Notification) {
        if let value = notification.userInfo?[AgentNotification.bundlePathKey] {
            guard let path = value as? String,
                  let ownIdentifier = Bundle.main.bundleIdentifier,
                  let accepted = AgentNotification.acceptedBundleURL(fromPath: path, bundleIdentifier: ownIdentifier)
            else {
                logger.error("Agent \(self.groupID, privacy: .public) ignored a configuration change naming another bundle: \(String(describing: value), privacy: .public)")
                return
            }
            bundleURL = accepted
        }
        do {
            let configuration = try loadConfiguration()
            store?.updateGroup(groupID) { $0 = configuration.group }
            preferences?.update { $0 = configuration.preferences }
            applyDockPresence(for: configuration)
            logger.notice("Agent \(self.groupID, privacy: .public) reloaded its configuration")
        } catch {
            logger.error("Agent \(self.groupID, privacy: .public): reloading the configuration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Dock menu

    /// Runs the agent as a regular app while its Dock menu is on — the Dock asks only apps it shows
    /// as running for a menu — and as an agent app without a Dock presence otherwise. The menu bar
    /// it then gets (shown only while the agent is active, that is while its popup is open) has just
    /// Hide and Quit, named after the group.
    private func applyDockPresence(for configuration: AgentConfiguration) {
        let showsDockMenu = configuration.preferences.showsStandaloneDockMenus
        NSApp.mainMenu = showsDockMenu ? MainMenuBuilder.makeAgentMenu(groupName: configuration.group.name) : nil
        let policy: NSApplication.ActivationPolicy = showsDockMenu ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        if !NSApp.setActivationPolicy(policy) {
            logger.error("Agent \(self.groupID, privacy: .public) couldn't switch to activation policy \(policy.rawValue)")
        }
    }

    /// The tile's menu, asked for on every right-click or Control-click. The Dock draws it itself,
    /// without item images, so the apps are listed by name, checked while they run; it adds its
    /// own items (Options, Show All Windows, Hide, Quit) below.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard preferences?.preferences.showsStandaloneDockMenus == true,
              let group = store?.group(withID: groupID)
        else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if group.apps.isEmpty {
            let placeholder = NSMenuItem(title: L10n.Common.noAppsInGroup, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        for app in group.apps {
            let item = NSMenuItem(title: app.name, action: #selector(openAppFromDockMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            let isRunning = runningApps.isRunning(app)
            item.state = isRunning ? .on : .off
            item.isEnabled = isRunning || icons.isInstalled(app)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hasRunningApps = runningApps.runningCount(in: group) > 0
        menu.addItem(dockMenuItem(L10n.Common.openAll, action: #selector(openAllFromDockMenu(_:)), isEnabled: !group.apps.isEmpty))
        menu.addItem(dockMenuItem(L10n.Common.hideAll, action: #selector(hideAllFromDockMenu(_:)), isEnabled: hasRunningApps))
        menu.addItem(dockMenuItem(L10n.Common.closeAll, action: #selector(closeAllFromDockMenu(_:)), isEnabled: hasRunningApps))
        return menu
    }

    private func dockMenuItem(_ title: String, action: Selector, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        return item
    }

    /// Opens the app, or brings it to the front when it's running.
    @objc private func openAppFromDockMenu(_ sender: NSMenuItem) {
        guard let group = store?.group(withID: groupID),
              let identifier = (sender.representedObject as? String)?.lowercased(),
              let app = group.apps.first(where: { $0.normalizedBundleIdentifier == identifier })
        else { return }
        popupController?.close(reason: .appAction)
        open(app, in: group)
    }

    @objc private func openAllFromDockMenu(_ sender: NSMenuItem) {
        guard let group = store?.group(withID: groupID) else { return }
        popupController?.close(reason: .appAction)
        openAll(group)
    }

    @objc private func hideAllFromDockMenu(_ sender: NSMenuItem) {
        guard let group = store?.group(withID: groupID) else { return }
        popupController?.close(reason: .appAction)
        hideAll(group)
    }

    @objc private func closeAllFromDockMenu(_ sender: NSMenuItem) {
        guard let group = store?.group(withID: groupID) else { return }
        popupController?.close(reason: .appAction)
        closeAll(group, mode: .graceful)
    }

    // MARK: - Actions

    private func open(_ app: AppReference, in group: DockGroup) {
        let restoresWindows = preferences?.preferences.restoresWindowsOfRunningApps ?? PopupPreferences().restoresWindowsOfRunningApps
        Task { @MainActor in
            LaunchReportPresenter.presentProblems(in: await launcher.open(app, inGroup: group, restoringWindows: restoresWindows))
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
        alert.messageText = L10n.Agent.damagedTitle
        alert.informativeText = L10n.Agent.damagedMessage(error.localizedDescription, appName: AppInfo.name)
        NSApp.activate()
        alert.runModal()
    }
}

enum AgentLaunchError: LocalizedError {
    case groupMismatch

    var errorDescription: String? {
        L10n.Agent.groupMismatch
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
