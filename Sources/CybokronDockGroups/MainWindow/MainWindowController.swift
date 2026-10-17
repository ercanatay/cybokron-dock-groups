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

    init(store: GroupStore, tiles: TileImageCache, standalone: StandaloneController, actions: MainWindowView.Actions) {
        let hostingController = NSHostingController(
            rootView: MainWindowView(store: store, tiles: tiles, standalone: standalone, actions: actions)
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
}
