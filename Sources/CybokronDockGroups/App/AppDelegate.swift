import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Owns the app's long-lived objects. The app is a menu bar utility (`LSUIElement`): it has no Dock
/// icon, and its windows open from the menu bar or when the app is opened again while running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GroupStore(persistence: JSONFileGroupPersistence())
    private let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence())
    private let launcher = GroupLauncher()
    private let terminator = GroupTerminator()
    private let icons = WorkspaceAppIconProvider()
    private let runningApps = RunningAppsMonitor()
    private lazy var tiles: TileImageCache = TileImageCache(iconProvider: icons)
    private var statusBarController: StatusBarController?
    private var subscriptions: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "App")

    private lazy var mainWindowController: MainWindowController = MainWindowController(
        store: store,
        tiles: tiles,
        actions: MainWindowView.Actions(
            openAll: { [weak self] group in self?.openAll(group) },
            showPopup: { [weak self] group in self?.popupController.show(groupID: group.id) }
        )
    )
    private lazy var settingsWindowController: SettingsWindowController = SettingsWindowController(
        preferences: preferences,
        store: store,
        shortcuts: shortcutMonitor
    )
    private lazy var aboutWindowController = AboutWindowController()
    private lazy var shortcutMonitor: GlobalShortcutMonitor = GlobalShortcutMonitor(preferences: preferences) { [weak self] digit in
        self?.togglePopup(forShortcut: digit)
    }
    private lazy var popupController: PopupPanelController = PopupPanelController(
        store: store,
        preferences: preferences,
        tiles: tiles,
        icons: icons,
        runningApps: runningApps,
        actions: PopupPanelController.Actions(
            open: { [weak self] app, group in self?.open(app, in: group) },
            openAll: { [weak self] group in self?.openAll(group) },
            closeAll: { [weak self] group, mode in self?.closeAll(group, mode: mode) },
            manageGroups: { [weak self] in self?.mainWindowController.show() }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()
        // Changed and deleted groups lose their cached tiles.
        store.$groups
            .sink { [weak self] groups in self?.tiles.synchronize(with: groups) }
            .store(in: &subscriptions)
        statusBarController = StatusBarController(
            store: store,
            actions: StatusBarController.Actions(
                showPopup: { [weak self] group in self?.popupController.toggle(groupID: group.id) },
                openAll: { [weak self] group in self?.openAll(group) },
                showMainWindow: { [weak self] in self?.mainWindowController.show() },
                showSettings: { [weak self] in self?.showSettingsWindow(nil) },
                showAbout: { [weak self] in self?.showAboutWindow(nil) },
                menuWillOpen: { [weak self] in self?.popupController.close() },
                tileImage: { [weak self] group in
                    self?.tiles.image(for: group, pointSize: StatusBarController.menuTileSize) ?? NSImage()
                },
                shortcutTitle: { [weak self] group in self?.shortcutTitle(for: group) }
            )
        )
        shortcutMonitor.start()
        // The window stays closed at launch unless there's a problem the user needs to see.
        if store.issue != nil {
            mainWindowController.show()
        }
    }

    /// Opening the app again (Finder, `open -a`, Spotlight) while it runs shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingSave()
        preferences.flushPendingSave()
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

    private func open(_ app: AppReference, in group: DockGroup) {
        Task { @MainActor in
            let report = await launcher.open(app, inGroup: group)
            LaunchReportPresenter.presentProblems(in: report)
        }
    }

    private func openAll(_ group: DockGroup) {
        Task { @MainActor in
            let report = await launcher.openAll(group)
            LaunchReportPresenter.presentProblems(in: report)
        }
    }

    private func closeAll(_ group: DockGroup, mode: QuitMode) {
        LaunchReportPresenter.presentProblems(in: terminator.closeAll(group, mode: mode))
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

    private func shortcutTitle(for group: DockGroup) -> String? {
        let settings = preferences.preferences
        guard settings.shortcutsEnabled, let digit = GroupShortcuts.digit(forGroup: group.id, in: store.groups) else {
            return nil
        }
        return GroupShortcuts.title(digit: digit, modifiers: settings.shortcutModifiers)
    }
}
