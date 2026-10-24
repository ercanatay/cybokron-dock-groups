import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: Start and Finish settings")
@MainActor
struct GroupSwitchingTests {
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func defaultsHideAndNeverQuit() {
        let settings = GroupSwitching()
        #expect(settings.onStart == .hidePreviousGroup)
        #expect(settings.onFinish == .hideApps)
        #expect(settings.afterFinish == .showPreviousGroup)
        #expect(settings.isDefault)
        #expect(!settings.quitsApps)
        #expect(DockGroup(name: "Work").switching == settings)
    }

    @Test func automaticTriggersQuitNothing() {
        let quitting = GroupSwitching(onStart: .quitPreviousGroup, onFinish: .quitApps, afterFinish: .nothing)
        #expect(quitting.quitsApps)
        #expect(quitting.withoutQuitting == GroupSwitching(onStart: .hidePreviousGroup, onFinish: .hideApps, afterFinish: .nothing))
        #expect(!quitting.withoutQuitting.quitsApps)
        let others = GroupSwitching(onStart: .hideAllOtherApps, onFinish: .leaveApps)
        #expect(others.withoutQuitting == others)
    }

    @Test func aGroupWritesItsSettingsOnlyWhenTheyArentTheDefaults() throws {
        #expect(try object(DockGroup(name: "Work"))["switching"] == nil)
        let group = DockGroup(name: "Coding", switching: GroupSwitching(onStart: .quitPreviousGroup, onFinish: .hideApps, afterFinish: .nothing))
        let saved = try #require(try object(group)["switching"] as? [String: String])
        #expect(saved == ["onStart": "quitPreviousGroup", "onFinish": "hideApps", "afterFinish": "nothing"])
        #expect(try JSONDecoder().decode(DockGroup.self, from: JSONEncoder().encode(group)) == group)
    }

    @Test func unreadableSettingsFallBackOneByOne() throws {
        let json = """
        { "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Coding",
          "switching": { "onStart": "teleport", "onFinish": "quitApps", "afterFinish": 7, "later": true } }
        """
        let group = try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        #expect(group.switching == GroupSwitching(onFinish: .quitApps))

        for value in [#""switching": 42"#, #""switching": "fast""#, #""switching": []"#] {
            let broken = #"{ "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Coding", \#(value) }"#
            #expect(try JSONDecoder().decode(DockGroup.self, from: Data(broken.utf8)).switching == GroupSwitching())
        }
    }

    @Test func groupsKeepTheirSettingsThroughEditsAndBackups() throws {
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
        let group = store.addGroup(named: "Coding")
        store.updateGroup(group.id) { $0.switching.onFinish = .quitApps }
        #expect(store.group(withID: group.id)?.switching.onFinish == .quitApps)

        let backup = SettingsBackup(appVersion: "0.8.0", groups: store.groups, preferences: PopupPreferences())
        let restored = try SettingsBackup.decode(from: backup.encoded())
        #expect(restored.groups.first?.switching.onFinish == .quitApps)
    }
}

@Suite("Switching: protected apps")
struct ProtectedAppsTests {
    private static let music = AppReference(bundleIdentifier: "com.apple.Music", name: "Music")
    private static let tool = AppReference(bundleIdentifier: "/Users/me/Tools/Builder.app", name: "Builder", path: "/Users/me/Tools/Builder.app")

    @Test func keepsAppsOnlyOnceAndAtMostFifty() {
        let website = AppReference(websiteURL: URL(string: "https://github.com")!)
        let file = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.pdf"), kind: .file)
        var detailed = Self.music
        detailed.details = ItemDetails(alias: "Tunes")
        let script = AppReference(bundleIdentifier: "/tmp/run.command", name: "Run")
        let unreadable = AppReference(bundleIdentifier: "file:///Users/me/a.pdf", name: "Broken")
        let withScriptPath = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail", path: "/tmp/run.command")

        let protected = ProtectedApps([detailed, website, file, AppReference(bundleIdentifier: "COM.APPLE.MUSIC", name: "Music"), script, unreadable, Self.tool, withScriptPath])

        #expect(protected.apps.map(\.bundleIdentifier) == ["com.apple.Music", "/Users/me/Tools/Builder.app", "com.apple.mail"])
        #expect(protected.apps[0].details.isEmpty, "details aren't kept")
        #expect(protected.apps[1].path == "/Users/me/Tools/Builder.app")
        #expect(protected.apps[2].path == nil, "a location that isn't an app bundle is dropped")

        let many = ProtectedApps((1...60).map { AppReference(bundleIdentifier: "com.example.app\($0)", name: "App \($0)") })
        #expect(many.apps.count == ProtectedApps.maximumCount)
        #expect(many.apps.last?.bundleIdentifier == "com.example.app50")
    }

    @Test func listedAppsAreProtectedFromHidingAndQuitting() {
        let protected = ProtectedApps([Self.music, Self.tool])
        for action in [ProtectedApps.Action.hiding, .quitting] {
            #expect(protected.reason(forIdentity: "com.apple.music", action: action) == .listed)
            #expect(protected.reason(forIdentity: Self.tool.normalizedBundleIdentifier, action: action) == .listed)
            #expect(protected.reason(forIdentity: "com.apple.safari", action: action) == nil)
        }
        #expect(protected.lists(identity: "COM.apple.Music"))
        #expect(protected.protects(RunningAppSnapshot(processIdentifier: 5, identity: "com.apple.Music", name: "Music"), from: .quitting))
    }

    @Test func thisAppItsGroupsAppsAndFinderAreAlwaysProtected() {
        let none = ProtectedApps()
        let agent = AgentIdentity.bundleIdentifier(for: UUID())
        for action in [ProtectedApps.Action.hiding, .quitting] {
            #expect(none.reason(forIdentity: "com.cybokron.dockgroups", action: action) == .always)
            #expect(none.reason(forIdentity: agent, action: action) == .always)
            #expect(none.reason(forIdentity: agent.lowercased(), action: action) == .always)
        }
        // Finder is never quit, but may be hidden.
        #expect(none.reason(forIdentity: "com.apple.finder", action: .quitting) == .always)
        #expect(none.reason(forIdentity: "com.apple.Finder", action: .hiding) == nil)
        // Only the app itself, not apps whose identifiers start like it.
        #expect(none.reason(forIdentity: "com.cybokron.dockgroupsx", action: .quitting) == nil)
    }

    @Test func aStandaloneGroupKeepsOnlyItsOwnProtectedApps() {
        let protected = ProtectedApps([Self.music, Self.tool, AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
        let group = DockGroup(name: "Work", apps: [
            AppReference(bundleIdentifier: "com.apple.MAIL", name: "Mail"),
            AppReference(websiteURL: URL(string: "https://music.apple.com")!),
            Self.tool,
        ])
        #expect(protected.restricted(to: group).apps.map(\.bundleIdentifier) == ["/Users/me/Tools/Builder.app", "com.apple.mail"])
        #expect(protected.restricted(to: DockGroup(name: "Empty")).isEmpty)
    }

    @Test func readsElementByElement() throws {
        let json = """
        [ { "bundleIdentifier": "com.apple.Music", "name": "Music" }, 42, { "name": "No identifier" },
          { "bundleIdentifier": "https://github.com", "name": "Web" }, "text",
          { "bundleIdentifier": "com.apple.mail", "name": "Mail", "alias": "Inbox" } ]
        """
        let protected = try JSONDecoder().decode(ProtectedApps.self, from: Data(json.utf8))
        #expect(protected.apps.map(\.bundleIdentifier) == ["com.apple.Music", "com.apple.mail"])
        #expect(try JSONDecoder().decode(ProtectedApps.self, from: JSONEncoder().encode(protected)) == protected)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(protected)) as? [[String: String]])
        #expect(saved == [["bundleIdentifier": "com.apple.Music", "name": "Music"], ["bundleIdentifier": "com.apple.mail", "name": "Mail"]])
    }

    @Test func preferencesWriteTheListOnlyWhenItHasApps() throws {
        let empty = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PopupPreferences())) as? [String: Any])
        #expect(empty["protectedApps"] == nil)

        let preferences = PopupPreferences(theme: .light, protectedApps: ProtectedApps([Self.music]))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect((saved["protectedApps"] as? [[String: String]])?.first?["bundleIdentifier"] == "com.apple.Music")
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }

    @Test func unreadableListsFallBackToNone() throws {
        for value in ["42", #""Music""#, #"{ "bundleIdentifier": "com.apple.Music" }"#] {
            let json = #"{ "panelTheme": "light", "protectedApps": \#(value) }"#
            let preferences = try JSONDecoder().decode(PopupPreferences.self, from: Data(json.utf8))
            #expect(preferences.protectedApps.isEmpty)
            #expect(preferences.theme == .light, "other settings are kept")
        }
    }

    @Test func backupsCarryTheList() throws {
        let preferences = PopupPreferences(protectedApps: ProtectedApps([Self.music, Self.tool]))
        let backup = SettingsBackup(appVersion: "0.8.0", groups: [], preferences: preferences)
        #expect(try SettingsBackup.decode(from: backup.encoded()).preferences.protectedApps == preferences.protectedApps)
    }
}

@Suite("Switching: files written by 0.7.0")
@MainActor
struct Version070CompatibilityTests {
    @Test func groupsFileReadsAndIsSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        try Data(Version070Fixtures.groupsFile.utf8).write(to: fileURL)
        let persistence = JSONFileGroupPersistence(fileURL: fileURL)

        let groups = try persistence.loadGroups()

        #expect(groups == [Version070Fixtures.codingGroup, Version070Fixtures.designGroup])
        #expect(groups.allSatisfy { $0.switching.isDefault })
        try persistence.saveGroups(groups)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == Version070Fixtures.groupsFile)
    }

    @Test func preferencesFileReadsAndIsSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "preferences.json")
        try Data(Version070Fixtures.preferencesFile.utf8).write(to: fileURL)
        let persistence = JSONFilePreferencesPersistence(fileURL: fileURL)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences == Version070Fixtures.preferences)
        #expect(preferences.protectedApps.isEmpty)
        try persistence.savePreferences(preferences)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == Version070Fixtures.preferencesFile)
    }

    @Test func agentConfigurationIsWhatThisVersionWrites() throws {
        let installed = try AgentConfiguration.decode(from: Data(Version070Fixtures.agentConfiguration.utf8))
        let current = AgentConfiguration(group: Version070Fixtures.codingGroup, preferences: Version070Fixtures.preferences)

        // Equal values and equal bytes: updating doesn't rebuild the agent as `outdated`.
        #expect(installed == current)
        #expect(String(decoding: try current.encoded(), as: UTF8.self) == Version070Fixtures.agentConfiguration)
    }

    @Test func backupImportsAsBefore() throws {
        let backup = try SettingsBackup.decode(from: Data(Version070Fixtures.backup.utf8))

        #expect(backup.groups == [Version070Fixtures.codingGroup, Version070Fixtures.designGroup])
        #expect(backup.preferences == Version070Fixtures.preferences)
        #expect(backup.schemaVersion == 1)
        #expect(backup.leftOutItemCount == 0)
        #expect(String(decoding: try backup.encoded(), as: UTF8.self) == Version070Fixtures.backup)
    }

    @Test func formatVersionsStayAtOne() throws {
        let group = DockGroup(name: "Coding", switching: GroupSwitching(onFinish: .quitApps))
        let preferences = PopupPreferences(protectedApps: ProtectedApps([AppReference(bundleIdentifier: "com.apple.Music", name: "Music")]))
        let backup = try #require(try JSONSerialization.jsonObject(with: SettingsBackup(appVersion: "0.8.0", groups: [group], preferences: preferences).encoded()) as? [String: Any])
        #expect(backup["schemaVersion"] as? Int == 1)
        #expect((backup["preferences"] as? [String: Any])?["formatVersion"] as? Int == 1)
        let configuration = try #require(try JSONSerialization.jsonObject(with: AgentConfiguration(group: group, preferences: preferences).encoded()) as? [String: Any])
        #expect(configuration["formatVersion"] as? Int == 1)
        #expect(GroupsDocument.currentFormatVersion == 1)
    }
}

@Suite("Switching: standalone groups' configurations")
struct SwitchingAgentConfigurationTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let music = AppReference(bundleIdentifier: "com.apple.Music", name: "Music")
    private static let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")

    private let group = DockGroup(name: "Work", apps: [mail, slack], isStandalone: true)

    @Test func agentsDontStartOrFinishAndKeepOnlyTheirOwnProtectedApps() {
        var group = group
        group.switching = GroupSwitching(onStart: .quitPreviousGroup, onFinish: .quitApps)
        let preferences = PopupPreferences(protectedApps: ProtectedApps([Self.music, Self.slack]))

        let configuration = AgentConfiguration(group: group, preferences: preferences)

        #expect(configuration.group.switching.isDefault)
        #expect(configuration.group.apps == group.apps)
        #expect(configuration.preferences.protectedApps.apps == [Self.slack])
    }

    @Test func unrelatedChangesDontRebuildTheAgent() throws {
        let base = AgentConfiguration(group: group, preferences: PopupPreferences(protectedApps: ProtectedApps([Self.slack])))
        var started = group
        started.switching.onStart = .hideAllOtherApps
        let others = [
            AgentConfiguration(group: started, preferences: PopupPreferences(protectedApps: ProtectedApps([Self.slack]))),
            AgentConfiguration(group: group, preferences: PopupPreferences(protectedApps: ProtectedApps([Self.music, Self.slack]))),
        ]
        for other in others {
            #expect(other == base)
            #expect(try other.encoded() == base.encoded())
            let desired = DesiredAgent(configuration: other, folderName: "work.app", sourceDigest: "d")
            let installed = InstalledAgent(bundleURL: URL(fileURLWithPath: "/tmp/Agents/work.app"), bundleIdentifier: desired.bundleIdentifier, configuration: base, sourceDigest: "d")
            #expect(AgentPlanner.plan(desired: [desired], installed: [installed], runningBundleIdentifiers: []).isEmpty)
        }
        // Protecting one of the group's own apps does change it: its Close All needs to know.
        let unprotected = AgentConfiguration(group: group, preferences: PopupPreferences())
        #expect(unprotected != base)
    }
}
