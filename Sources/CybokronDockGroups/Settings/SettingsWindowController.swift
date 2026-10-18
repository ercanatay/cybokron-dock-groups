import AppKit
import DockGroupsCore
import SwiftUI

/// The Settings window (⌘,): the app's language and popup settings, shortcuts and Siri, the Most Used list, updates, and
/// backups with the diagnostics report, each in its own tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "SettingsWindow"
    /// The tabs' height on a screen with room for it; shorter screens get shorter tabs.
    private static let idealPaneHeight: CGFloat = 640
    /// The tabs don't shrink below this, however short the screen.
    private static let minimumPaneHeight: CGFloat = 320
    /// Room kept between the window and the edges of the screen's usable area.
    private static let screenMargin: CGFloat = 40
    private let hostingController: NSHostingController<SettingsView>
    private let backup: SettingsBackupController
    private let diagnostics: DiagnosticsController

    init(
        preferences: PreferencesStore,
        store: GroupStore,
        usage: UsageStore,
        shortcuts: GlobalShortcutMonitor,
        updater: AutoUpdater,
        isStatusItemShown: @escaping () -> Bool
    ) {
        let backup = SettingsBackupController(store: store, preferences: preferences)
        let diagnostics = DiagnosticsController(
            preferences: preferences,
            store: store,
            updater: updater,
            isStatusItemShown: isStatusItemShown
        )
        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                store: store,
                usage: usage,
                shortcuts: shortcuts,
                updater: updater,
                backup: backup,
                diagnostics: diagnostics,
                paneHeight: Self.idealPaneHeight
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Settings.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        backup.window = window
        diagnostics.window = window
        self.hostingController = hostingController
        self.backup = backup
        self.diagnostics = diagnostics
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        fitToScreen()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Makes the tabs as tall as the screen the window is on has room for, and keeps the whole
    /// window inside that screen's usable area: a frame saved on a bigger screen could otherwise
    /// leave its bottom out of reach.
    private func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let titleBarHeight = window.frameRect(forContentRect: .zero).height
        let available = visible.height - titleBarHeight - 2 * Self.screenMargin
        hostingController.rootView.paneHeight = min(Self.idealPaneHeight, max(Self.minimumPaneHeight, available))
        hostingController.view.layoutSubtreeIfNeeded()

        let previous = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: hostingController.preferredContentSize))
        // Keep the top-left corner where it was, then pull the window back onto the screen.
        frame.origin.x = max(visible.minX, min(previous.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(previous.maxY - frame.height, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }
}

private struct SettingsView: View {
    let preferences: PreferencesStore
    let store: GroupStore
    let usage: UsageStore
    let shortcuts: GlobalShortcutMonitor
    let updater: AutoUpdater
    let backup: SettingsBackupController
    let diagnostics: DiagnosticsController
    /// Set by `SettingsWindowController` to fit the screen.
    var paneHeight: CGFloat

    var body: some View {
        TabView {
            PopupSettingsView(preferences: preferences)
                .tabItem { Label(L10n.Settings.popupTab, systemImage: "rectangle.grid.2x2") }
            ShortcutsSettingsView(preferences: preferences, store: store, shortcuts: shortcuts)
                .tabItem { Label(L10n.Settings.shortcutsTab, systemImage: "keyboard") }
            MostUsedSettingsView(preferences: preferences, usage: usage)
                .tabItem { Label(MostUsedGroup.name, systemImage: "star") }
            UpdatesSettingsView(preferences: preferences, updater: updater)
                .tabItem { Label(L10n.Settings.updatesTab, systemImage: "arrow.triangle.2.circlepath") }
            BackupSettingsView(backup: backup, diagnostics: diagnostics)
                .tabItem { Label(L10n.Settings.backupTab, systemImage: "externaldrive") }
        }
        .padding(.top, 8)
        // The window is as tall as this; each tab's grouped Form fills it and scrolls. The tabs
        // must not fix their own height (or `fixedSize` it): the form would then grow past the
        // window, cut off its bottom and cover the tab bar.
        .frame(height: paneHeight)
    }
}
