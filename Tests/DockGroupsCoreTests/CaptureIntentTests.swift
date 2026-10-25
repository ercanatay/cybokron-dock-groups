import Foundation
import Testing
@testable import DockGroupsCore

/// Capturing without the sheet, as New Group from Open Apps and Add Open Apps to Group do (capture
/// spec §1.10, §2.7): the apps the sheet would start with selected, never the Shortcuts app.
@Suite("Capture: Siri and Shortcuts")
@MainActor
struct CaptureIntentTests {
    private static let shortcuts = CaptureApps.app("com.apple.shortcuts", "Shortcuts", pid: 110, path: "/System/Applications/Shortcuts.app")
    private static let finder = CaptureApps.app("com.apple.finder", "Finder", pid: 111, path: "/System/Library/CoreServices/Finder.app")
    private static let protectedMail = ProtectedApps([AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])

    private static let xcodeItem = AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
    private static let safariItem = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
    private static let terminalItem = AppReference(bundleIdentifier: "com.apple.Terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app")

    private func makeStore() -> GroupStore {
        GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
    }

    /// The Shortcuts app ran the intent, so it's the most recent; then Xcode, Safari and Terminal.
    private func snapshot(_ apps: [OpenApp], windows: WindowSnapshot? = nil) -> OpenAppsSnapshot {
        OpenAppsSnapshot(
            apps: apps,
            windows: windows,
            history: ActivationHistory(recentIdentities: ["com.apple.shortcuts", "com.apple.dt.xcode", "com.apple.safari", "com.apple.terminal", "com.apple.mail"])
        )
    }

    private func capture(
        _ store: GroupStore,
        _ apps: [OpenApp],
        into target: CaptureTarget = .newGroup,
        typedName: String? = nil,
        settings: CaptureSettings = CaptureSettings(),
        windows: WindowSnapshot? = nil
    ) -> CaptureOutcome {
        store.captureWithoutSheet(
            snapshot(apps, windows: windows),
            into: target,
            typedName: typedName,
            settings: settings,
            protectedApps: Self.protectedMail
        )
    }

    // MARK: - New Group from Open Apps

    @Test func aNewGroupHasTheAppsThatStartSelectedButNeverTheShortcutsApp() throws {
        let store = makeStore()
        let existing = store.addGroup(named: "Work", items: [])
        let apps = [Self.shortcuts, CaptureApps.mail, CaptureApps.safari, Self.finder, CaptureApps.xcode, CaptureApps.terminal]
        let outcome = capture(store, apps)

        let group = try #require(outcome.createdGroup)
        #expect(outcome == .created(group))
        #expect(group.apps == [Self.xcodeItem, Self.safariItem, Self.terminalItem], "most recently used first; no Shortcuts, Finder or protected Mail")
        #expect(group.name == "Xcode +2")
        #expect(store.groups.map(\.id) == [existing.id, group.id], "at the end of the list")
        #expect(store.group(withID: group.id) == group)
        #expect(!group.isStandalone && group.shortcut == nil)
    }

    @Test func theShortcutsAppIsLeftOutWhateverTheCaseOfItsIdentifier() {
        let planned = CapturePlanner.plan(
            snapshot([CaptureApps.app("com.apple.Shortcuts", "Shortcuts", pid: 112, path: "/System/Applications/Shortcuts.app"), CaptureApps.xcode]),
            settings: CaptureSettings(),
            target: .newGroup,
            leavingOut: CaptureOutcome.leftOutApps
        )
        #expect(planned.candidates.map(\.id) == ["com.apple.dt.xcode"])
        #expect(planned.unavailableCount == 0, "left out, not counted")
        #expect(CaptureOutcome.leftOutApps == ["com.apple.shortcuts"])
    }

    @Test func aTypedNameIsKeptAndABlankOrMissingOneIsTheSuggestion() throws {
        let store = makeStore()
        let typed = try #require(capture(store, [CaptureApps.xcode, CaptureApps.safari], typedName: "  Deep Work ").createdGroup)
        #expect(typed.name == "Deep Work")

        let suggested = try #require(capture(store, [CaptureApps.xcode, CaptureApps.safari]).createdGroup)
        #expect(suggested.name == "Xcode +1")
        let blank = try #require(capture(store, [CaptureApps.xcode, CaptureApps.safari], typedName: " ").createdGroup)
        #expect(blank.name == "Xcode +1 2", "unique among the groups")
        let taken = try #require(capture(store, [CaptureApps.xcode], typedName: "Deep Work").createdGroup)
        #expect(taken.name == "Deep Work", "as typed, as renaming keeps it")
        #expect(store.groups.map(\.name) == ["Deep Work", "Xcode +1", "Xcode +1 2", "Deep Work"])
    }

    @Test func theWindowOptionIsTheIntentsWhenGivenAndTheRememberedOneOtherwise() throws {
        let remembered = CaptureSettings(order: .name, selectsOnlyAppsWithWindows: true)
        #expect(CaptureOutcome.settings(remembered, onlyAppsWithWindows: nil) == remembered)
        #expect(CaptureOutcome.settings(remembered, onlyAppsWithWindows: false) == CaptureSettings(order: .name, selectsOnlyAppsWithWindows: false))
        #expect(CaptureOutcome.settings(CaptureSettings(), onlyAppsWithWindows: true) == CaptureSettings(selectsOnlyAppsWithWindows: true))

        // Safari has no window: with the option it isn't added, without it it is.
        let windows = CaptureApps.windows(onScreen: [CaptureApps.xcode.processIdentifier, CaptureApps.terminal.processIdentifier])
        let apps = [CaptureApps.xcode, CaptureApps.safari, CaptureApps.terminal]
        let store = makeStore()
        let windowed = try #require(capture(store, apps, settings: CaptureOutcome.settings(CaptureSettings(), onlyAppsWithWindows: true), windows: windows).createdGroup)
        #expect(windowed.apps == [Self.xcodeItem, Self.terminalItem])
        let all = try #require(capture(store, apps, settings: CaptureOutcome.settings(remembered, onlyAppsWithWindows: false), windows: windows).createdGroup)
        #expect(all.apps == [Self.safariItem, Self.terminalItem, Self.xcodeItem], "the remembered order, by name")
    }

    @Test func atMostFiftyAppsAreCaptured() throws {
        let apps = (0..<60).map { CaptureApps.app("com.example.app\($0)", String(format: "App %02d", $0), pid: pid_t(5_000 + $0)) }
        let store = makeStore()
        let group = try #require(capture(store, apps, settings: CaptureSettings(order: .name)).createdGroup)
        #expect(group.apps.count == CapturePlan.maximumItems)
        #expect(group.apps.first?.name == "App 00" && group.apps.last?.name == "App 49")
    }

    @Test func withNothingToCaptureNoGroupIsMade() {
        let store = makeStore()
        for apps in [[], [Self.shortcuts], [Self.shortcuts, Self.finder, CaptureApps.mail]] {
            let outcome = capture(store, apps)
            #expect(outcome == .nothingToAdd(groupName: nil))
            #expect(outcome.createdGroup == nil)
            #expect(outcome.summary == "No open apps to put in a group.")
        }
        #expect(store.groups.isEmpty)
    }

    // MARK: - Add Open Apps to Group

    @Test func theAppsTheGroupDoesntHaveAreAddedAfterItsItems() throws {
        let store = makeStore()
        let coding = store.addGroup(named: "Coding", items: [Self.safariItem])
        let outcome = capture(store, [Self.shortcuts, CaptureApps.terminal, CaptureApps.safari, CaptureApps.mail, CaptureApps.xcode], into: .group(coding.id))

        #expect(outcome == .added(count: 2, groupName: "Coding"))
        #expect(outcome.createdGroup == nil)
        #expect(outcome.summary == "Added 2 apps to “Coding”.")
        #expect(store.group(withID: coding.id)?.apps == [Self.safariItem, Self.xcodeItem, Self.terminalItem])
        #expect(store.groups.count == 1, "no new group")
        #expect(store.group(withID: coding.id)?.name == "Coding", "a name is never applied to an existing group")
    }

    @Test func whenTheGroupHasEveryOpenAppNothingIsAdded() {
        let store = makeStore()
        let coding = store.addGroup(named: "Coding", items: [Self.xcodeItem, Self.safariItem])
        let outcome = capture(store, [Self.shortcuts, CaptureApps.safari, CaptureApps.xcode], into: .group(coding.id))
        #expect(outcome == .everyAppInGroup(groupName: "Coding"))
        #expect(outcome.summary == "Every open app is already in “Coding”.")
        #expect(store.group(withID: coding.id)?.apps == [Self.xcodeItem, Self.safariItem])
    }

    @Test func whenOnlyProtectedAppsAreLeftNothingIsAdded() {
        let store = makeStore()
        let coding = store.addGroup(named: "Coding", items: [Self.xcodeItem])
        let outcome = capture(store, [CaptureApps.xcode, CaptureApps.mail], into: .group(coding.id))
        #expect(outcome == .nothingToAdd(groupName: "Coding"))
        #expect(outcome.summary == "No open apps to add to “Coding”.")
        #expect(store.group(withID: coding.id)?.apps == [Self.xcodeItem])
    }

    @Test func anArchivedOrDeletedGroupIsLeftAsItIs() throws {
        let store = makeStore()
        let coding = store.addGroup(named: "Coding", items: [Self.safariItem])
        try #require(store.archiveGroup(coding.id) != nil)

        #expect(capture(store, [CaptureApps.xcode], into: .group(coding.id)) == .unavailableGroup)
        #expect(store.archivedGroup(withID: coding.id)?.group.apps == [Self.safariItem])
        #expect(capture(store, [CaptureApps.xcode], into: .group(UUID())) == .unavailableGroup)
        #expect(store.groups.isEmpty, "nothing is made instead")
        #expect(CaptureOutcome.unavailableGroup.summary == "The group is archived or was deleted. Nothing was added.")
    }

    // MARK: - Dialogs

    @Test func theDialogsCountTheApps() {
        let one = DockGroup(name: "Xcode", apps: [Self.xcodeItem])
        let four = DockGroup(name: "Xcode +3", apps: [Self.xcodeItem, Self.safariItem, Self.terminalItem, AppReference(bundleIdentifier: "com.apple.Music", name: "Music")])
        #expect(CaptureOutcome.created(one).summary == "Made “Xcode” with 1 app.")
        #expect(CaptureOutcome.created(four).summary == "Made “Xcode +3” with 4 apps.")
        #expect(CaptureOutcome.added(count: 1, groupName: "Coding").summary == "Added 1 app to “Coding”.")
        #expect(CaptureOutcome.added(count: 2, groupName: "Coding").summary == "Added 2 apps to “Coding”.")
        #expect(CaptureOutcome.created(four).createdGroup == four)
    }
}

/// The intents' wiring, read from the app's sources (the tests don't link the app target).
@Suite("Capture: the intents' wiring")
struct CaptureIntentWiringTests {
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: LocalizationTests.root.appending(path: "Sources/\(path)"), encoding: .utf8)
    }

    /// The `AppShortcut(...)` entries of `DockGroupsShortcuts`, one string each.
    private static func appShortcuts() throws -> [String] {
        let text = try source("CybokronDockGroups/Intents/DockGroupsShortcuts.swift")
        let parts = text.components(separatedBy: "\n        AppShortcut(\n").dropFirst()
        return parts.map { part in
            part.components(separatedBy: "\n        )\n").first ?? part
        }
    }

    /// Six of the ten App Shortcuts the system allows; Add Open Apps to Group has none (Decision 5).
    @Test func oneAppShortcutMakesAGroupFromTheOpenApps() throws {
        let shortcuts = try Self.appShortcuts()
        #expect(shortcuts.count == 6)
        #expect(shortcuts.count <= 10)
        let intents = shortcuts.compactMap { $0.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) }
        #expect(intents == [
            "intent: LaunchGroupIntent(),", "intent: QuitGroupIntent(),", "intent: ShowGroupIntent(),",
            "intent: StartGroupIntent(),", "intent: FinishGroupIntent(),", "intent: CaptureOpenAppsIntent(),",
        ])
        let text = try Self.source("CybokronDockGroups/Intents/DockGroupsShortcuts.swift")
        #expect(!text.contains("intent: AddOpenAppsIntent()"))
    }

    /// What Settings → Shortcuts & Siri shows is the App Shortcut's first phrase.
    @Test func theSettingsPhraseIsTheAppShortcutsFirstPhrase() throws {
        let capture = try #require(try Self.appShortcuts().first { $0.contains("intent: CaptureOpenAppsIntent()") })
        let phrases = capture.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("\"") }
        #expect(phrases == [
            "\"Capture my open apps in \\(.applicationName)\",",
            "\"Make a group from my open apps in \\(.applicationName)\",",
        ])
        let first = try #require(phrases.first)
        let spoken = first.dropFirst().dropLast(2).replacingOccurrences(of: "\\(.applicationName)", with: "Cybokron Dock Groups")
        let shown = GroupInvocations.capturePhrase(appName: "Cybokron Dock Groups")
        #expect(shown.text == spoken)
        #expect(shown.title == "New Group from Open Apps")
        #expect(capture.contains("shortTitle: \"New Group from Open Apps\""))

        let settings = try Self.source("CybokronDockGroups/Settings/ShortcutsSettingsView.swift")
        #expect(settings.contains("let capturePhrase = GroupInvocations.capturePhrase(appName: AppInfo.name)"))
    }

    /// Add Open Apps to Group finds its group as every group intent does — so an archived one gives
    /// the usual error — and New Group from Open Apps waits for the app as they do. Neither asks for
    /// confirmation: nothing is opened, hidden or quit.
    @Test func theIntentsResolveAsTheOthersAndAskNothing() throws {
        let intents = try Self.source("CybokronDockGroups/Intents/CaptureIntents.swift")
        #expect(intents.contains("struct CaptureOpenAppsIntent: AppIntent {"))
        #expect(intents.contains("struct AddOpenAppsIntent: AppIntent {"))
        #expect(intents.contains("static let title: LocalizedStringResource = \"New Group from Open Apps\""))
        #expect(intents.contains("static let title: LocalizedStringResource = \"Add Open Apps to Group\""))
        #expect(intents.contains("@Parameter(title: \"Name\""))
        #expect(intents.contains("var name: String?"))
        #expect(intents.contains("@Parameter(title: \"Group\", requestValueDialog: \"Which group?\")\n    var group: GroupEntity"))
        #expect(intents.components(separatedBy: "var onlyAppsWithWindows: Bool?").count == 3)
        #expect(intents.contains("ReturnsValue<GroupEntity?> & ProvidesDialog"), "the new group goes back to the shortcut")
        #expect(intents.contains("let handler = try GroupIntentSupport.readyHandler(for: \"New Group from Open Apps\")"))
        #expect(intents.contains("handler.captureNewGroup(named: name, onlyAppsWithWindows: onlyAppsWithWindows)"))
        #expect(intents.contains("let (handler, resolved) = try GroupIntentSupport.resolve(group, for: \"Add Open Apps to Group\")"))
        #expect(intents.contains("handler.captureOpenApps(into: resolved, onlyAppsWithWindows: onlyAppsWithWindows)"))
        for asking in ["IntentConfirming", "askFirst", "requestConfirmation", "openAppWhenRun", "requestValue("] {
            #expect(!intents.contains(asking), "CaptureIntents.swift uses \(asking)")
        }

        let support = try Self.source("CybokronDockGroups/Intents/GroupIntentSupport.swift")
        #expect(support.contains("throw GroupIntentError.groupArchived(name: archived.group.name)"))
        #expect(support.contains("let handler = try readyHandler(for: action)"))
        #expect(support.contains("guard let handler else {\n            logger.error(\"\\(action, privacy: .public): the app isn't ready\")\n            throw GroupIntentError.notReady"))
        #expect(support.contains("func captureNewGroup(named name: String?, onlyAppsWithWindows: Bool?) -> CaptureOutcome"))
        #expect(support.contains("func captureOpenApps(into group: DockGroup, onlyAppsWithWindows: Bool?) -> CaptureOutcome"))
    }

    /// The app captures without the sheet or the group window: it reads the open apps and adds them.
    @Test func theAppCapturesWithoutTheSheet() throws {
        let app = try Self.source("CybokronDockGroups/App/AppDelegate.swift")
        #expect(app.contains("capture.captureWithoutSheet(into: .newGroup, typedName: name, onlyAppsWithWindows: onlyAppsWithWindows)"))
        #expect(app.contains("capture.captureWithoutSheet(into: .group(group.id), typedName: nil, onlyAppsWithWindows: onlyAppsWithWindows)"))
        let start = try #require(app.range(of: "func captureNewGroup(named name: String?, onlyAppsWithWindows: Bool?) -> CaptureOutcome {")).lowerBound
        let rest = app[start...]
        let handling = String(rest[..<(rest.range(of: "\n// MARK:")?.lowerBound ?? rest.endIndex)])
        #expect(handling.contains("func captureOpenApps(into group: DockGroup, onlyAppsWithWindows: Bool?) -> CaptureOutcome {"))
        for name in ["beginCapture", "mainWindowController", "activate", "popupController"] {
            #expect(!handling.contains(name), "the intents' capture uses \(name)")
        }

        let controller = try Self.source("CybokronDockGroups/Capture/CaptureController.swift")
        #expect(controller.contains("let outcome = store.captureWithoutSheet(\n            snapshot(),"))
        #expect(controller.contains("settings: CaptureOutcome.settings(settings, onlyAppsWithWindows: onlyAppsWithWindows),"))

        let core = try Self.source("DockGroupsCore/Capture/CaptureOutcome.swift")
        #expect(core.contains("leavingOut: CaptureOutcome.leftOutApps"))
        #expect(core.contains("let items = plan.defaultItems"))
    }

    /// Like the sheet, the intents ask for no permission and never open, hide or quit anything.
    @Test func theIntentsAskForNoPermissionAndTouchNoApp() throws {
        let forbidden = [
            "AXIsProcessTrusted", "AXUIElement", "kAXTrustedCheckOptionPrompt", "AccessibilityAccess",
            "kCGWindowName", "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess", "ScreenCaptureKit",
            "NSAppleScript", "NSAppleEventDescriptor", "CGEventTapCreate", "addGlobalMonitorForEvents",
            "openApplication", "terminate(", "hide()", "launchApplication", ".activate(", "launchAll", "quitAll",
        ]
        for path in ["CybokronDockGroups/Intents/CaptureIntents.swift", "DockGroupsCore/Capture/CaptureOutcome.swift"] {
            let text = try Self.source(path)
            for name in forbidden {
                #expect(!text.contains(name), "\(path) uses \(name)")
            }
        }
    }
}
