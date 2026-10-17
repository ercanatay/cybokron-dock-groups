import AppKit
import DockGroupsCore

/// Owns the app's long-lived objects. The app is a menu bar utility (`LSUIElement`): it has no Dock
/// icon, and its window opens from the menu bar or when the app is opened again while running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GroupStore(persistence: JSONFileGroupPersistence())
    private let launcher = GroupLauncher()
    private var statusBarController: StatusBarController?
    private lazy var mainWindowController = MainWindowController(
        store: store,
        openAll: { [weak self] group in self?.openAll(group) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()
        statusBarController = StatusBarController(
            store: store,
            actions: StatusBarController.Actions(
                openAll: { [weak self] group in self?.openAll(group) },
                showMainWindow: { [weak self] in self?.mainWindowController.show() }
            )
        )
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
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func openAll(_ group: DockGroup) {
        Task { @MainActor in
            let report = await launcher.openAll(group)
            LaunchReportPresenter.presentProblems(in: report)
        }
    }
}
