import AppKit
import DockGroupsCore
import SwiftUI

/// The Settings window (⌘,): the app's language and popup settings, shortcuts and Siri, the Most Used list, updates,
/// backups with the diagnostics report, and the changelog, each in its own pane, picked from a sidebar.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "SettingsWindow"
    /// The panes' height on a screen with room for it; shorter screens get shorter panes.
    private static let idealPaneHeight: CGFloat = 640
    /// The panes don't shrink below this, however short the screen.
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
        // Reads the saved release list now, so the Changelog pane shows it at once.
        let changelog = ChangelogService(
            fetcher: GitHubChangelogFeed(appVersion: AppInfo.version),
            currentVersion: SemanticVersion(AppInfo.version)
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
                changelog: changelog,
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

    /// Makes the panes as tall as the screen the window is on has room for, and keeps the whole
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

/// The Settings window's panes, in sidebar order.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case popup
    case shortcuts
    case mostUsed
    case updates
    case backup
    case changelog

    var id: Self { self }

    var title: String {
        switch self {
        case .popup: L10n.Settings.popupTab
        case .shortcuts: L10n.Settings.shortcutsTab
        case .mostUsed: MostUsedGroup.name
        case .updates: L10n.Settings.updatesTab
        case .backup: L10n.Settings.backupTab
        case .changelog: L10n.Changelog.tab
        }
    }

    var systemImage: String {
        switch self {
        case .popup: "rectangle.grid.2x2"
        case .shortcuts: "keyboard"
        case .mostUsed: "star"
        case .updates: "arrow.triangle.2.circlepath"
        case .backup: "externaldrive"
        case .changelog: "newspaper"
        }
    }
}

/// The panes listed in a sidebar, as in System Settings, with the selected one beside it. The
/// sidebar takes the leading edge, so the right in right-to-left languages.
private struct SettingsView: View {
    /// Fits the longest pane name; the panes keep their own 480-point width beside it.
    private static let sidebarWidth: CGFloat = 180

    let preferences: PreferencesStore
    let store: GroupStore
    let usage: UsageStore
    let shortcuts: GlobalShortcutMonitor
    let updater: AutoUpdater
    let backup: SettingsBackupController
    let diagnostics: DiagnosticsController
    let changelog: ChangelogService
    /// Set by `SettingsWindowController` to fit the screen.
    var paneHeight: CGFloat

    /// The pane shown, kept across launches as the window's frame is.
    @AppStorage("SettingsSelectedPane") private var selectedPane: SettingsPane = .popup

    var body: some View {
        HStack(spacing: 0) {
            // A required selection: one pane stays selected, whatever is clicked.
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            paneView
        }
        // The window is as tall as this; each pane's grouped Form fills it and scrolls. The panes
        // must not fix their own height (or `fixedSize` it): the form would then grow past the
        // window and cut off its bottom.
        .frame(height: paneHeight)
    }

    @ViewBuilder
    private var paneView: some View {
        switch selectedPane {
        case .popup:
            PopupSettingsView(preferences: preferences)
        case .shortcuts:
            ShortcutsSettingsView(preferences: preferences, store: store, shortcuts: shortcuts)
        case .mostUsed:
            MostUsedSettingsView(preferences: preferences, usage: usage)
        case .updates:
            UpdatesSettingsView(preferences: preferences, updater: updater)
        case .backup:
            BackupSettingsView(backup: backup, diagnostics: diagnostics)
        case .changelog:
            ChangelogSettingsView(changelog: changelog)
        }
    }
}
