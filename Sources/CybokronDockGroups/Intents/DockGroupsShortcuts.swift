import AppIntents

/// The app's ready-made shortcuts: Siri phrases and Spotlight/Shortcuts app entries for the
/// three group actions. Phrases with a group are generated for every group name the app reports
/// (see `updateAppShortcutParameters()`); the others ask which group.
struct DockGroupsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchGroupIntent(),
            phrases: [
                "Launch \(\.$group) in \(.applicationName)",
                "Open my \(\.$group) apps with \(.applicationName)",
                "Fire up \(\.$group) in \(.applicationName)",
                "Launch a group in \(.applicationName)",
            ],
            shortTitle: "Launch Group",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: QuitGroupIntent(),
            phrases: [
                "Quit \(\.$group) in \(.applicationName)",
                "Close my \(\.$group) apps with \(.applicationName)",
                "Wind down \(\.$group) in \(.applicationName)",
                "Quit a group in \(.applicationName)",
            ],
            shortTitle: "Quit Group",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ShowGroupIntent(),
            phrases: [
                "Show \(\.$group) in \(.applicationName)",
                "Bring up \(\.$group) in \(.applicationName)",
                "Go to \(\.$group) in \(.applicationName)",
                "Show a group in \(.applicationName)",
            ],
            shortTitle: "Show Group",
            systemImageName: "square.grid.2x2"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .teal }
}
