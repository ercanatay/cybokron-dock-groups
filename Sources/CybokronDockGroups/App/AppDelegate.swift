import AppIntents
import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Owns the app's long-lived objects. The app is a menu bar utility (`LSUIElement`): it has no Dock
/// icon, and its windows open from the menu bar or when the app is opened again while running.
/// Group popups also open from the global shortcuts, Siri and Shortcuts, and `cybokrondockgroups:`
/// URLs. App launches are counted all along for the Most Used list. Standalone groups get their own
/// apps with their own Dock icons (`StandaloneController`); those run with `AgentAppDelegate`.
/// `AutoUpdater` looks for new releases on GitHub (only here, never in an agent). A second copy of
/// the app, launched while one runs, hands its URLs to the running copy and quits (`SecondCopyHandoff`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GroupStore(persistence: JSONFileGroupPersistence())
    private let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence())
    private let launcher = GroupLauncher()
    private let terminator = GroupTerminator()
    private let icons = WorkspaceAppIconProvider()
    private let runningApps = RunningAppsMonitor()
    private lazy var usage: UsageStore = UsageStore(
        persistence: JSONFileUsagePersistence(),
        sessionLength: TimeInterval(preferences.preferences.mostUsedSessionSeconds)
    )
    private lazy var usageMonitor = UsageMonitor(usage: usage)
    private lazy var mostUsed = MostUsedProvider(usage: usage, preferences: preferences, icons: icons)
    private lazy var tiles: TileImageCache = TileImageCache(iconProvider: icons)
    private lazy var standalone = StandaloneController(store: store, preferences: preferences, icons: icons)
    private var statusBarController: StatusBarController?
    private var subscriptions: Set<AnyCancellable> = []
    /// Set while this is a second copy of the app, launched next to the copy that runs: it then
    /// only hands its URLs over to that copy and quits.
    private var secondCopyHandoff: SecondCopyHandoff?
    private var urlThrottle = CommandThrottle()
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "App")
    private let urlLogger = Logger(subsystem: "com.cybokron.dockgroups", category: "URLScheme")

    private lazy var mainWindowController: MainWindowController = {
        let controller = MainWindowController(
            store: store,
            tiles: tiles,
            standalone: standalone,
            actions: MainWindowView.Actions(
                openAll: { [weak self] group in self?.openAll(group) },
                hideAll: { [weak self] group in self?.hideAll(group) },
                showPopup: { [weak self] group in self?.popupController.show(groupID: group.id) }
            )
        )
        // A standalone group's Dock tile may have been dragged out of the Dock meanwhile.
        controller.willShow = { [weak self] in self?.standalone.checkDockTiles() }
        return controller
    }()
    private lazy var settingsWindowController: SettingsWindowController = SettingsWindowController(
        preferences: preferences,
        store: store,
        usage: usage,
        shortcuts: shortcutMonitor,
        updater: updater
    )
    private lazy var aboutWindowController = AboutWindowController()
    private lazy var updater = AutoUpdater(preferences: preferences)
    private lazy var updateWindowController = UpdateWindowController(updater: updater)
    private lazy var shortcutMonitor: GlobalShortcutMonitor = GlobalShortcutMonitor(preferences: preferences) { [weak self] digit in
        self?.togglePopup(forShortcut: digit)
    }
    private lazy var popupController: PopupPanelController = PopupPanelController(
        store: store,
        preferences: preferences,
        tiles: tiles,
        icons: icons,
        runningApps: runningApps,
        mostUsed: mostUsed,
        actions: PopupPanelController.Actions(
            open: { [weak self] app, group in self?.open(app, in: group) },
            openAll: { [weak self] group in self?.openAll(group) },
            closeAll: { [weak self] group, mode in self?.closeAll(group, mode: mode) },
            hideAll: { [weak self] group in self?.hideAll(group) },
            manageGroups: { [weak self] in self?.mainWindowController.show() }
        )
    )

    override init() {
        super.init()
        // Intents may arrive as soon as the app runs; they reach the store through the delegate.
        GroupIntentSupport.handler = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the URLs the app was launched with arrive.
        secondCopyHandoff = SecondCopyHandoff.toOlderRunningCopy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var launchURLs: [URL] = []
        if let handoff = secondCopyHandoff {
            if handoff.isPrimaryRunning {
                handoff.finishLaunching()
                return
            }
            // The other copy quit meanwhile: this one runs as the app.
            launchURLs = handoff.takePendingURLs()
            secondCopyHandoff = nil
        }
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()
        usageMonitor.start()
        preferences.$preferences
            .map(\.mostUsedSessionSeconds)
            .removeDuplicates()
            .sink { [weak self] seconds in self?.usage.sessionLength = TimeInterval(seconds) }
            .store(in: &subscriptions)
        // Changed and deleted groups lose their cached tiles.
        store.$groups
            .sink { [weak self] groups in self?.tiles.synchronize(with: groups) }
            .store(in: &subscriptions)
        // Siri learns the group names from the app's shortcuts; tell it when they change.
        store.$groups
            .map { groups in groups.map { "\($0.id.uuidString) \($0.name)" } }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { _ in DockGroupsShortcuts.updateAppShortcutParameters() }
            .store(in: &subscriptions)
        statusBarController = StatusBarController(
            store: store,
            actions: StatusBarController.Actions(
                showPopup: { [weak self] group in
                    guard let self else { return }
                    self.popupController.toggle(groupID: group.id, source: self.menuBarSource)
                },
                openAll: { [weak self] group in self?.openAll(group) },
                hideAll: { [weak self] group in self?.hideAll(group) },
                showMainWindow: { [weak self] in self?.mainWindowController.show() },
                showSettings: { [weak self] in self?.showSettingsWindow(nil) },
                showAbout: { [weak self] in self?.showAboutWindow(nil) },
                checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
                menuWillOpen: { [weak self] in self?.popupController.close() },
                tileImage: { [weak self] group in
                    self?.tiles.image(for: group, pointSize: StatusBarController.menuTileSize) ?? NSImage()
                },
                shortcutTitle: { [weak self] group in self?.shortcutTitle(for: group) },
                mostUsedEntries: { [weak self] in self?.mostUsed.entries() },
                showMostUsedPopup: { [weak self] in
                    guard let self else { return }
                    self.popupController.toggle(groupID: MostUsedGroup.id, source: self.menuBarSource)
                },
                openMostUsedApp: { [weak self] app in self?.open(app, in: MostUsedGroup.group(with: [])) },
                appIcon: { [weak self] app in self?.menuIcon(for: app) ?? NSImage() }
            )
        )
        shortcutMonitor.start()
        // Removes stranded agents, then keeps the standalone groups' agents up to date.
        standalone.start()
        updater.showWindow = { [weak self] in
            self?.popupController.close()
            self?.updateWindowController.show()
        }
        updater.closeWindow = { [weak self] in self?.updateWindowController.close() }
        updater.start()
        // The window stays closed at launch unless there's a problem the user needs to see.
        if store.issue != nil {
            mainWindowController.show()
        }
        for url in launchURLs {
            handle(url)
        }
    }

    /// Opening the app again (Finder, `open -a`, Spotlight) while it runs shows a popup — the one
    /// shown last, else the first group's — and brings the app forward. Without groups, or when a
    /// popup is already showing, it shows the group window instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard secondCopyHandoff == nil else { return false }
        if popupController.isShown {
            popupController.close()
            mainWindowController.show()
        } else if let group = popupController.lastGroupID.flatMap(popupController.group(withID:)) ?? store.groups.first {
            logger.notice("Reopened: showing the popup of group \(group.id, privacy: .public)")
            NSApp.activate()
            popupController.show(groupID: group.id)
        } else {
            mainWindowController.show()
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let secondCopyHandoff {
            secondCopyHandoff.receive(urls)
            return
        }
        for url in urls {
            handle(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A second copy changed nothing; the copy that runs owns the files.
        guard secondCopyHandoff == nil else { return }
        store.flushPendingSave()
        preferences.flushPendingSave()
        usage.flushPendingSave()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Target of the Settings… menu items (reached through the responder chain).
    @objc func showSettingsWindow(_ sender: Any?) {
        popupController.close()
        settingsWindowController.show()
    }

    /// Target of the About menu items.
    @objc func showAboutWindow(_ sender: Any?) {
        popupController.close()
        aboutWindowController.show()
    }

    /// Target of the Check for Updates… menu items: shows the update window, which follows the check.
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdatesFromMenu()
    }

    /// Popups chosen from the menu bar menu open under its item when their position is "above the
    /// clicked icon".
    private var menuBarSource: PopupSource {
        statusBarController?.itemFrame.map(PopupSource.menuBarItem) ?? .unspecified
    }

    // MARK: - Group actions

    private func open(_ app: AppReference, in group: DockGroup) {
        Task { @MainActor in
            let report = await launcher.open(app, inGroup: group)
            LaunchReportPresenter.presentProblems(in: report)
        }
    }

    private func openAll(_ group: DockGroup) {
        Task { @MainActor in
            LaunchReportPresenter.presentProblems(in: await launchAll(group))
        }
    }

    private func closeAll(_ group: DockGroup, mode: QuitMode) {
        LaunchReportPresenter.presentProblems(in: quitAll(group, mode: mode))
    }

    private func hideAll(_ group: DockGroup) {
        LaunchReportPresenter.presentProblems(in: terminator.hideAll(group))
    }

    // MARK: - Global shortcuts

    /// Shortcut *n* shows or hides the *n*-th group's popup.
    private func togglePopup(forShortcut digit: Int) {
        guard let group = GroupShortcuts.group(forDigit: digit, in: store.groups) else {
            logger.debug("Shortcut \(digit) has no group")
            return
        }
        popupController.toggle(groupID: group.id)
    }

    /// A copy of the app's icon sized for a menu item; the shared icon keeps its size.
    private func menuIcon(for app: AppReference) -> NSImage {
        let icon = (icons.icon(for: app).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: StatusBarController.menuTileSize, height: StatusBarController.menuTileSize)
        return icon
    }

    private func shortcutTitle(for group: DockGroup) -> String? {
        let settings = preferences.preferences
        guard settings.shortcutsEnabled, let digit = GroupShortcuts.digit(forGroup: group.id, in: store.groups) else {
            return nil
        }
        return GroupShortcuts.title(digit: digit, modifiers: settings.shortcutModifiers)
    }

    // MARK: - URL scheme

    private func handle(_ url: URL) {
        guard let command = URLCommand(url: url) else {
            urlLogger.error("Ignored unsupported URL \(url.absoluteString, privacy: .public)")
            return
        }
        guard urlThrottle.accept(command.throttleKey) else {
            urlLogger.notice("Ignored \(url.absoluteString, privacy: .public): repeated within the \(Int(CommandThrottle.urlCooldown))-second cooldown")
            return
        }
        urlLogger.notice("Handling \(url.absoluteString, privacy: .public)")
        // Run once the activation that comes with an opened URL has settled.
        Task { @MainActor [weak self] in
            self?.perform(command)
        }
    }

    private func perform(_ command: URLCommand) {
        switch command {
        case .showGroup(let name):
            if let group = group(named: name) { popupController.show(groupID: group.id) }
        case .launchGroup(let name):
            if let group = group(named: name) { openAll(group) }
        case .quitGroup(let name, let mode):
            if let group = group(named: name) { closeAll(group, mode: mode) }
        case .hideGroup(let name):
            if let group = group(named: name) { hideAll(group) }
        case .showShortcut(let digit):
            if let group = GroupShortcuts.group(forDigit: digit, in: store.groups) {
                popupController.show(groupID: group.id)
            } else {
                urlLogger.error("Shortcut \(digit) has no group")
                NSSound.beep()
            }
        case .closePopup:
            popupController.close()
        case .openSettings:
            showSettingsWindow(nil)
        case .manageGroups:
            popupController.close()
            mainWindowController.show()
        }
    }

    private func group(named name: String) -> DockGroup? {
        guard let group = GroupLookup.group(matching: name, in: store.groups) else {
            urlLogger.error("No group matches “\(name, privacy: .public)”")
            NSSound.beep()
            return nil
        }
        return group
    }
}

// MARK: - Siri and Shortcuts

extension AppDelegate: GroupIntentHandling {
    var groups: [DockGroup] { store.groups }

    func showPopup(forGroup id: DockGroup.ID) {
        popupController.show(groupID: id)
    }

    func launchAll(_ group: DockGroup) async -> LaunchReport {
        await launcher.openAll(group)
    }

    func quitAll(_ group: DockGroup, mode: QuitMode) -> QuitReport {
        terminator.closeAll(group, mode: mode)
    }
}
