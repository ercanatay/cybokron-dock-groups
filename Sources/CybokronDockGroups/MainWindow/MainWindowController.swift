import AppKit
import DockGroupsCore
import SwiftUI

/// The group management window: an AppKit window hosting the SwiftUI `MainWindowView`, so it can
/// be opened from the menu bar item and on reopen.
@MainActor
final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "MainWindow"

    /// Called each time the window is about to show.
    var willShow: (() -> Void)?

    private let store: GroupStore
    private let selection = GroupWindowSelection()

    init(store: GroupStore, tiles: TileImageCache, standalone: StandaloneController, actions: MainWindowView.Actions) {
        self.store = store
        let hostingController = NSHostingController(
            rootView: MainWindowView(store: store, tiles: tiles, standalone: standalone, actions: actions, selection: selection)
        )
        hostingController.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = AppInfo.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        willShow?()
        NSApp.activate()
        if let window, window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Group Settings: shows the window on the settings of the group `token` names (an identifier
    /// or a name), brought to the front if it's open already. When no group matches it opens on
    /// the group it showed before (`GroupSettingsDestination`).
    @discardableResult
    func showSettings(ofGroup token: String) -> GroupSettingsDestination {
        let destination = GroupSettingsDestination(request: token, current: selection.groupID, in: store.groups)
        selection.groupID = destination.selection
        show()
        return destination
    }
}
