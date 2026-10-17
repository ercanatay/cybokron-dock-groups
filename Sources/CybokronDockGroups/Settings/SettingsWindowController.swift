import AppKit
import DockGroupsCore
import SwiftUI

/// The Settings window (⌘,): popup settings and shortcuts, each in its own tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "SettingsWindow"

    init(preferences: PreferencesStore, store: GroupStore, shortcuts: GlobalShortcutMonitor) {
        let hostingController = NSHostingController(
            rootView: SettingsView(preferences: preferences, store: store, shortcuts: shortcuts)
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
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
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let preferences: PreferencesStore
    let store: GroupStore
    let shortcuts: GlobalShortcutMonitor

    var body: some View {
        TabView {
            PopupSettingsView(preferences: preferences)
                .tabItem { Label("Popup", systemImage: "rectangle.grid.2x2") }
            ShortcutsSettingsView(preferences: preferences, store: store, shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(.top, 8)
    }
}
