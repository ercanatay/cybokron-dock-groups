import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Capture settings in preferences.json")
struct CaptureSettingsCodingTests {
    private func preferencesJSON(_ preferences: PopupPreferences) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(preferences)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> PopupPreferences {
        try JSONDecoder().decode(PopupPreferences.self, from: Data(json.utf8))
    }

    @Test func theDefaultsAreNotWritten() throws {
        #expect(CaptureSettings().isDefault)
        #expect(CaptureSettings() == CaptureSettings(order: .recentlyUsed, selectsOnlyAppsWithWindows: false))
        #expect(try preferencesJSON(PopupPreferences())["capture"] == nil)
    }

    @Test func otherSettingsAreWrittenWithBothValues() throws {
        for settings in [CaptureSettings(order: .name), CaptureSettings(selectsOnlyAppsWithWindows: true)] {
            var preferences = PopupPreferences()
            preferences.capture = settings
            let capture = try #require(try preferencesJSON(preferences)["capture"] as? [String: Any])
            #expect(capture["order"] as? String == settings.order.rawValue)
            #expect(capture["selectsOnlyAppsWithWindows"] as? Bool == settings.selectsOnlyAppsWithWindows)
            #expect(Set(capture.keys) == ["order", "selectsOnlyAppsWithWindows"])
            let decoded = try JSONDecoder().decode(PopupPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(decoded == preferences)
        }
    }

    /// §2.9's table. Whatever a file says, capture ends up with an order and a switch.
    @Test(arguments: [
        (#"{}"#, CaptureSettings()),
        (#"{"capture": "name"}"#, CaptureSettings()),
        (#"{"capture": ["name", true]}"#, CaptureSettings()),
        (#"{"capture": null}"#, CaptureSettings()),
        (#"{"capture": {}}"#, CaptureSettings()),
        (#"{"capture": {"order": "name"}}"#, CaptureSettings(order: .name)),
        (#"{"capture": {"order": "dockOrder", "selectsOnlyAppsWithWindows": true}}"#, CaptureSettings(selectsOnlyAppsWithWindows: true)),
        (#"{"capture": {"order": 7, "selectsOnlyAppsWithWindows": "yes"}}"#, CaptureSettings()),
        (#"{"capture": {"selectsOnlyAppsWithWindows": 1}}"#, CaptureSettings()),
        (#"{"capture": {"order": "NAME"}}"#, CaptureSettings()),
    ])
    func valuesAreReadLeniently(json: String, expected: CaptureSettings) throws {
        let preferences = try decode(json)
        #expect(preferences.capture == expected)
        // Nothing else of the preferences changes because of it.
        var others = preferences
        others.capture = CaptureSettings()
        #expect(others == PopupPreferences())
    }

    /// A crafted file can put anything next to the two values: none of it is kept, and nothing of
    /// it can name an app, a location or a command to run.
    @Test func aCraftedCaptureObjectKeepsOnlyTheOrderAndTheSwitch() throws {
        let json = #"""
        {"capture": {"order": "name", "selectsOnlyAppsWithWindows": true,
                     "apps": [{"bundleIdentifier": "/tmp/evil.command", "name": "Evil"}],
                     "path": "/bin/sh", "command": "rm -rf ~", "url": "https://example.com/x.app"}}
        """#
        let preferences = try decode(json)
        #expect(preferences.capture == CaptureSettings(order: .name, selectsOnlyAppsWithWindows: true))
        let written = try #require(try preferencesJSON(preferences)["capture"] as? [String: Any])
        #expect(Set(written.keys) == ["order", "selectsOnlyAppsWithWindows"])
        let text = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        for crafted in ["evil", "/bin/sh", "rm -rf", "example.com"] {
            #expect(!text.contains(crafted))
        }
    }

    @Test func backupsCarryTheSettingsAndReadThemLeniently() throws {
        var preferences = PopupPreferences()
        preferences.capture = CaptureSettings(order: .name, selectsOnlyAppsWithWindows: true)
        let backup = SettingsBackup(appVersion: "0.10.0", exportedAt: Date(timeIntervalSince1970: 1_793_300_000), groups: [], preferences: preferences)

        let read = try SettingsBackup.decode(from: backup.encoded())
        #expect(read.preferences.capture == preferences.capture)

        // A crafted backup's capture values fall back to the defaults; the backup still imports.
        var crafted = try #require(try JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        var craftedPreferences = try #require(crafted["preferences"] as? [String: Any])
        craftedPreferences["capture"] = ["order": ["/bin/sh"], "selectsOnlyAppsWithWindows": "always", "apps": ["com.evil"]] as [String: Any]
        crafted["preferences"] = craftedPreferences
        let craftedRead = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: crafted))
        #expect(craftedRead.preferences.capture == CaptureSettings())
        #expect(craftedRead.groups.isEmpty && craftedRead.leftOutItemCount == 0)
    }
}

@Suite("Capture: files written by 0.9.0")
@MainActor
struct Version090CaptureCompatibilityTests {
    private func temporaryFile(_ name: String, contents: String) throws -> (URL, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return (url, directory)
    }

    @Test(arguments: [
        (Version090PreferencesFixtures.preferencesFile, Version080Fixtures.preferences),
        (Version090PreferencesFixtures.defaultPreferencesFile, PopupPreferences()),
    ])
    func preferencesFilesReadAndAreSavedByteForByte(file: String, expected: PopupPreferences) throws {
        let (url, directory) = try temporaryFile("preferences.json", contents: file)
        defer { directory.remove() }
        let persistence = JSONFilePreferencesPersistence(fileURL: url)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences == expected)
        #expect(preferences.capture.isDefault)
        try persistence.savePreferences(preferences)
        #expect(try String(contentsOf: url, encoding: .utf8) == file)
    }

    /// What this version writes once the capture settings were changed: the same file with a
    /// `capture` key, read back to the same preferences. 0.9.0 read these files and saved them
    /// back as `preferencesFile` and `defaultPreferencesFile` (see `Version090PreferencesFixtures`).
    @Test(arguments: [
        (Version090PreferencesFixtures.preferencesFileWithCapture, Version090PreferencesFixtures.preferencesWithCapture, Version090PreferencesFixtures.preferencesFile),
        (Version090PreferencesFixtures.defaultPreferencesFileWithCapture, Version090PreferencesFixtures.defaultPreferencesWithCapture, Version090PreferencesFixtures.defaultPreferencesFile),
    ])
    func captureSettingsAddOnlyTheCaptureKey(file: String, expected: PopupPreferences, older: String) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "preferences.json")
        let persistence = JSONFilePreferencesPersistence(fileURL: url)

        try persistence.savePreferences(expected)

        #expect(try String(contentsOf: url, encoding: .utf8) == file)
        #expect(try persistence.loadPreferences() == expected)
        var withoutCapture = try #require(try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
        withoutCapture["capture"] = nil
        let olderObject = try #require(try JSONSerialization.jsonObject(with: Data(older.utf8)) as? NSDictionary)
        #expect(NSDictionary(dictionary: withoutCapture) == olderObject)
    }

    @Test func aCapturedGroupIsAnOrdinaryGroupInBothVersions() throws {
        let (url, directory) = try temporaryFile("groups.json", contents: Version090PreferencesFixtures.groupsFile)
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: url)

        let groups = try persistence.loadGroups()

        #expect(groups == [Version090PreferencesFixtures.capturedGroup])
        try persistence.saveGroups(groups)
        #expect(try String(contentsOf: url, encoding: .utf8) == Version090PreferencesFixtures.groupsFile)
    }

    /// Capturing makes the fixture's group from running apps: the store writes what 0.9.0 wrote.
    @Test func capturingMakesTheItemsAddAppsWouldMake() throws {
        let apps = [
            CaptureApps.app("com.apple.dt.Xcode", "Xcode", pid: 1),
            CaptureApps.app("com.apple.Safari", "Safari", pid: 2),
            CaptureApps.app(nil, "Old Tool", pid: 3, path: "/Applications/Games/Old Tool.app"),
            CaptureApps.app("com.example.Downloaded", "Downloaded", pid: 4, path: "/private/var/folders/xy/abc/T/AppTranslocation/0F1E2D3C/d/Downloaded.app"),
        ]
        var history = ActivationHistory()
        for identity in ["com.example.downloaded", "/applications/games/old tool.app", "com.apple.safari", "com.apple.dt.xcode"] {
            history.recordActivation(ofIdentity: identity)
        }
        let plan = CapturePlanner.plan(OpenAppsSnapshot(apps: apps, windows: nil, history: history), settings: CaptureSettings(), target: .newGroup)
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let name = CapturePlanner.suggestedName(for: plan.defaultItems, taken: store.takenNames)

        let group = store.addGroup(named: name, items: plan.defaultItems)

        let fixture = Version090PreferencesFixtures.capturedGroup
        #expect(group.name == fixture.name)
        #expect(group.apps == fixture.apps)
        #expect(!group.isStandalone && group.shortcut == nil && group.freeLayoutSlots.isEmpty)
    }

    /// Changing the capture settings rebuilds no standalone group's app: its configuration stays
    /// what 0.9.0 wrote.
    @Test func agentConfigurationsDontCarryTheCaptureSettings() throws {
        let installed = try AgentConfiguration.decode(from: Data(Version090PreferencesFixtures.agentConfiguration.utf8))
        let group = Version090PreferencesFixtures.capturedGroup
        for preferences in [Version080Fixtures.preferences, Version090PreferencesFixtures.preferencesWithCapture] {
            let current = AgentConfiguration(group: group, preferences: preferences)
            #expect(installed == current)
            #expect(current.preferences.capture.isDefault)
            #expect(String(decoding: try current.encoded(), as: UTF8.self) == Version090PreferencesFixtures.agentConfiguration)
        }
    }

    @Test func aCaptureSettingsChangeDoesntMakeAnAgentOutdated() {
        let group = Version090PreferencesFixtures.capturedGroup
        func desired(_ preferences: PopupPreferences) -> DesiredAgent {
            DesiredAgent(
                configuration: AgentConfiguration(group: group, preferences: preferences),
                folderName: AgentIdentity.folderNames(for: [group])[group.id]!,
                sourceDigest: "digest"
            )
        }
        let before = desired(Version080Fixtures.preferences)
        let installed = InstalledAgent(
            bundleURL: URL(fileURLWithPath: "/tmp/Agents/\(before.folderName)", isDirectory: true),
            bundleIdentifier: before.bundleIdentifier,
            configuration: before.configuration,
            sourceDigest: before.sourceDigest
        )
        let plan = AgentPlanner.plan(desired: [desired(Version090PreferencesFixtures.preferencesWithCapture)], installed: [installed], runningBundleIdentifiers: [])
        #expect(plan.isEmpty)
    }
}

@Suite("Capture: diagnostics")
struct CaptureDiagnosticsTests {
    private func report(_ capture: CaptureSettings) -> String {
        var preferences = PopupPreferences()
        preferences.capture = capture
        let info = DiagnosticsInfo(
            app: .init(version: "0.10.0", build: "1000", path: "/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "Version 26.0", hardwareModel: "Mac15,6", architecture: "arm64"),
            isAccessibilityTrusted: false,
            isStatusItemShown: true,
            preferences: preferences,
            updates: .init(lastCheckDate: nil, lastResult: "Not checked"),
            groups: [DockGroup(name: "Xcode +3", apps: [AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")])],
            recentErrors: []
        )
        return DiagnosticsReport.text(for: info, homeDirectory: "/Users/jane")
    }

    @Test func theReportHasTheTwoSettingsOnly() {
        #expect(report(CaptureSettings()).contains("Capture: order recentlyUsed, windowed-only off\n"))
        let changed = report(CaptureSettings(order: .name, selectsOnlyAppsWithWindows: true))
        #expect(changed.contains("Capture: order name, windowed-only on\n"))
        // No app names or identifiers from the group's items.
        #expect(!changed.contains("com.apple.dt.Xcode"))
    }
}
