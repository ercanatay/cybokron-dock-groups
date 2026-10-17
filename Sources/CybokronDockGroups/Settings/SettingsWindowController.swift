import AppKit
import DockGroupsCore
import SwiftUI

/// The Settings window (⌘,): popup settings, shortcuts, the Most Used list and updates, each in its
/// own tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "SettingsWindow"

    init(
        preferences: PreferencesStore,
        store: GroupStore,
        usage: UsageStore,
        shortcuts: GlobalShortcutMonitor,
        updater: AutoUpdater
    ) {
        let hostingController = NSHostingController(
            rootView: SettingsView(preferences: preferences, store: store, usage: usage, shortcuts: shortcuts, updater: updater)
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
    let usage: UsageStore
    let shortcuts: GlobalShortcutMonitor
    let updater: AutoUpdater

    var body: some View {
        TabView {
            PopupSettingsView(preferences: preferences)
                .tabItem { Label("Popup", systemImage: "rectangle.grid.2x2") }
            ShortcutsSettingsView(preferences: preferences, store: store, shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            MostUsedSettingsView(preferences: preferences, usage: usage)
                .tabItem { Label("Most Used", systemImage: "star") }
            UpdatesSettingsView(preferences: preferences, updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .padding(.top, 8)
    }
}
