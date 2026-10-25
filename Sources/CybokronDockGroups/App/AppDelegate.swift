import AppIntents
import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Owns the app's long-lived objects. The app is a menu bar utility (`LSUIElement`): it has no Dock
/// icon, and its windows open from the menu bar or when the app is opened again while running.
/// Group popups also open from the global shortcuts, Siri and Shortcuts, and `cybokrondockgroups:`
/// URLs; a group's own keyboard shortcut shows its popup, opens it or starts it
/// (`performGroupShortcut`). App launches are counted for the Most Used list while it's turned on. Standalone groups get their own
/// apps with their own Dock icons (`StandaloneController`); those run with `AgentAppDelegate`.
/// `AutoUpdater` looks for new releases on GitHub (only here, never in an agent). A second copy of
/// the app, launched while one runs, hands its URLs to the running copy and quits (`SecondCopyHandoff`).
///
/// Groups are started and finished (`ContextSwitcher`) from the popup, the menu bar menu, the group
/// window, links, Siri and Shortcuts, and started, opened or shown when a Focus with the app's
/// filter turns on (`GroupFocusFilter`, through `FocusRequestCoordinator`, never quitting anything);
/// the current group is kept in memory only (`ContextSession`).
/// Items with a launch delay wait in one `DelayedLaunches`, shared by Open All, Start, Finish, Hide
/// All and Close All, and cancelled when the app quits.
///
/// New Group from Open Apps… and Add Open Apps… (the menu bar menu, the group window, an empty
/// group's popup, `capture` links) read the open apps first, while the app the user was in is still
/// in front, and then show the capture sheet in the group window (`beginCapture`, `CaptureController`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy, like everything that reads the files: a second copy that hands its URLs over and quits
    // (`SecondCopyHandoff`, decided before launching finishes) never loads them — and so never
    // moves an unreadable file aside under the running copy.
    private lazy var store = GroupStore(persistence: JSONFileGroupPersistence())
    private lazy var preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence())
    /// The templates (`templates.json`), read when the group window or Settings first needs them,
    /// so quitting before that reads nothing.
    private var loadedTemplates: TemplateStore?
    private var templates: TemplateStore {
        if let loadedTemplates { return loadedTemplates }
        let templates = TemplateStore(persistence: JSONFileTemplatePersistence())
        loadedTemplates = templates
        return templates
    }
    /// Open All's and Start's items that wait for their launch delay; what they couldn't open is
    /// shown once they've all had their turn.
    private lazy var delayedLaunches: DelayedLaunches = {
        let delayed = DelayedLaunches { [weak self] id in self?.store.group(withID: id) }
        delayed.onFinished = { report in LaunchReportPresenter.presentProblems(in: report) }
        return delayed
    }()
    private lazy var launcher = GroupLauncher(workspace: SystemApplicationWorkspace(), pendingLaunches: delayedLaunches)
    /// Close All leaves the protected apps (Settings → Switching) alone, whoever asks.
    private lazy var terminator = GroupTerminator(
        applications: SystemRunningApplications(),
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        protectedApps: { [weak self] in self?.preferences.preferences.protectedApps ?? ProtectedApps() },
        pendingLaunches: delayedLaunches
    )
    /// The current group and the groups started before it, forgotten when the app quits.
    private let session = ContextSession()
    /// Start and Finish, one at a time; a link's question goes through `quitRequests`, so it never
    /// shows while a quit link's does.
    private lazy var switcher = ContextSwitcher(
        store: store,
        preferences: preferences,
        session: session,
        launcher: launcher,
        terminator: terminator,
        applications: SystemRunningApplicationsListing(),
        questions: quitRequests
    )
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
    /// Capturing the open apps: the order apps came to the front, the snapshot, the sheet's plan.
    private lazy var capture = CaptureController(store: store, preferences: preferences)
    private var statusBarController: StatusBarController?
    private var subscriptions: Set<AnyCancellable> = []
    /// Set while this is a second copy of the app, launched next to the copy that runs: it then
    /// only hands its URLs over to that copy and quits.
    private var secondCopyHandoff: SecondCopyHandoff?
    private var urlGate = URLCommandGate()
    /// Close All from every source; a link asks first. It also asks a start or finish link's
    /// question, one question at a time.
    private lazy var quitRequests = GroupQuitRequests(
        prompt: QuitConfirmationAlert(),
        transitionPrompt: TransitionConfirmationAlert()
    ) { [terminator] group, mode in
        terminator.closeAll(group, mode: mode)
    }
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "App")
    private let urlLogger = Logger(subsystem: "com.cybokron.dockgroups", category: "URLScheme")

    private lazy var mainWindowController: MainWindowController = {
        let controller = MainWindowController(
            store: store,
            templates: templates,
            tiles: tiles,
            icons: icons,
            standalone: standalone,
            session: session,
            shortcuts: shortcutMonitor,
            capture: capture,
            actions: MainWindowView.Actions(
                openAll: { [weak self] group in self?.openAll(group) },
                hideAll: { [weak self] group in self?.hideAll(group) },
                showPopup: { [weak self] group in self?.popupController.show(groupID: group.id) },
                start: { [weak self] group in self?.start(group) },
                finish: { [weak self] group in self?.finish(group) },
                showProtectedApps: { [weak self] in self?.showSwitchingSettings() },
                archive: { [weak self] group in self?.archive(group) },
                restore: { [weak self] id in self?.restore(id) },
                capture: { [weak self] target in self?.beginCapture(target) }
            )
        )
        // A standalone group's Dock tile may have been dragged out of the Dock meanwhile.
        controller.willShow = { [weak self] in self?.standalone.checkDockTiles() }
        return controller
    }()
    private lazy var settingsWindowController: SettingsWindowController = SettingsWindowController(
        preferences: preferences,
        store: store,
        templates: templates,
        usage: usage,
        shortcuts: shortcutMonitor,
        updater: updater,
        session: session,
        runningApps: runningApps,
        icons: icons,
        isStatusItemShown: { [weak self] in self?.statusBarController?.itemFrame != nil },
        // Standalone groups from a backup get their Dock tiles instead of being turned off.
        groupsRestored: { [weak self] groups in self?.standalone.adoptRestoredGroups(groups) },
        showGroupSettings: { [weak self] id in
            _ = self?.mainWindowController.showSettings(ofGroup: id.uuidString)
        }
    )
    private lazy var aboutWindowController = AboutWindowController()
    private lazy var addWebsiteWindowController = AddWebsiteWindowController(store: store)
    private lazy var updater = AutoUpdater(preferences: preferences, groups: store, templateCount: { [unowned self] in self.templates.templates.count })
    private lazy var updateWindowController = UpdateWindowController(updater: updater)
    private lazy var shortcutMonitor: GlobalShortcutMonitor = GlobalShortcutMonitor(
        preferences: preferences,
        store: store,
        onShortcut: { [weak self] digit in self?.togglePopup(forShortcut: digit) },
        onGroupShortcut: { [weak self] id, action in self?.performGroupShortcut(id, action: action) }
    )
    private lazy var popupController: PopupPanelController = PopupPanelController(
        store: store,
        preferences: preferences,
        tiles: tiles,
        icons: icons,
        runningApps: runningApps,
        mostUsed: mostUsed,
        session: session,
        actions: PopupPanelController.Actions(
            open: { [weak self] app, group in self?.open(app, in: group) },
            openAll: { [weak self] group in self?.openAll(group) },
            closeAll: { [weak self] group, mode in _ = self?.closeAll(group, mode: mode, from: .userAction) },
            hideAll: { [weak self] group in self?.hideAll(group) },
            manageGroups: { [weak self] in self?.mainWindowController.show() },
            showGroupSettings: { [weak self] group in self?.mainWindowController.showSettings(ofGroup: group.id.uuidString) },
            addWebsite: { [weak self] group in self?.addWebsiteWindowController.show(for: group) },
            inGroupWindow: { [weak self] action, group in
                self?.mainWindowController.perform(action, inGroup: group.id)
            },
            start: { [weak self] group in self?.start(group) },
            finish: { [weak self] group in self?.finish(group) },
            captureOpenApps: { [weak self] group in self?.beginCapture(.group(group.id)) }
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
        capture.start()
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
                start: { [weak self] group in self?.start(group) },
                finish: { [weak self] group in self?.finish(group) },
                switchingOffer: { [weak self] group in self?.switchingOffer(for: group) },
                currentGroupID: { [weak self] in self?.session.current },
                showMainWindow: { [weak self] in self?.mainWindowController.show() },
                captureNewGroup: { [weak self] in self?.beginCapture(.newGroup) },
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
        // Focus filter calls that came while the app started wait until now.
        FocusFilterBridge.coordinator.handler = self
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
        // Items still waiting for their launch delay don't open after the app is gone, and what
        // the others couldn't open isn't shown in an alert now.
        delayedLaunches.onFinished = nil
        delayedLaunches.cancelAll()
        store.flushPendingSave()
        preferences.flushPendingSave()
        usage.flushPendingSave()
        loadedTemplates?.flushPendingSave()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Target of the Settings… menu items (reached through the responder chain).
    @objc func showSettingsWindow(_ sender: Any?) {
        popupController.close()
        settingsWindowController.show()
    }

    /// Settings on the Switching pane (the group window's Protected Apps…).
    private func showSwitchingSettings() {
        popupController.close()
        settingsWindowController.show(pane: .switching)
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

    /// Start from the popup, the menu bar menu or the group window: the user's click, which quits
    /// what the group's settings say without asking (as Close All does).
    private func start(_ group: DockGroup) {
        Task { @MainActor in
            do {
                LaunchReportPresenter.presentProblems(in: try await switcher.start(group.id, trigger: .userAction))
            } catch {
                logger.error("Starting group \(group.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Finish from the popup, the menu bar menu or the group window.
    private func finish(_ group: DockGroup) {
        Task { @MainActor in
            do {
                LaunchReportPresenter.presentProblems(in: try await switcher.finish(group.id, trigger: .userAction))
            } catch {
                logger.error("Finishing group \(group.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Archive, from the group window (spec §1.7): the group leaves every menu, shortcut, link and
    /// agent with `store.groups`, and its items still waiting for their launch delay don't open.
    /// Running apps aren't touched.
    private func archive(_ group: DockGroup) {
        delayedLaunches.cancel(group: group.id)
        guard store.archiveGroup(group.id) != nil else { return }
        logger.notice("Archived group \(group.id, privacy: .public)\(group.isStandalone ? ": its own app and Dock icon are removed" : "", privacy: .public)")
    }

    /// Restore, from the group window: the group is active again at the end of the list. One that
    /// was standalone gets its own app and Dock icon back the way the Standalone toggle does, with
    /// its alert when that fails (spec §2.10).
    private func restore(_ id: DockGroup.ID) -> GroupRestoreResult? {
        guard let result = store.restoreGroup(id) else { return nil }
        logger.notice("Restored group \(id, privacy: .public)\(result.removedShortcut != nil ? " without its shortcut, which another group has" : "", privacy: .public)")
        if result.restoresStandalone {
            standalone.setStandalone(true, for: id)
        }
        return result
    }

    /// New Group from Open Apps… or Add Open Apps… (capture spec §2.6): the open apps are read now —
    /// the menu bar menu and the popup don't bring this app to the front, so the app the user was in
    /// is still the front one; from the group window, the history puts the app used before it first
    /// — and only then does the group window come forward with the sheet. An archived or deleted
    /// group is never a target. Nothing is opened, hidden or quit; the sheet's click adds the apps.
    private func beginCapture(_ target: CaptureTarget) {
        if case .group(let id) = target, store.group(withID: id) == nil {
            logger.notice("Capture into group \(id, privacy: .public): no such active group")
            NSSound.beep()
            return
        }
        let snapshot = capture.snapshot()
        popupController.close()
        mainWindowController.capture(target, from: snapshot)
    }

    /// What the menu bar menu offers for the group: Finish for the current group, Start otherwise.
    private func switchingOffer(for group: DockGroup) -> SwitchingOffer {
        SwitchingOffer.offer(for: group, current: session.current, previous: session.previous, in: store.groups)
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

    /// A group's own shortcut (spec §1.4): shows or hides its popup, opens its items, or starts it —
    /// finishes it when it's the current group (`ShortcutTransition`). Start and Finish run as
    /// `TransitionTrigger.shortcut`: when they'd quit apps they ask first with the link's alert
    /// (Hide Instead, Cancel). Only active groups have their shortcuts registered.
    private func performGroupShortcut(_ id: DockGroup.ID, action: GroupShortcutAction) {
        guard let group = store.group(withID: id) else {
            logger.notice("Group shortcut of \(id, privacy: .public): no such group")
            return
        }
        switch action {
        case .showPopup:
            popupController.toggle(groupID: id)
        case .openAll:
            openAll(group)
        case .startOrFinish:
            switch ShortcutTransition.forGroup(id, in: session, at: Date()) {
            case .start:
                transitionFromShortcut(group, starting: true)
            case .finish:
                transitionFromShortcut(group, starting: false)
            case .nothing:
                logger.notice("Group shortcut of \(id, privacy: .public): started just now, nothing to do")
            }
        }
    }

    private func transitionFromShortcut(_ group: DockGroup, starting: Bool) {
        Task { @MainActor in
            do {
                let report = starting
                    ? try await switcher.start(group.id, trigger: .shortcut)
                    : try await switcher.finish(group.id, trigger: .shortcut)
                switch report.outcome {
                case .done, .repeated:
                    LaunchReportPresenter.presentProblems(in: report)
                case .declined:
                    logger.notice("\(starting ? "Start" : "Finish", privacy: .public) of group \(group.id, privacy: .public) from its shortcut: cancelled")
                case .dropped:
                    logger.notice("\(starting ? "Start" : "Finish", privacy: .public) of group \(group.id, privacy: .public) from its shortcut: another question is showing")
                }
            } catch {
                logger.error("\(starting ? "Starting" : "Finishing", privacy: .public) group \(group.id, privacy: .public) from its shortcut failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A copy of the app's icon sized for a menu item; the shared icon keeps its size.
    private func menuIcon(for app: AppReference) -> NSImage {
        let icon = (icons.icon(for: app).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: StatusBarController.menuTileSize, height: StatusBarController.menuTileSize)
        return icon
    }

    /// The group's shortcuts for its menu bar menu item's tooltip: its number shortcut and its own
    /// shortcut while that works ("⌃⌥1, ⌃⌥C"; with what the own one does when that isn't showing the
    /// popup). Not the item's key equivalent, which would break its ⌥, ⇧⌥ and ⌃⌥ alternates.
    private func shortcutTitle(for group: DockGroup) -> String? {
        let settings = preferences.preferences
        var titles: [String] = []
        if settings.shortcutsEnabled, let digit = GroupShortcuts.digit(forGroup: group.id, in: store.groups) {
            titles.append(GroupShortcuts.title(digit: digit, modifiers: settings.shortcutModifiers))
        }
        if let shortcut = group.shortcut, shortcutMonitor.groupStatuses[group.id] == .on {
            let keys = KeyNames.title(for: shortcut.keys)
            titles.append(shortcut.action == .showPopup ? keys : "\(keys) (\(shortcut.action.title))")
        }
        return titles.isEmpty ? nil : titles.joined(separator: ", ")
    }

    // MARK: - URL scheme

    private func handle(_ url: URL) {
        guard let link = LinkCommand(url: url) else {
            urlLogger.error("Ignored unsupported URL \(url.absoluteString, privacy: .public)")
            return
        }
        switch urlGate.accept(link) {
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
            switch link {
            case .command(let command): self?.perform(command)
            case .switching(let command): await self?.perform(command)
            }
        }
    }

    /// A start or finish link: asks first when it would quit apps (`TransitionConfirmationAlert`,
    /// one question at a time with quit links), offering to hide them instead.
    private func perform(_ command: SwitchingURLCommand) async {
        guard let group = group(named: command.group) else { return }
        let report: TransitionReport
        do {
            switch command {
            case .start: report = try await switcher.start(group.id, trigger: .link)
            case .finish: report = try await switcher.finish(group.id, trigger: .link)
            }
        } catch {
            urlLogger.error("\(command.throttleKey, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return
        }
        switch report.outcome {
        case .done, .repeated:
            LaunchReportPresenter.presentProblems(in: report)
        case .declined:
            urlLogger.notice("\(command.throttleKey, privacy: .public) for group \(group.id, privacy: .public): cancelled")
        case .dropped:
            urlLogger.notice("Ignored \(command.throttleKey, privacy: .public) for group \(group.id, privacy: .public): another link's question is showing")
            return
        }
        // As for quit links: the cooldown starts again once the question is answered.
        if report.wasAsked {
            urlGate.restartCooldown(for: command)
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
                urlLogger.error("No group matches “\(name, privacy: .public)”\(self.archivedMatch(for: name), privacy: .public): showing the group window as it was")
                NSSound.beep()
            }
        case .manageGroups:
            popupController.close()
            mainWindowController.show()
        case .captureNewGroup:
            // Only the sheet: the user's click makes the group (capture spec Decision 5).
            beginCapture(.newGroup)
        case .captureOpenApps(let name):
            if let group = group(named: name) { beginCapture(.group(group.id)) }
        }
    }

    /// Links act on active groups only: an archived group is never found (spec §2.11).
    private func group(named name: String) -> DockGroup? {
        guard let group = GroupLookup.group(matching: name, in: store.groups) else {
            urlLogger.error("No group matches “\(name, privacy: .public)”\(self.archivedMatch(for: name), privacy: .public)")
            NSSound.beep()
            return nil
        }
        return group
    }

    /// For the log of a link no active group matches: ", but archived group <id> does" when an
    /// archived one does (by identifier; archived groups aren't named in the log).
    private func archivedMatch(for name: String) -> String {
        guard let archived = GroupLookup.group(matching: name, in: store.archivedGroups.map(\.group)) else { return "" }
        return ", but archived group \(archived.id.uuidString) does"
    }
}

// MARK: - Siri and Shortcuts

extension AppDelegate: GroupIntentHandling {
    var groups: [DockGroup] { store.groups }
    var archivedGroups: [ArchivedGroup] { store.archivedGroups }

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

    /// Start Group: asks in Siri or Shortcuts (`confirm`) before quitting anything.
    func start(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport {
        try await switcher.start(group.id, trigger: .intent, confirm: confirm)
    }

    /// Finish Group: asks in Siri or Shortcuts (`confirm`) before quitting anything.
    func finish(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport {
        try await switcher.finish(group.id, trigger: .intent, confirm: confirm)
    }
}

// MARK: - Focus

/// What a Focus asks for, carried out with `trigger: .focus` (`FocusRequestCoordinator`): a Focus
/// never quits apps, and nothing it does asks a question.
extension AppDelegate: FocusRequestHandling {
    func group(withID id: DockGroup.ID) -> DockGroup? {
        store.group(withID: id)
    }

    var currentGroupID: DockGroup.ID? { session.current }
    var currentGroupStartTrigger: TransitionTrigger? { session.startTrigger }

    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async {
        do {
            LaunchReportPresenter.presentProblems(in: try await switcher.start(id, trigger: trigger))
        } catch {
            logger.error("A Focus couldn't start group \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async {
        do {
            LaunchReportPresenter.presentProblems(in: try await switcher.finish(id, trigger: trigger, showsPrevious: showsPrevious))
        } catch {
            logger.error("A Focus couldn't finish group \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func openAllItems(of group: DockGroup) async {
        LaunchReportPresenter.presentProblems(in: await launchAll(group))
    }

    func showPopup(of group: DockGroup) {
        popupController.show(groupID: group.id)
    }
}
