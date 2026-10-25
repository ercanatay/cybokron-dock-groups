import AppIntents

/// The app's ready-made shortcuts: Siri phrases and Spotlight/Shortcuts app entries for the
/// five group actions and New Group from Open Apps (6 of the 10 the system allows). Phrases with a
/// group are generated for every group name the app reports (see `updateAppShortcutParameters()`);
/// the others ask which group. Add Open Apps to Group is in the Shortcuts app without a phrase
/// (capture spec Decision 5).
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
        // Keep the first phrase of these two in step with `GroupInvocations.switchingPhrases`.
        AppShortcut(
            intent: StartGroupIntent(),
            phrases: [
                "Start \(\.$group) in \(.applicationName)",
                "Switch to \(\.$group) in \(.applicationName)",
                "Start a group in \(.applicationName)",
            ],
            shortTitle: "Start Group",
            systemImageName: "play.square"
        )
        AppShortcut(
            intent: FinishGroupIntent(),
            phrases: [
                "Finish \(\.$group) in \(.applicationName)",
                "Wind up \(\.$group) in \(.applicationName)",
                "Finish a group in \(.applicationName)",
            ],
            shortTitle: "Finish Group",
            systemImageName: "stop.circle"
        )
        // Keep the first phrase in step with `GroupInvocations.capturePhrase`.
        AppShortcut(
            intent: CaptureOpenAppsIntent(),
            phrases: [
                "Capture my open apps in \(.applicationName)",
                "Make a group from my open apps in \(.applicationName)",
            ],
            shortTitle: "New Group from Open Apps",
            systemImageName: "rectangle.stack.badge.plus"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .teal }
}
