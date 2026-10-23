import AppIntents
import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Owns the app's long-lived objects. The app is a menu bar utility (`LSUIElement`): it has no Dock
/// icon, and its windows open from the menu bar or when the app is opened again while running.
/// Group popups also open from the global shortcuts, Siri and Shortcuts, and `cybokrondockgroups:`
/// URLs. App launches are counted for the Most Used list while it's turned on. Standalone groups get their own
/// apps with their own Dock icons (`StandaloneController`); those run with `AgentAppDelegate`.
/// `AutoUpdater` looks for new releases on GitHub (only here, never in an agent). A second copy of
/// the app, launched while one runs, hands its URLs to the running copy and quits (`SecondCopyHandoff`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy, like everything that reads the files: a second copy that hands its URLs over and quits
    // (`SecondCopyHandoff`, decided before launching finishes) never loads them — and so never
    // moves an unreadable file aside under the running copy.
    private lazy var store = GroupStore(persistence: JSONFileGroupPersistence())
    private lazy var preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence())
    private let launcher = GroupLauncher()
    private let terminator = GroupTerminator()
    private let icons = WorkspaceAppIconProvider()
    private let runningApps = RunningAppsMonitor()
    /// Records launches only while Most Used is on (asked at every launch and activation).
    private lazy var usage: UsageStore = UsageStore(
        persistence: JSONFileUsagePersistence(),
        sessionLength: TimeInterval(preferences.preferences.mostUsedSessionSeconds),
        isRecordingEnabled: { [weak self] in self?.preferences.preferences.showsMostUsed ?? false }
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
    private var urlGate = URLCommandGate()
    /// Close All from every source; a link asks first.
    private lazy var quitRequests = GroupQuitRequests(prompt: QuitConfirmationAlert()) { [terminator] group, mode in
        terminator.closeAll(group, mode: mode)
    }
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "App")
    private let urlLogger = Logger(subsystem: "com.cybokron.dockgroups", category: "URLScheme")

    private lazy var mainWindowController: MainWindowController = {
        let controller = MainWindowController(
            store: store,
            tiles: tiles,
            icons: icons,
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
        updater: updater,
        isStatusItemShown: { [weak self] in self?.statusBarController?.itemFrame != nil },
        // Standalone groups from a backup get their Dock tiles instead of being turned off.
        groupsRestored: { [weak self] groups in self?.standalone.adoptRestoredGroups(groups) }
    )
    private lazy var aboutWindowController = AboutWindowController()
    private lazy var addWebsiteWindowController = AddWebsiteWindowController(store: store)
    private lazy var updater = AutoUpdater(preferences: preferences, groups: store)
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
            closeAll: { [weak self] group, mode in _ = self?.closeAll(group, mode: mode, from: .userAction) },
            hideAll: { [weak self] group in self?.hideAll(group) },
            manageGroups: { [weak self] in self?.mainWindowController.show() },
            showGroupSettings: { [weak self] group in self?.mainWindowController.showSettings(ofGroup: group.id.uuidString) },
            addWebsite: { [weak self] group in self?.addWebsiteWindowController.show(for: group) }
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
        updater.isWindowShown = { [weak self] in self?.updateWindowController.window?.isVisible == true }
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

    /// Opens an item from a popup or the Most Used menu; a running app comes back with its windows
    /// when Settings → Popup → Running Apps says so. A website opens in the default browser, a file
    /// or folder with its default app.
    private func open(_ app: AppReference, in group: DockGroup) {
        let restoresWindows = preferences.preferences.restoresWindowsOfRunningApps
        if restoresWindows, app.kind.hasProcess {
            AccessibilityAccess.promptOnceForRestoringWindows(of: app)
        }
        Task { @MainActor in
            let report = await launcher.open(app, inGroup: group, restoringWindows: restoresWindows)
            LaunchReportPresenter.presentProblems(in: report)
        }
    }

    private func openAll(_ group: DockGroup) {
        Task { @MainActor in
            LaunchReportPresenter.presentProblems(in: await launchAll(group))
        }
    }

    /// Quits the group's running apps, asking first when a link asked (`QuitRequestSource`).
    private func closeAll(_ group: DockGroup, mode: QuitMode, from source: QuitRequestSource) -> GroupQuitRequests.Outcome {
        let outcome = quitRequests.request(group, mode: mode, from: source)
        if let report = outcome.report {
            LaunchReportPresenter.presentProblems(in: report)
        }
        return outcome
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
        switch urlGate.accept(command) {
        case .accepted:
            break
        case .repeated:
            urlLogger.notice("Ignored \(url.absoluteString, privacy: .public): repeated within the \(Int(CommandThrottle.urlCooldown))-second cooldown")
            return
        case .groupActionLimited:
            urlLogger.notice("Ignored \(url.absoluteString, privacy: .public): a link opened or hid a group's apps less than \(Int(CommandThrottle.urlCooldown)) seconds ago")
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
            guard let group = group(named: name) else { return }
            switch closeAll(group, mode: mode, from: .link) {
            case .quit:
                urlLogger.notice("Quitting the apps of group \(group.id, privacy: .public) (\(mode.rawValue, privacy: .public)): confirmed")
            case .declined:
                urlLogger.notice("Quitting the apps of group \(group.id, privacy: .public): cancelled")
            case .dropped:
                urlLogger.notice("Ignored quitting the apps of group \(group.id, privacy: .public): another link's question is showing")
                return
            }
            // The cooldown starts once the question is answered, so links that came while it showed
            // (or right after) don't ask again.
            urlGate.restartCooldown(for: command)
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
        case .showGroupSettings(let name):
            popupController.close()
            if case .unmatched = mainWindowController.showSettings(ofGroup: name) {
                // The window still opens, on the group it showed before.
                urlLogger.error("No group matches “\(name, privacy: .public)”: showing the group window as it was")
                NSSound.beep()
            }
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

    /// Siri and Shortcuts ask in their own way (`QuitGroupIntent`), not with the app's alert.
    func quitAll(_ group: DockGroup, mode: QuitMode, confirm: (QuitConfirmation) async throws -> Void) async throws -> QuitReport {
        try await quitRequests.requestFromIntent(group, mode: mode, confirm: confirm)
    }
}
