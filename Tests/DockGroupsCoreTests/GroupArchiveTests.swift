import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Archive: the store")
@MainActor
struct GroupArchiveStoreTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let date = Date(timeIntervalSince1970: 1_793_200_000.75)

    @Test func archivingMovesTheGroupOutOfTheListAndSavesOnce() throws {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        store.addItems([Self.mail], toGroup: work.id)
        let saves = persistence.saveCount

        let archived = try #require(store.archiveGroup(work.id, at: Self.date))

        #expect(store.groups.map(\.id) == [home.id])
        #expect(store.group(withID: work.id) == nil, "never found as a group")
        #expect(store.archivedGroups == [archived])
        #expect(store.archivedGroup(withID: work.id)?.group.apps == [Self.mail])
        #expect(archived.archivedAt == Date(timeIntervalSince1970: 1_793_200_000), "whole seconds")
        #expect(persistence.saveCount == saves + 1)
        #expect(persistence.saved.archived == [archived] && persistence.saved.active.map(\.id) == [home.id])
        #expect(store.archiveGroup(work.id) == nil, "already archived")
        #expect(store.archiveGroup(UUID()) == nil)
    }

    @Test func aStandaloneGroupIsArchivedWithStandaloneOffAndRestoredAsItWas() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.updateGroup(work.id) { $0.isStandalone = true }

        let archived = try #require(store.archiveGroup(work.id))

        #expect(!archived.group.isStandalone, "no standalone group without its Dock tile")
        #expect(archived.restoresStandalone)
        let restored = try #require(store.restoreGroup(work.id))
        #expect(restored.restoresStandalone, "the app turns Standalone on again")
        #expect(!restored.group.isStandalone, "after its Dock tile is added, not by the store")
        #expect(store.group(withID: work.id)?.isStandalone == false)
    }

    @Test func restoringPutsTheGroupBackAtTheEndWithItsSettings() throws {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.addGroup(named: "Home")
        store.addItems([Self.mail], toGroup: work.id)
        store.updateGroup(work.id) { $0.switching.onStart = .hideAllOtherApps }
        store.setShortcut(makeShortcut(kVK_ANSI_W, [.control, .option], .openAll), forGroup: work.id)
        let before = try #require(store.group(withID: work.id))
        store.archiveGroup(work.id)
        let saves = persistence.saveCount

        let result = try #require(store.restoreGroup(work.id))

        #expect(result.group == before)
        #expect(result.removedShortcut == nil && result.shortcutOwner == nil && !result.restoresStandalone)
        #expect(store.groups.map(\.name) == ["Home", "Work"], "at the end of the list")
        #expect(store.archivedGroups.isEmpty)
        #expect(persistence.saveCount == saves + 1)
        #expect(store.restoreGroup(work.id) == nil)
    }

    @Test func aRestoredGroupLosesAShortcutAnotherGroupTookMeanwhile() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let keys = makeShortcut(kVK_ANSI_W, [.control, .option])
        store.setShortcut(keys, forGroup: work.id)
        store.archiveGroup(work.id)
        // Archived groups hold no keys: another group may take them.
        let home = store.addGroup(named: "Home")
        #expect(store.setShortcut(makeShortcut(kVK_ANSI_W, [.control, .option], .startOrFinish), forGroup: home.id) == .assigned)

        let result = try #require(store.restoreGroup(work.id))

        #expect(result.removedShortcut == keys)
        #expect(result.shortcutOwner == home.id)
        #expect(store.group(withID: work.id)?.shortcut == nil)
        #expect(store.group(withID: home.id)?.shortcut?.action == .startOrFinish)
        #expect(result.removedShortcutTitle == "“Work” is back without its keyboard shortcut")
        #expect(result.removedShortcutMessage(ownerName: "Home", keyTitle: keys.keys.title)
            == "“Home” uses ⌃⌥W now. Choose another shortcut in “Work”'s settings.")
    }

    @Test func archivedGroupsCantBeEdited() throws {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.addGroup(named: "Home")
        store.archiveGroup(work.id)
        let saves = persistence.saveCount
        let archived = store.archivedGroups

        store.updateGroup(work.id) { $0.name = "Changed" }
        #expect(!store.renameGroup(work.id, to: "Changed"))
        #expect(store.addItems([Self.mail], toGroup: work.id) == 0)
        #expect(store.setShortcut(makeShortcut(kVK_ANSI_K, [.control, .option]), forGroup: work.id) == .unknownGroup)
        #expect(store.duplicateGroup(work.id) == nil)
        store.removeApp(bundleIdentifier: "com.apple.mail", fromGroup: work.id)

        #expect(store.archivedGroups == archived)
        #expect(persistence.saveCount == saves, "nothing saved")
    }

    @Test func deletingRemovesActiveOrArchivedGroups() {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        store.archiveGroup(work.id)

        #expect(store.deleteArchivedGroup(work.id))
        #expect(!store.deleteArchivedGroup(work.id))
        #expect(!store.deleteArchivedGroup(home.id), "only archived groups")
        #expect(store.archivedGroups.isEmpty && store.groups.map(\.id) == [home.id])

        let other = store.addGroup(named: "Other")
        store.archiveGroup(other.id)
        store.deleteGroup(other.id)
        store.deleteGroup(home.id)
        #expect(store.archivedGroups.isEmpty && store.groups.isEmpty)
        #expect(persistence.saved == StoredGroups())
    }

    @Test func archivedGroupsAreLoadedAgain() throws {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.addGroup(named: "Home")
        store.archiveGroup(work.id, at: Self.date)

        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)

        #expect(reloaded.groups == store.groups)
        #expect(reloaded.archivedGroups == store.archivedGroups)
    }

    @Test func shortcutsOfArchivedGroupsAreNeverPlanned() {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.setShortcut(makeShortcut(kVK_ANSI_W, [.control, .option]), forGroup: work.id)
        store.archiveGroup(work.id)

        let plan = GroupShortcutPlanner.plan(groups: store.groups, numbers: .off, system: [])

        #expect(plan == .empty)
        #expect(store.archivedGroups.first?.group.shortcut != nil, "kept for a restore")
    }

    /// The current group, archived, is no longer current; its delayed items find no group.
    @Test func archivingTheCurrentGroupEndsItsSession() async throws {
        let rig = SwitchingRig(groups: [DockGroup.of("Design", ["com.figma.Desktop"]), DockGroup.of("Coding", ["com.apple.dt.Xcode"])])
        let coding = rig.store.groups[1]
        _ = try await rig.switcher.start(coding.id, trigger: .userAction)
        #expect(rig.session.current == coding.id)

        rig.store.archiveGroup(coding.id)

        #expect(rig.session.current == nil)
        #expect(rig.store.group(withID: coding.id) == nil)
        // The rig's persistence only knows active groups: it refuses to save the archived one
        // rather than drop it, and the store says so.
        #expect(rig.store.issue?.message == "The archived groups can't be saved here.")
    }
}

@Suite("Archive: the groups file")
@MainActor
struct GroupArchiveFileTests {
    private func write(_ text: String) throws -> (JSONFileGroupPersistence, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "groups.json")
        try Data(text.utf8).write(to: url)
        return (JSONFileGroupPersistence(fileURL: url), directory)
    }

    private func json(_ text: String) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject)
    }

    /// The JSON with the archive marks and the shortcuts — what 0.8.0 doesn't know — removed.
    private func withoutNewKeys(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            let unknown: Set<String> = ["archived", "archivedAt", "restoresStandalone", "shortcut"]
            return object.filter { !unknown.contains($0.key) }.mapValues(withoutNewKeys)
        }
        if let array = value as? [Any] { return array.map(withoutNewKeys) }
        return value
    }

    @Test func archivedGroupsAreWrittenAfterTheActiveOnesWithTheirMarks() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "groups.json")
        let persistence = JSONFileGroupPersistence(fileURL: url)

        try persistence.saveStoredGroups(Version090ArchiveFixtures.stored)

        #expect(try String(contentsOf: url, encoding: .utf8) == Version090ArchiveFixtures.groupsFile)
        #expect(try persistence.loadStoredGroups() == Version090ArchiveFixtures.stored)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 1, "the format version stays")
        let entries = try #require(object["groups"] as? [[String: Any]])
        #expect(entries.map { $0["name"] as? String } == ["Design", "Coding"])
        #expect(entries[0]["archived"] == nil)
        #expect(entries[1]["archived"] as? Bool == true)
        #expect(entries[1]["archivedAt"] as? String == "2026-10-28T15:06:40Z")
        #expect(entries[1]["restoresStandalone"] as? Bool == true)
        #expect(entries[1]["isStandalone"] as? Bool == false)
    }

    @Test func activeGroupsAloneAreWhatSiriAndShortcutsReadBeforeTheAppIsReady() throws {
        let (persistence, directory) = try write(Version090ArchiveFixtures.groupsFile)
        defer { directory.remove() }

        #expect(try persistence.loadGroups().map(\.name) == ["Design"])
    }

    /// Two ways: 0.8.0 read this version's file as two ordinary groups and dropped only what it
    /// doesn't know when saving it (`Version090ArchiveFixtures`); this version reads that file back.
    @Test func version080ReadsArchivedGroupsAsOrdinaryGroups() throws {
        #expect(withoutNewKeys(try json(Version090ArchiveFixtures.groupsFile)) as? NSObject == (try json(Version090ArchiveFixtures.groupsFileSavedBy080)))

        let (persistence, directory) = try write(Version090ArchiveFixtures.groupsFileSavedBy080)
        defer { directory.remove() }
        let stored = try persistence.loadStoredGroups()

        var coding = Version080Fixtures.codingGroup
        coding.isStandalone = false
        #expect(stored.active == [Version080Fixtures.designGroup, coding], "active again, without shortcuts")
        #expect(stored.archived.isEmpty)
    }

    @Test func entriesMayComeInAnyOrder() throws {
        let file = #"""
        { "formatVersion": 1, "groups": [
          { "id": "00000000-0000-4000-8000-000000000001", "name": "Old", "archived": true },
          { "id": "00000000-0000-4000-8000-000000000002", "name": "Work" },
          { "id": "00000000-0000-4000-8000-000000000003", "name": "Older", "archived": true, "archivedAt": "2026-10-01T08:00:00Z" },
          { "id": "00000000-0000-4000-8000-000000000004", "name": "Home" } ] }
        """#
        let (persistence, directory) = try write(file)
        defer { directory.remove() }

        let stored = try persistence.loadStoredGroups()
        #expect(stored.active.map(\.name) == ["Work", "Home"])
        #expect(stored.archived.map(\.group.name) == ["Old", "Older"])
        #expect(stored.archived[0].archivedAt == nil)
        #expect(stored.archived[1].archivedAt == Date(timeIntervalSince1970: 1_790_841_600))

        try persistence.saveStoredGroups(stored)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appending(path: "groups.json"))) as? [String: Any])
        #expect((written["groups"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Work", "Home", "Old", "Older"], "active first")
    }

    /// Only `"archived": true` hides a group: damaged data can only make one visible.
    @Test(arguments: [#""archived": false"#, #""archived": "true""#, #""archived": 1"#, #""archived": null"#, #""archived": {}"#, #""archivedAt": "2026-10-01T08:00:00Z""#])
    func anythingButTrueIsActive(mark: String) throws {
        let (persistence, directory) = try write(#"{ "formatVersion": 1, "groups": [ { "id": "00000000-0000-4000-8000-000000000001", "name": "Work", \#(mark) } ] }"#)
        defer { directory.remove() }

        let stored = try persistence.loadStoredGroups()
        #expect(stored.active.map(\.name) == ["Work"])
        #expect(stored.archived.isEmpty)
    }

    @Test(arguments: [#""archivedAt": "yesterday""#, #""archivedAt": 1793200000"#, #""archivedAt": null"#, #""restoresStandalone": "yes""#])
    func unreadableMarksKeepTheGroupArchived(mark: String) throws {
        let (persistence, directory) = try write(#"{ "formatVersion": 1, "groups": [ { "id": "00000000-0000-4000-8000-000000000001", "name": "Work", "archived": true, \#(mark) } ] }"#)
        defer { directory.remove() }

        let archived = try #require(try persistence.loadStoredGroups().archived.first)
        #expect(archived.archivedAt == nil)
        #expect(!archived.restoresStandalone)
    }

    @Test func anArchivedStandaloneGroupInAFileIsntStandalone() throws {
        let (persistence, directory) = try write(#"{ "formatVersion": 1, "groups": [ { "id": "00000000-0000-4000-8000-000000000001", "name": "Work", "isStandalone": true, "archived": true } ] }"#)
        defer { directory.remove() }

        let archived = try #require(try persistence.loadStoredGroups().archived.first)
        #expect(!archived.group.isStandalone)
        #expect(archived.restoresStandalone)
    }

    @Test func anArchivedGroupRepeatingAnIdentifierIsDropped() throws {
        let file = #"""
        { "formatVersion": 1, "groups": [
          { "id": "00000000-0000-4000-8000-000000000001", "name": "Work" },
          { "id": "00000000-0000-4000-8000-000000000001", "name": "Work, archived", "archived": true },
          { "id": "00000000-0000-4000-8000-000000000002", "name": "Old", "archived": true },
          { "id": "00000000-0000-4000-8000-000000000002", "name": "Old again", "archived": true } ] }
        """#
        let (persistence, directory) = try write(file)
        defer { directory.remove() }

        let stored = try persistence.loadStoredGroups()
        #expect(stored.active.map(\.name) == ["Work"])
        #expect(stored.archived.map(\.group.name) == ["Old"])
    }

    @Test func aFileWithoutArchivedGroupsIsWrittenAsBefore() throws {
        let (persistence, directory) = try write(Version080Fixtures.groupsFile)
        defer { directory.remove() }

        try persistence.saveStoredGroups(try persistence.loadStoredGroups())

        #expect(try String(contentsOf: directory.url.appending(path: "groups.json"), encoding: .utf8) == Version080Fixtures.groupsFile)
    }

    @Test func aStoreThatOnlyKnowsActiveGroupsRefusesArchivedOnes() throws {
        let persistence = MemoryGroupPersistence()
        #expect(throws: GroupPersistenceError.archivedGroupsUnsupported) {
            try persistence.saveStoredGroups(StoredGroups(archived: [ArchivedGroup(group: DockGroup(name: "Old"), archivedAt: nil)]))
        }
        #expect(throws: Never.self) { try persistence.saveStoredGroups(StoredGroups(active: [DockGroup(name: "Work")])) }
        #expect(try persistence.loadStoredGroups().active.map(\.name) == ["Work"])
    }
}

@Suite("Archive: backups")
@MainActor
struct GroupArchiveBackupTests {
    private func json(_ text: String) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject)
    }

    private func withoutNewKeys(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            let unknown: Set<String> = ["archived", "archivedAt", "restoresStandalone", "shortcut"]
            return object.filter { !unknown.contains($0.key) }.mapValues(withoutNewKeys)
        }
        if let array = value as? [Any] { return array.map(withoutNewKeys) }
        return value
    }

    private static var backup: SettingsBackup {
        let stored = Version090ArchiveFixtures.stored
        return SettingsBackup(
            appVersion: "0.9.0",
            exportedAt: Version080Fixtures.exportedAt,
            groups: stored.active,
            archivedGroups: stored.archived,
            preferences: Version080Fixtures.preferences
        )
    }

    @Test func archivedGroupsGoIntoTheBackupsGroupList() throws {
        let written = String(decoding: try Self.backup.encoded(), as: UTF8.self)

        #expect(written == Version090ArchiveFixtures.backup)
        let read = try SettingsBackup.decode(from: Data(written.utf8))
        #expect(read == Self.backup)
        #expect(read.archivedGroups == Version090ArchiveFixtures.stored.archived)
        #expect(read.itemCount == Version080Fixtures.designGroup.apps.count, "items of the active groups")
        // 0.8.0 imported it as two ordinary groups and dropped only what it doesn't know.
        #expect(withoutNewKeys(try json(written)) as? NSObject == (try json(Version090ArchiveFixtures.backupSavedBy080)))
    }

    @Test func archivedGroupsAreBroughtInUnderTheSameRules() throws {
        let backup = #"""
        { "schemaVersion": 1, "app": "cybokron-dock-groups", "appVersion": "9.9.9", "exportedAt": "2026-10-25T10:00:00Z",
          "groups": [ { "id": "00000000-0000-4000-8000-000000000001", "name": "Old", "archived": true, "isStandalone": true, "apps": [
              { "bundleIdentifier": "file:///Users/me/run.command", "kind": "file", "name": "run" },
              { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", "openWith": { "bundleIdentifier": "com.apple.Terminal", "name": "Terminal" } },
              { "bundleIdentifier": "com.apple.mail", "name": "Mail" } ] } ],
          "preferences": { "formatVersion": 1 } }
        """#

        let read = try SettingsBackup.decode(from: Data(backup.utf8))

        let archived = try #require(read.archivedGroups.first)
        #expect(read.groups.isEmpty)
        #expect(archived.group.apps.map(\.name) == ["notes.txt", "Mail"], "the script is left out")
        #expect(archived.group.apps[0].launch.opener == nil, "the runner is dropped")
        #expect(read.leftOutItemCount == 1 && read.resetLaunchOptionCount == 1)
        #expect(!archived.group.isStandalone && archived.restoresStandalone)
    }

    @Test func replaceAllReplacesArchivedGroupsToo() throws {
        let (store, _) = GroupStore.archiving()
        let mine = store.addGroup(named: "Mine")
        store.archiveGroup(mine.id)
        let preferences = PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero)

        try Self.backup.restore(to: store, preferences: preferences)

        #expect(store.groups.map(\.name) == ["Design"])
        #expect(store.archivedGroups.map(\.group.name) == ["Coding"])
        #expect(store.archivedGroups == Version090ArchiveFixtures.stored.archived)
    }

    @Test func mergingMatchesNamesAgainstArchivedGroupsAndAddsArchivedOnes() throws {
        let (store, _) = GroupStore.archiving()
        let design = store.addGroup(named: "design")
        store.archiveGroup(design.id)
        let summary = SettingsRestoreSummary(backup: Self.backup, currentGroups: store.groups, currentArchivedGroups: store.archivedGroups)

        let result = try Self.backup.merge(into: store)

        #expect(result.addedGroups.isEmpty, "Design matches the archived “design”")
        #expect(result.addedArchivedGroups.map(\.group.name) == ["Coding"])
        #expect(store.archivedGroups.map(\.group.name) == ["design", "Coding"])
        #expect(store.groups.isEmpty)
        #expect(summary.mergedGroupCount == 0 && summary.mergedArchivedGroupCount == 1 && summary.skippedGroupCount == 1)
    }

    @Test func mergedGroupsLoseKeysACurrentGroupHasAndTheSummaryCountsThem() throws {
        let (store, _) = GroupStore.archiving()
        let current = store.addGroup(named: "Current")
        store.setShortcut(makeShortcut(kVK_ANSI_D, [.control, .option]), forGroup: current.id)
        // Design's shortcut is ⌃⌥D too; Coding's (archived) keeps its keys.
        let summary = SettingsRestoreSummary(backup: Self.backup, currentGroups: store.groups, currentArchivedGroups: store.archivedGroups)

        let result = try Self.backup.merge(into: store)

        #expect(result.clearedShortcutCount == 1)
        #expect(summary.clearedShortcutCount == 1)
        #expect(result.addedGroups.map(\.shortcut) == [nil])
        #expect(store.group(withID: current.id)?.shortcut != nil)
        #expect(store.archivedGroups.first?.group.shortcut == Version080Fixtures.codingShortcut, "archived groups hold no keys")
        #expect(summary.clearedShortcutsNote == "1 group comes in without its keyboard shortcut: another group uses those keys.")
    }

    @Test func theSummarySaysWhatHappensToArchivedGroups() {
        let archived = (1...3).map { ArchivedGroup(group: DockGroup(name: "Old \($0)"), archivedAt: nil) }
        let none = SettingsRestoreSummary(backup: SettingsBackup(appVersion: "0.9.0", groups: [], preferences: PopupPreferences()), currentGroups: [])
        #expect(none.archivedGroupsNote == nil && none.replacedArchivedGroupsNote == nil && none.clearedShortcutsNote == nil)

        let backup = SettingsBackup(appVersion: "0.9.0", groups: [], archivedGroups: archived, preferences: PopupPreferences())
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: [], currentArchivedGroups: Array(archived.prefix(1)))
        #expect(summary.archivedGroupCount == 3 && summary.currentArchivedGroupCount == 1)
        #expect(summary.archivedGroupsNote == "It also has 3 archived groups.")
        #expect(summary.replacedArchivedGroupsNote == "Your archived group is replaced too.")
        #expect(summary.mergedArchivedGroupCount == 2, "“Old 1” is here already")

        let one = SettingsRestoreSummary(backup: SettingsBackup(appVersion: "0.9.0", groups: [], archivedGroups: Array(archived.prefix(1)), preferences: PopupPreferences()), currentGroups: [], currentArchivedGroups: archived)
        #expect(one.archivedGroupsNote == "It also has 1 archived group.")
        #expect(one.replacedArchivedGroupsNote == "Your 3 archived groups are replaced too.")
    }

    @Test func anOlderBackupReplacesArchivedGroupsWithNone() throws {
        let (store, _) = GroupStore.archiving()
        let old = store.addGroup(named: "Old")
        store.archiveGroup(old.id)
        let backup = try SettingsBackup.decode(from: Data(Version080Fixtures.backup.utf8))
        #expect(backup.archivedGroups.isEmpty)
        #expect(SettingsRestoreSummary(backup: backup, currentGroups: store.groups, currentArchivedGroups: store.archivedGroups).currentArchivedGroupCount == 1,
                "the confirmation says so")

        try backup.restore(to: store, preferences: PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero))

        #expect(store.archivedGroups.isEmpty)
        #expect(store.groups.map(\.name) == ["Coding", "Design"])
    }
}

@Suite("Duplicate and names")
@MainActor
struct GroupDuplicateTests {
    @Test func uniqueNamesCountOn() {
        #expect(GroupNaming.uniqueName("Coding", taken: []) == "Coding")
        #expect(GroupNaming.uniqueName("Coding", taken: ["coding "]) == "Coding 2", "ignoring case and spaces")
        #expect(GroupNaming.uniqueName("Coding", taken: ["Coding", "Coding 2", "coding 3"]) == "Coding 4")
        #expect(GroupNaming.uniqueName("  ", taken: []) == DockGroup.defaultName)
    }

    @Test func copyNamesCountOnFromTheOriginal() {
        #expect(GroupNaming.copyName(of: "Coding", taken: ["Coding"]) == "Coding copy")
        #expect(GroupNaming.copyName(of: "Coding", taken: ["Coding", "Coding Copy"]) == "Coding copy 2")
        #expect(GroupNaming.copyName(of: "Coding copy", taken: ["Coding", "Coding copy"]) == "Coding copy 2")
        #expect(GroupNaming.copyName(of: "Coding copy 2", taken: ["Coding copy", "Coding copy 2"]) == "Coding copy 3")
        #expect(GroupNaming.copyName(of: "Coding copy 2", taken: ["Coding copy 2"]) == "Coding copy")
        #expect(GroupNaming.copyName(of: "copy", taken: ["copy"]) == "copy copy", "a name that only looks like a suffix")
        #expect(GroupNaming.original(ofCopyNamed: "Work copy 12") == "Work")
        #expect(GroupNaming.original(ofCopyNamed: "Copying") == "Copying")
    }

    @Test func aDuplicateIsANewGroupAtTheEndWithTheSameItemsAndSettings() throws {
        let (store, persistence) = GroupStore.archiving()
        let coding = store.addGroup(named: "Coding", emoji: "💻")
        store.addGroup(named: "Home")
        var report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file)
        report.details = ItemDetails(alias: "Q3", tags: ["work"], notes: "Totals")
        report.launch = ItemLaunchOptions(delay: 3)
        store.addItems([AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"), report], toGroup: coding.id)
        store.updateGroup(coding.id) { group in
            group.isPinned = true
            group.isStandalone = true
            group.tile = TileAppearance(kind: .grid)
            group.popup = PopupOverrides(columns: .fixed(3))
            group.freeLayoutSlots = ["com.apple.dt.xcode": 2]
            group.switching = GroupSwitching(onStart: .hideAllOtherApps)
        }
        store.setShortcut(makeShortcut(kVK_ANSI_C, [.control, .option]), forGroup: coding.id)
        let original = try #require(store.group(withID: coding.id))
        let saves = persistence.saveCount

        let copy = try #require(store.duplicateGroup(coding.id))

        #expect(copy.id != original.id)
        #expect(copy.name == "Coding copy")
        #expect(store.groups.map(\.name) == ["Coding", "Home", "Coding copy"], "at the end: no number shortcut moves")
        #expect(copy.emoji == "💻" && copy.apps == original.apps && copy.tile == original.tile && copy.isPinned)
        #expect(copy.popup == original.popup && copy.freeLayoutSlots == original.freeLayoutSlots && copy.switching == original.switching)
        #expect(copy.apps[1].details == report.details && copy.apps[1].launch == report.launch)
        #expect(!copy.isStandalone, "no agent, no Dock restart")
        #expect(copy.shortcut == nil, "keys stay with the original")
        #expect(persistence.saveCount == saves + 1)
        #expect(store.group(withID: coding.id) == original)

        #expect(store.duplicateGroup(copy.id)?.name == "Coding copy 2")
        #expect(store.duplicateGroup(UUID()) == nil)
    }

    @Test func storeMadeNamesAvoidArchivedGroups() throws {
        let (store, _) = GroupStore.archiving()
        let new = store.addGroup()
        let coding = store.addGroup(named: "Coding")
        let copy = try #require(store.duplicateGroup(coding.id))
        store.archiveGroup(new.id)
        store.archiveGroup(copy.id)

        #expect(store.addGroup().name == "New Group 2")
        #expect(store.duplicateGroup(coding.id)?.name == "Coding copy 2")
    }

    @Test func namesTheUserTypesAreKept() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        store.archiveGroup(work.id)
        let other = store.addGroup(named: "Work")
        #expect(other.name == "Work", "a name given is kept")
        let home = store.addGroup(named: "Home")
        #expect(store.renameGroup(home.id, to: "Work"))
        #expect(store.group(withID: home.id)?.name == "Work")
        // A restored group keeps its name, too.
        #expect(store.restoreGroup(work.id)?.group.name == "Work")
    }
}
