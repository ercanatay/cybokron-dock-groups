import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: files written by 0.8.0")
@MainActor
struct Version080CompatibilityTests {
    private func temporaryFile(_ name: String, contents: String) throws -> (URL, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return (url, directory)
    }

    /// A JSON value with every `shortcut` key removed, at any depth.
    private func withoutShortcuts(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { $0.key != "shortcut" }.mapValues(withoutShortcuts)
        }
        if let array = value as? [Any] {
            return array.map(withoutShortcuts)
        }
        return value
    }

    private func json(_ text: String) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject)
    }

    @Test func groupsFileReadsAndIsSavedByteForByte() throws {
        let (url, directory) = try temporaryFile("groups.json", contents: Version080Fixtures.groupsFile)
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: url)

        let groups = try persistence.loadGroups()

        #expect(groups == [Version080Fixtures.codingGroup, Version080Fixtures.designGroup])
        #expect(groups.allSatisfy { $0.shortcut == nil })
        try persistence.saveGroups(groups)
        #expect(try String(contentsOf: url, encoding: .utf8) == Version080Fixtures.groupsFile)
    }

    @Test func preferencesFileReadsAndIsSavedByteForByte() throws {
        let (url, directory) = try temporaryFile("preferences.json", contents: Version080Fixtures.preferencesFile)
        defer { directory.remove() }
        let persistence = JSONFilePreferencesPersistence(fileURL: url)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences == Version080Fixtures.preferences)
        try persistence.savePreferences(preferences)
        #expect(try String(contentsOf: url, encoding: .utf8) == Version080Fixtures.preferencesFile)
    }

    @Test func agentConfigurationIsWhatThisVersionWritesWithOrWithoutAShortcut() throws {
        let installed = try AgentConfiguration.decode(from: Data(Version080Fixtures.agentConfiguration.utf8))
        for group in [Version080Fixtures.codingGroup, Version080Fixtures.groupsWithShortcuts[0]] {
            let current = AgentConfiguration(group: group, preferences: Version080Fixtures.preferences)
            // Equal values and equal bytes: updating, or giving the group a shortcut, doesn't rebuild the agent.
            #expect(installed == current)
            #expect(String(decoding: try current.encoded(), as: UTF8.self) == Version080Fixtures.agentConfiguration)
        }
    }

    @Test func backupImportsAsBefore() throws {
        let backup = try SettingsBackup.decode(from: Data(Version080Fixtures.backup.utf8))

        #expect(backup.groups == [Version080Fixtures.codingGroup, Version080Fixtures.designGroup])
        #expect(backup.preferences == Version080Fixtures.preferences)
        #expect(backup.leftOutItemCount == 0 && backup.resetLaunchOptionCount == 0)
        #expect(String(decoding: try backup.encoded(), as: UTF8.self) == Version080Fixtures.backup)
    }

    /// What this version writes once groups have shortcuts: the same files with a `shortcut` key
    /// per group, read back to the same groups. 0.8.0 read these files and saved them back as
    /// `groupsFile` and `backup` (see `Version080Fixtures`): the key is the only difference.
    @Test func groupsWithShortcutsAddOnlyTheShortcutKey() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "groups.json")
        let persistence = JSONFileGroupPersistence(fileURL: url)

        try persistence.saveGroups(Version080Fixtures.groupsWithShortcuts)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == Version080Fixtures.groupsFileWithShortcuts)
        #expect(try persistence.loadGroups() == Version080Fixtures.groupsWithShortcuts)
        #expect(withoutShortcuts(try json(written)) as? NSObject == (try json(Version080Fixtures.groupsFile)))
        #expect(GroupsDocument.currentFormatVersion == 1, "the format version stays")
    }

    @Test func backupsWithShortcutsAddOnlyTheShortcutKey() throws {
        let backup = SettingsBackup(
            appVersion: "0.9.0",
            exportedAt: Version080Fixtures.exportedAt,
            groups: Version080Fixtures.groupsWithShortcuts,
            preferences: Version080Fixtures.preferences
        )

        let written = String(decoding: try backup.encoded(), as: UTF8.self)

        #expect(written == Version080Fixtures.backupWithShortcuts)
        #expect(try SettingsBackup.decode(from: Data(written.utf8)).groups == Version080Fixtures.groupsWithShortcuts)
        let older = try json(Version080Fixtures.backup.replacingOccurrences(of: #""appVersion" : "0.8.0""#, with: #""appVersion" : "0.9.0""#))
        #expect(withoutShortcuts(try json(written)) as? NSObject == older)
        #expect(SettingsBackup.currentSchemaVersion == 1)
    }
}

/// A crafted `groups.json` or backup can't take keys typing and macOS need, can't make a key press
/// do something it couldn't, and can't make registering costly (spec §4.2).
@Suite("Group shortcuts: crafted files")
@MainActor
struct GroupShortcutCraftedFileTests {
    private static let numbers = NumberShortcutSettings(enabled: true, modifiers: .controlOption)

    private func groupsFile(_ groups: [String]) -> String {
        #"{ "formatVersion": 1, "groups": [ \#(groups.joined(separator: ", ")) ] }"#
    }

    private func group(_ number: Int, shortcut: String) -> String {
        #"{ "id": "\#(String(format: "00000000-0000-4000-8000-%012d", number))", "name": "Group \#(number)", "apps": [ { "bundleIdentifier": "com.apple.Terminal", "name": "Terminal" } ], "shortcut": \#(shortcut) }"#
    }

    private func load(_ text: String) throws -> [DockGroup] {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "groups.json")
        try Data(text.utf8).write(to: url)
        return try JSONFileGroupPersistence(fileURL: url).loadGroups()
    }

    @Test func everydayAndSystemKeysAreDroppedAndTheGroupsKept() throws {
        let hijacks = [
            #"{ "keyCode": 8, "modifiers": ["command"], "action": "startOrFinish" }"#,          // ⌘C
            #"{ "keyCode": 9, "modifiers": ["command"], "action": "openAll" }"#,                // ⌘V
            #"{ "keyCode": 12, "modifiers": ["command"], "action": "openAll" }"#,               // ⌘Q
            #"{ "keyCode": 48, "modifiers": ["command"], "action": "openAll" }"#,               // ⌘⇥
            #"{ "keyCode": 49, "modifiers": ["command"], "action": "openAll" }"#,               // ⌘Space
            #"{ "keyCode": 0, "modifiers": ["control"], "action": "openAll" }"#,                // ⌃A
            #"{ "keyCode": 14, "modifiers": ["option", "shift"], "action": "openAll" }"#,       // ⌥⇧E
            #"{ "keyCode": 12, "modifiers": ["control", "command"], "action": "openAll" }"#,    // ⌃⌘Q
            #"{ "keyCode": 53, "modifiers": ["option", "command"], "action": "openAll" }"#,     // ⌥⌘⎋
            #"{ "keyCode": 36, "modifiers": ["control", "option"], "action": "openAll" }"#,     // ⌃⌥↩
        ]
        let groups = try load(groupsFile(hijacks.enumerated().map { group($0.offset + 1, shortcut: $0.element) }))

        #expect(groups.count == hijacks.count, "every group loads")
        #expect(groups.allSatisfy { $0.shortcut == nil && $0.apps.count == 1 })
        let plan = GroupShortcutPlanner.plan(groups: groups, numbers: Self.numbers, system: [])
        #expect(plan.registrations.isEmpty, "nothing to register")
    }

    @Test func aBackupCantBringThemEither() throws {
        let backup = #"""
        { "schemaVersion": 1, "app": "cybokron-dock-groups", "appVersion": "9.9.9", "exportedAt": "2026-10-25T10:00:00Z",
          "groups": [ \#(group(1, shortcut: #"{ "keyCode": 8, "modifiers": ["command"], "action": "openAll" }"#)),
                      \#(group(2, shortcut: #"{ "keyCode": 8, "modifiers": ["control", "option"], "action": "openAll" }"#)) ],
          "preferences": { "formatVersion": 1 } }
        """#
        let decoded = try SettingsBackup.decode(from: Data(backup.utf8))
        #expect(decoded.groups.map(\.shortcut) == [nil, makeShortcut(kVK_ANSI_C, [.control, .option], .openAll)])
    }

    @Test func numberAndSystemKeysAreKeptButOff() throws {
        let groups = try load(groupsFile([
            group(1, shortcut: #"{ "keyCode": 20, "modifiers": ["control", "option"], "action": "startOrFinish" }"#),   // ⌃⌥3
            group(2, shortcut: #"{ "keyCode": 40, "modifiers": ["control", "option", "command"] }"#),                 // ⌃⌥⌘K
        ]))
        let system: Set<KeyCombination> = [combo(kVK_ANSI_K, [.control, .option, .command])]

        let plan = GroupShortcutPlanner.plan(groups: groups, numbers: Self.numbers, system: system)

        #expect(groups.allSatisfy { $0.shortcut != nil }, "the file isn't rewritten")
        #expect(plan.registrations.isEmpty)
        #expect(plan.statuses[groups[0].id] == .off(.numberShortcut(digit: 3)))
        #expect(plan.statuses[groups[1].id] == .off(.systemShortcut))
    }

    @Test func thousandsOfShortcutsRegisterAHundredAtMost() throws {
        // 2,000 groups, the same allowed keys over and over: one registration per distinct
        // combination, and never more than 100.
        let keyCodes = Array(GroupShortcut.allowedKeyCodes).sorted()
        let modifierSets = [["control", "option"], ["control", "command"], ["option", "command"], ["control", "option", "shift"]]
        let entries = (0..<2_000).map { index in
            let keyCode = keyCodes[index % keyCodes.count]
            let modifiers = modifierSets[(index / keyCodes.count) % modifierSets.count]
            let names = modifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            return group(index + 1, shortcut: #"{ "keyCode": \#(keyCode), "modifiers": [\#(names)], "action": "openAll" }"#)
        }
        let groups = try load(groupsFile(entries))
        #expect(groups.count == 2_000)

        let system = FakeHotKeys()
        let registrar = GroupHotKeyRegistrar(system: system)
        registrar.applyGroupShortcuts(GroupShortcutPlanner.plan(groups: groups, numbers: Self.numbers, system: []))

        #expect(system.registered.count == GroupShortcutPlanner.maximumRegistrations)
        #expect(system.calls.count == GroupShortcutPlanner.maximumRegistrations, "no more calls than registrations")
        #expect(registrar.groupStatuses.values.filter(\.isOn).count == GroupShortcutPlanner.maximumRegistrations)
        #expect(!registrar.groupStatuses.values.contains { if case .unavailable = $0 { return true } else { return false } })
    }

    /// Loading groups, planning and registering never act: only a press of a registered hot key does.
    @Test func noPressNoAction() throws {
        let groups = try load(groupsFile([
            group(1, shortcut: #"{ "keyCode": 8, "modifiers": ["control", "option"], "action": "startOrFinish" }"#),
        ]))
        let system = FakeHotKeys()
        let registrar = GroupHotKeyRegistrar(system: system)
        var actions: [GroupShortcutAction] = []
        registrar.onGroupShortcut = { _, action in actions.append(action) }

        registrar.apply(enabled: true, modifiers: .controlOption)
        registrar.applyGroupShortcuts(GroupShortcutPlanner.plan(groups: groups, numbers: Self.numbers, system: []))
        registrar.suspend()
        registrar.resume()

        #expect(actions.isEmpty)
        system.press(combo(kVK_ANSI_C, [.control, .option]))
        #expect(actions == [.startOrFinish])
    }
}
