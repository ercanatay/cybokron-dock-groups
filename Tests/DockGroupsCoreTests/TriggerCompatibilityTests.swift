import Foundation
import Testing
@testable import DockGroupsCore

/// Triggers add files of their own and nothing to the files 0.10.0 reads (spec TR-9, §2.8, §2.10).
@Suite("Triggers: files written by 0.10.0, agents and going back")
@MainActor
struct TriggerCompatibilityTests {
    private static func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    private static var triggers: [GroupTrigger] {
        let coding = Version0100Fixtures.stored.active[0]
        return [
            .at(9, 0, days: TriggerTime.weekdays, group: coding, runMode: .notice),
            .on(.condition(.wifi(WiFiNetworkName("Office")!), edge: .ends), group: coding, action: .finish),
        ]
    }

    private func temporaryFile(_ name: String, contents: String, in directory: TemporaryDirectory) throws -> URL {
        let url = directory.url.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func groupsAndPreferencesReadAndAreSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // Triggers saved next to them change nothing in them.
        try JSONFileTriggerPersistence(fileURL: directory.url.appending(path: "triggers.json")).saveTriggers(Self.triggers)

        let groupsURL = try temporaryFile("groups.json", contents: Version0100Fixtures.groupsFile, in: directory)
        let groups = JSONFileGroupPersistence(fileURL: groupsURL)
        let stored = try groups.loadStoredGroups()
        #expect(stored == Version0100Fixtures.stored)
        try groups.saveStoredGroups(stored)
        #expect(try String(contentsOf: groupsURL, encoding: .utf8) == Version0100Fixtures.groupsFile)

        for (file, expected) in [
            (Version0100Fixtures.preferencesFile, Version0100Fixtures.preferences),
            (Version0100Fixtures.defaultPreferencesFile, PopupPreferences()),
        ] {
            let url = try temporaryFile("preferences.json", contents: file, in: directory)
            let persistence = JSONFilePreferencesPersistence(fileURL: url)
            let preferences = try #require(try persistence.loadPreferences())
            #expect(preferences == expected)
            try persistence.savePreferences(preferences)
            #expect(try String(contentsOf: url, encoding: .utf8) == file)
        }
    }

    @Test func theStoresWriteWhat0100Wrote() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let groupsURL = try temporaryFile("groups.json", contents: Version0100Fixtures.groupsFile, in: directory)
        let preferencesURL = try temporaryFile("preferences.json", contents: Version0100Fixtures.preferencesFile, in: directory)
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .zero)
        let triggers = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: directory.url.appending(path: "triggers.json")), saveDelay: .zero)
        for trigger in Self.triggers {
            triggers.add(trigger)
        }
        triggers.pruneTriggers(for: groups)
        // A change saves the files (renaming back and forth ends where it began).
        let coding = Version0100Fixtures.stored.active[0]
        #expect(groups.renameGroup(coding.id, to: "Renamed"))
        #expect(groups.renameGroup(coding.id, to: coding.name))
        preferences.update { $0.showsTitles.toggle() }
        preferences.update { $0.showsTitles.toggle() }
        groups.flushPendingSave()
        preferences.flushPendingSave()
        #expect(try String(contentsOf: groupsURL, encoding: .utf8) == Version0100Fixtures.groupsFile)
        #expect(try String(contentsOf: preferencesURL, encoding: .utf8) == Version0100Fixtures.preferencesFile)
        #expect(triggers.triggers.count == 2)
    }

    @Test func agentConfigurationsDontChange() throws {
        let installed = try AgentConfiguration.decode(from: Data(Version0100Fixtures.agentConfiguration.utf8))
        let group = Version0100Fixtures.stored.active[0]
        let current = AgentConfiguration(group: group, preferences: Version0100Fixtures.preferences)
        #expect(installed == current)
        #expect(String(decoding: try current.encoded(), as: UTF8.self) == Version0100Fixtures.agentConfiguration)
    }

    @Test func aBackupWithoutTriggersIsByteForByteWhat0100Wrote() throws {
        let read = try SettingsBackup.decode(from: Data(Version0100Fixtures.backup.utf8))
        #expect(read.triggers.isEmpty)
        #expect(read.groups == Version0100Fixtures.backupValue.groups)
        #expect(String(decoding: try Version0100Fixtures.backupValue.encoded(), as: UTF8.self) == Version0100Fixtures.backup)
        #expect(String(decoding: try read.encoded(), as: UTF8.self) == Version0100Fixtures.backup)
    }

    /// 0.10.0 ignores the `triggers` key of a backup, as 0.8.0 ignores templates: everything else
    /// is the same backup.
    @Test func aBackupWithTriggersOnlyAddsTheTriggersKey() throws {
        var backup = Version0100Fixtures.backupValue
        backup.triggers = Self.triggers
        var object = try #require(try JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        #expect((object["triggers"] as? [Any])?.count == 2)
        object["triggers"] = nil
        let older = try #require(try JSONSerialization.jsonObject(with: Data(Version0100Fixtures.backup.utf8)) as? NSDictionary)
        #expect(NSDictionary(dictionary: object) == older)
    }

    // MARK: - Going back

    @Test func goingBackPastTriggersWarnsButCopiesNothingNew() throws {
        #expect(ReleaseHistory.firstTriggersVersion == Self.version("0.11.0"))
        #expect(ReleaseHistory.lacksTriggers(Self.version("0.10.0")))
        #expect(!ReleaseHistory.lacksTriggers(Self.version("0.11.0")))
        let back = (Self.version("0.10.0"), Self.version("0.11.0"))
        #expect(DowngradeProtection.appliesToTriggers(installing: back.0, over: back.1))
        #expect(!DowngradeProtection.appliesToTriggers(installing: Self.version("0.11.0"), over: Self.version("0.11.1")))
        #expect(!DowngradeProtection.appliesToTriggers(installing: Self.version("0.12.0"), over: Self.version("0.11.0")))
        #expect(DowngradeProtection.appliesToTriggers(installing: back.0, over: nil))

        #expect(!DowngradeProtection.warnsAboutTriggers(installing: back.0, over: back.1, enabledTriggerCount: 0, opensAtLogin: false))
        #expect(DowngradeProtection.warnsAboutTriggers(installing: back.0, over: back.1, enabledTriggerCount: 1, opensAtLogin: false))
        #expect(DowngradeProtection.warnsAboutTriggers(installing: back.0, over: back.1, enabledTriggerCount: 0, opensAtLogin: true))
        #expect(!DowngradeProtection.warnsAboutTriggers(installing: Self.version("0.11.0"), over: Self.version("0.11.1"), enabledTriggerCount: 3, opensAtLogin: true))
        #expect(DowngradeProtection.triggersWarning(installing: back.0, over: back.1, enabledTriggerCount: 2, opensAtLogin: true) == [
            "Version 0.10.0 doesn't run triggers. They're kept and run again after you update.",
            "Cybokron Dock Groups still opens at login; turn that off in System Settings → General → Login Items.",
        ])
        #expect(DowngradeProtection.triggersWarning(installing: back.0, over: back.1, enabledTriggerCount: 0, opensAtLogin: false).isEmpty)

        // The copies before going back are the groups and preferences files, as before: 0.10.0
        // never opens the triggers files, so they aren't copied.
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let groupsURL = try temporaryFile("groups.json", contents: Version0100Fixtures.groupsFile, in: directory)
        let preferencesURL = try temporaryFile("preferences.json", contents: Version0100Fixtures.preferencesFile, in: directory)
        try JSONFileTriggerPersistence(fileURL: directory.url.appending(path: "triggers.json")).saveTriggers(Self.triggers)
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .zero)
        #expect(try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: back.0, over: back.1).isEmpty)
        let toOld = try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.version("0.8.0"), over: back.1)
        #expect(toOld.map { $0.lastPathComponent.components(separatedBy: ".").first } == ["groups", "preferences"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(!names.contains { $0.hasPrefix("triggers.pre-downgrade") })
    }

    // MARK: - The automation trigger

    /// A trigger's Start never quits, and never asks: the previous group's apps are hidden instead
    /// (as a Focus's are), and the session says a trigger started it.
    @Test func anAutomaticStartHidesInsteadOfQuitting() async throws {
        let design = DockGroup.of("Design", ["com.figma.Desktop"])
        let coding = DockGroup.of("Coding", ["com.apple.dt.Xcode"], switching: GroupSwitching(onStart: .quitPreviousGroup, onFinish: .quitApps))
        let rig = SwitchingRig(groups: [design, coding], answer: .quit)
        rig.apps.run("com.figma.Desktop", name: "Figma")
        rig.apps.run("com.apple.dt.Xcode", name: "Xcode")
        _ = try await rig.switcher.start(design.id, trigger: .userAction)
        rig.clock.advance(10)

        let started = try await rig.switcher.start(coding.id, trigger: .automation)
        #expect(started.outcome == .done && !started.wasAsked)
        #expect(started.plan.quit.isEmpty)
        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "hide:") == ["com.figma.desktop"])
        #expect(rig.session.startTrigger == .automation)

        rig.clock.advance(10)
        let finished = try await rig.switcher.finish(coding.id, trigger: .automation)
        #expect(finished.plan.quit.isEmpty && !finished.wasAsked)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.transitionPrompt.asked.isEmpty)
    }

    @Test func diagnosticsCountTriggersAndSayNoNames() {
        let group = Version0100Fixtures.stored.active[0]
        var off = GroupTrigger.on(.condition(.display(.display(.monitor("Jane's LG UltraFine"))), edge: .starts), group: group)
        off.isEnabled = false
        let triggers = Self.triggers + [off]
        let info = DiagnosticsInfo(
            app: .init(version: "0.11.0", build: "1100", path: "/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "Version 27.0.1", hardwareModel: "Mac16,11", architecture: "arm64"),
            isAccessibilityTrusted: false,
            isStatusItemShown: true,
            preferences: PopupPreferences(),
            updates: .init(lastCheckDate: nil, lastResult: "never"),
            groups: [group],
            triggers: triggers,
            triggersPausedUntil: .distantFuture,
            recentErrors: [],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let text = DiagnosticsReport.text(for: info, homeDirectory: "/Users/jane")
        #expect(text.contains("Triggers: 3 (2 on; 1 display, 1 schedule, 1 wifi)"))
        #expect(text.contains("Triggers paused until: resumed"))
        for secret in ["Office", "UltraFine", "9:00", "540"] {
            #expect(!text.contains(secret), "\(secret) leaked into the report")
        }
        let none = DiagnosticsInfo(
            app: info.app, system: info.system, isAccessibilityTrusted: false, isStatusItemShown: true,
            preferences: PopupPreferences(), updates: info.updates, groups: [], recentErrors: []
        )
        #expect(DiagnosticsReport.text(for: none).contains("Triggers: none"))
    }
}
