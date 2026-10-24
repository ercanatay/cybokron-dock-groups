import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Templates: the template")
struct GroupTemplateModelTests {
    private static let coding = Version080Fixtures.groupsWithShortcuts[0]

    @Test func aTemplateIsABlueprintWithoutIdentityDockIconOrShortcut() {
        let id = UUID()
        let template = GroupTemplate(saving: Self.coding, named: "  Coding Starter ", id: id, at: Date(timeIntervalSince1970: 1_793_300_000.9))

        #expect(template.id == id)
        #expect(template.name == "Coding Starter")
        #expect(template.group.id == id, "the blueprint's identifier is the template's")
        #expect(!template.group.isStandalone && template.group.shortcut == nil)
        #expect(template.group.apps == Self.coding.apps)
        #expect(template.group.switching == Self.coding.switching && template.group.popup == Self.coding.popup)
        #expect(template.group.freeLayoutSlots == Self.coding.freeLayoutSlots && template.group.tile == Self.coding.tile)
        #expect(template.savedAt == Date(timeIntervalSince1970: 1_793_300_000), "whole seconds")
        #expect(GroupTemplate(saving: Self.coding, named: "   ").name == "Coding", "a blank name is the group's")
        #expect(GroupTemplate(saving: Self.coding).name == "Coding")
    }

    @Test func aGroupMadeFromItIsNew() {
        let template = Version090TemplateFixtures.template

        let group = template.makeGroup(named: "Coding 2")

        #expect(group.id != template.id && group.id != Self.coding.id)
        #expect(group.name == "Coding 2")
        #expect(group.apps == Self.coding.apps && group.emoji == Self.coding.emoji && group.isPinned == Self.coding.isPinned)
        #expect(group.apps.map(\.launch) == Self.coding.apps.map(\.launch), "launch options too")
        #expect(group.apps.map(\.details) == Self.coding.apps.map(\.details), "details too")
        #expect(!group.isStandalone && group.shortcut == nil)
        #expect(template.makeGroup(named: "x").id != group.id, "each one new")
    }

    @Test func theTemplatesFileReadsAndIsSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "templates.json")
        let persistence = JSONFileTemplatePersistence(fileURL: url)

        try persistence.saveTemplates([Version090TemplateFixtures.template])

        #expect(try String(contentsOf: url, encoding: .utf8) == Version090TemplateFixtures.templatesFile)
        #expect(try persistence.loadTemplates() == [Version090TemplateFixtures.template])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 1)
        #expect(JSONFileTemplatePersistence.defaultFileURL.lastPathComponent == "templates.json")
        #expect(JSONFileTemplatePersistence.defaultFileURL.deletingLastPathComponent() == JSONFileGroupPersistence.defaultFileURL.deletingLastPathComponent())
    }

    @Test func aCraftedBlueprintIsNormalized() throws {
        let json = #"""
        { "id": "7E3A1A7E-0000-4000-8000-000000000001", "savedAt": "soon",
          "group": { "id": "00000000-0000-4000-8000-0000000000FF", "name": "Work", "isStandalone": true,
                     "archived": true, "shortcut": { "keyCode": 13, "modifiers": ["control", "option"] } } }
        """#

        let template = try JSONDecoder().decode(GroupTemplate.self, from: Data(json.utf8))

        #expect(template.group.id == template.id)
        #expect(!template.group.isStandalone && template.group.shortcut == nil)
        #expect(template.savedAt == nil)
        #expect(template.name == "Work")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GroupTemplate.self, from: Data(#"{ "id": "7E3A1A7E-0000-4000-8000-000000000001" }"#.utf8)) }
    }

    @Test func aNewerTemplatesFileIsRefused() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "templates.json")
        try Data(#"{ "formatVersion": 2, "templates": [] }"#.utf8).write(to: url)

        #expect(throws: TemplatePersistenceError.unsupportedFormatVersion(2)) { try JSONFileTemplatePersistence(fileURL: url).loadTemplates() }
        #expect(TemplatePersistenceError.unsupportedFormatVersion(2).errorDescription
            == "The templates file was saved by a newer version of Cybokron Dock Groups (format 2).")
    }
}

@Suite("Templates: the store")
@MainActor
struct TemplateStoreTests {
    private func store(_ templates: [GroupTemplate] = []) -> (TemplateStore, MemoryTemplatePersistence) {
        let persistence = MemoryTemplatePersistence(templates)
        return (TemplateStore(persistence: persistence, saveDelay: .zero), persistence)
    }

    @Test func savingAddsATemplateAtTheEnd() throws {
        let (store, persistence) = store([.named("Writing")])
        let coding = Version080Fixtures.groupsWithShortcuts[0]

        guard case .saved(let template) = store.save(coding) else { Issue.record("not saved"); return }

        #expect(store.templates.map(\.name) == ["Writing", "Coding"])
        #expect(template.group.shortcut == nil && !template.group.isStandalone)
        #expect(persistence.saved == store.templates && persistence.saveCount == 1)
        #expect(store.template(withID: template.id) == template)
        #expect(store.template(named: " coding ") == template)
    }

    @Test func aTakenNameIsReplacedOnlyWhenAsked() throws {
        let (store, persistence) = store()
        let first = DockGroup(name: "Coding", apps: [AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")])
        guard case .saved(let original) = store.save(first, at: Date(timeIntervalSince1970: 1_000)) else { Issue.record("not saved"); return }
        let second = DockGroup(name: "Other", apps: [AppReference(bundleIdentifier: "com.apple.Terminal", name: "Terminal")])

        #expect(store.save(second, named: "CODING") == .nameTaken(original))
        #expect(store.templates == [original] && persistence.saveCount == 1)

        guard case .saved(let replacement) = store.save(second, named: "CODING", replacing: true, at: Date(timeIntervalSince1970: 2_000)) else { Issue.record("not replaced"); return }
        #expect(replacement.id == original.id, "replaced in place")
        #expect(replacement.name == "CODING" && replacement.group.apps == second.apps)
        #expect(replacement.savedAt == Date(timeIntervalSince1970: 2_000))
        #expect(store.templates == [replacement])
    }

    @Test func atMostFiftyTemplatesAreKept() {
        let (store, _) = store((1...GroupTemplate.maximumCount).map { .named("Template \($0)") })

        #expect(store.save(DockGroup(name: "One more")) == .limitReached)
        #expect(store.templates.count == GroupTemplate.maximumCount)
        // Replacing one doesn't add any.
        guard case .saved = store.save(DockGroup(name: "Template 3"), replacing: true) else { Issue.record("not replaced"); return }
        #expect(store.templates.count == GroupTemplate.maximumCount)
    }

    @Test func renamingKeepsNamesUnique() {
        let writing = GroupTemplate.named("Writing")
        let coding = GroupTemplate.named("Coding")
        let (store, persistence) = store([writing, coding])

        #expect(store.rename(writing.id, to: "  Notes  "))
        #expect(store.template(withID: writing.id)?.name == "Notes")
        #expect(store.template(withID: writing.id)?.group.name == "Notes", "the blueprint's name, which groups take")
        #expect(!store.rename(writing.id, to: "coding"), "another template has it")
        #expect(!store.rename(writing.id, to: "   "))
        #expect(!store.rename(UUID(), to: "Ghost"))
        let saves = persistence.saveCount
        #expect(store.rename(writing.id, to: "Notes"))
        #expect(persistence.saveCount == saves, "nothing saved for the same name")
    }

    @Test func deletingRemovesTheTemplateOnly() {
        let writing = GroupTemplate.named("Writing")
        let (store, persistence) = store([writing, .named("Coding")])

        store.delete(writing.id)
        store.delete(UUID())

        #expect(store.templates.map(\.name) == ["Coding"])
        #expect(persistence.saved.map(\.name) == ["Coding"])
    }

    @Test func aFreeNameIsSuggested() {
        let (store, _) = store([.named("Coding"), .named("Coding 2")])
        #expect(store.suggestedName(for: DockGroup(name: "coding")) == "coding 3")
        #expect(store.suggestedName(for: DockGroup(name: "Writing")) == "Writing")
    }

    @Test func templatesAreLoadedWithUniqueIdentifiersAndNamesAtMostFifty() {
        let id = UUID()
        var loaded = [GroupTemplate.named("A", id: id), .named("B", id: id), .named("a")]
        loaded += (1...60).map { .named("T\($0)") }
        let (store, _) = store(loaded)

        #expect(store.templates.count == GroupTemplate.maximumCount)
        #expect(store.templates.prefix(2).map(\.name) == ["A", "T1"])
    }

    @Test func anUnreadableFileIsMovedAsideAndTheStoreStartsEmpty() {
        let persistence = MemoryTemplatePersistence([.named("Writing")])
        persistence.failsToLoad = true

        let store = TemplateStore(persistence: persistence, saveDelay: .zero)

        #expect(store.templates.isEmpty)
        #expect(persistence.movedAside)
        #expect(store.issue?.title == "Your templates couldn't be loaded")
        #expect(store.issue?.message.hasSuffix("Starting without templates. A copy was kept at “/tmp/templates.unreadable.json”.") == true)
        guard case .saved = store.save(DockGroup(name: "Coding")) else { Issue.record("not saved"); return }
        #expect(persistence.saved.map(\.name) == ["Coding"])
    }

    @Test func whenItCantBeMovedAsideNothingIsSaved() {
        let persistence = MemoryTemplatePersistence([.named("Writing")])
        persistence.failsToLoad = true
        persistence.failsToMoveAside = true

        let store = TemplateStore(persistence: persistence, saveDelay: .zero)
        store.save(DockGroup(name: "Coding"))

        #expect(store.isSavingSuspended)
        #expect(persistence.saveCount == 0, "the unreadable file isn't overwritten")
        #expect(store.issue?.message.hasSuffix("To protect the existing file, changes to templates won't be saved until the app is restarted.") == true)
    }

    @Test func aFailedSaveIsReported() {
        let (store, persistence) = store()
        persistence.failsToSave = true

        store.save(DockGroup(name: "Coding"))

        #expect(store.issue?.title == "Your templates couldn't be saved")
        store.dismissIssue()
        #expect(store.issue == nil)
    }

    @Test func templatesAreSavedToTheirOwnFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(components: "DockGroups", "templates.json")
        let store = TemplateStore(persistence: JSONFileTemplatePersistence(fileURL: url), saveDelay: .zero)

        store.save(Version080Fixtures.groupsWithShortcuts[0], named: "Coding Starter")

        let reloaded = TemplateStore(persistence: JSONFileTemplatePersistence(fileURL: url), saveDelay: .zero)
        #expect(reloaded.templates == store.templates)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(components: "DockGroups", "groups.json").path), "the groups file isn't touched")
    }
}

@Suite("Templates: groups made from them")
@MainActor
struct GroupFromTemplateTests {
    @Test func aGroupFromATemplateIsNewAtTheEndAndOpensNothing() throws {
        let (store, persistence) = GroupStore.archiving()
        store.addGroup(named: "Home")
        let template = Version090TemplateFixtures.template
        let saves = persistence.saveCount

        let group = store.addGroup(from: template)

        #expect(store.groups.map(\.name) == ["Home", "Coding Starter"])
        #expect(group.id != template.id)
        #expect(group.apps == template.group.apps && group.switching == template.group.switching)
        #expect(!group.isStandalone && group.shortcut == nil)
        #expect(persistence.saveCount == saves + 1)
    }

    @Test func itsNameAvoidsActiveAndArchivedGroups() {
        let (store, _) = GroupStore.archiving()
        let template = GroupTemplate.named("Coding")
        let archived = store.addGroup(named: "coding")
        store.archiveGroup(archived.id)

        #expect(store.addGroup(from: template).name == "Coding 2")
        #expect(store.addGroup(from: template).name == "Coding 3")
    }

    @Test func aCraftedBlueprintIsCleanedUp() throws {
        let json = #"""
        { "id": "7E3A1A7E-0000-4000-8000-000000000001",
          "group": { "id": "00000000-0000-4000-8000-0000000000FF", "name": "Work", "emoji": "",
                     "apps": [ { "bundleIdentifier": "com.apple.mail", "name": "Mail" }, { "bundleIdentifier": "COM.APPLE.MAIL", "name": "Mail" } ] } }
        """#
        let template = try JSONDecoder().decode(GroupTemplate.self, from: Data(json.utf8))
        let (store, _) = GroupStore.archiving()

        let group = store.addGroup(from: template)

        #expect(group.apps.count == 1, "duplicate items dropped")
        #expect(group.emoji == DockGroup.defaultEmoji)
    }
}

@Suite("Templates: backups")
@MainActor
struct GroupTemplateBackupTests {
    private func json(_ text: String) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject)
    }

    private static var backup: SettingsBackup {
        SettingsBackup(
            appVersion: "0.9.0",
            exportedAt: Version080Fixtures.exportedAt,
            groups: [Version080Fixtures.designGroup],
            templates: [Version090TemplateFixtures.template],
            preferences: Version080Fixtures.preferences
        )
    }

    private func templateStore(_ templates: [GroupTemplate] = []) -> (TemplateStore, MemoryTemplatePersistence) {
        let persistence = MemoryTemplatePersistence(templates)
        return (TemplateStore(persistence: persistence, saveDelay: .zero), persistence)
    }

    private func preferences() -> PreferencesStore {
        PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero)
    }

    @Test func templatesGoIntoTheBackupsTemplatesList() throws {
        let written = String(decoding: try Self.backup.encoded(), as: UTF8.self)

        #expect(written == Version090TemplateFixtures.backup)
        let read = try SettingsBackup.decode(from: Data(written.utf8))
        #expect(read == Self.backup)
        #expect(read.templates == [Version090TemplateFixtures.template])
        // 0.8.0 imported its groups and dropped only the templates.
        var older = try #require(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        older["templates"] = nil
        #expect(older as NSObject == (try json(Version090TemplateFixtures.backupSavedBy080)))
    }

    @Test func aBackupWithoutTemplatesHasNoTemplatesList() throws {
        let object = try #require(JSONSerialization.jsonObject(with: SettingsBackup(appVersion: "0.9.0", groups: [], preferences: PopupPreferences()).encoded()) as? [String: Any])
        #expect(object["templates"] == nil)
        #expect(try SettingsBackup.decode(from: Data(Version080Fixtures.backup.utf8)).templates.isEmpty)
    }

    @Test func templatesAreBroughtInUnderTheSameRulesAsGroups() throws {
        var templates = (1...55).map { #"{ "id": "\#(String(format: "7E3A1A7E-0000-4000-8000-%012d", $0))", "group": { "id": "\#(UUID().uuidString)", "name": "T\#($0)" } }"# }
        templates.insert(#"""
        { "id": "7E3A1A7E-0000-4000-8000-0000000000AA", "group": { "id": "00000000-0000-4000-8000-0000000000FF", "name": "Risky", "isStandalone": true, "apps": [
            { "bundleIdentifier": "file:///Users/me/run.command", "kind": "file", "name": "run" },
            { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", "openWith": { "bundleIdentifier": "com.googlecode.iterm2", "name": "iTerm" } } ] } }
        """#, at: 0)
        templates.insert(#"{ "id": "7E3A1A7E-0000-4000-8000-0000000000BB", "group": { "id": "\#(UUID().uuidString)", "name": "risky" } }"#, at: 1)
        let backup = #"""
        { "schemaVersion": 1, "app": "cybokron-dock-groups", "appVersion": "9.9.9", "exportedAt": "2026-10-25T10:00:00Z",
          "groups": [], "preferences": { "formatVersion": 1 }, "templates": [ \#(templates.joined(separator: ", ")) ] }
        """#

        let read = try SettingsBackup.decode(from: Data(backup.utf8))

        #expect(read.templates.count == GroupTemplate.maximumCount)
        let risky = try #require(read.templates.first)
        #expect(risky.group.apps.map(\.name) == ["notes.txt"], "the script is left out")
        #expect(risky.group.apps.first?.launch.opener == nil, "the terminal is dropped")
        #expect(!risky.group.isStandalone)
        #expect(read.templates[1].name == "T1", "a repeated name is dropped")
        #expect(read.leftOutItemCount == 1 && read.resetLaunchOptionCount == 1)
    }

    @Test func replaceAllReplacesTemplatesWhenTheBackupHasSome() throws {
        let (groups, _) = GroupStore.archiving()
        let (templates, _) = templateStore([.named("Mine")])

        try Self.backup.restore(to: groups, preferences: preferences(), templates: templates)

        #expect(templates.templates == [Version090TemplateFixtures.template])
        #expect(groups.groups.map(\.name) == ["Design"])
    }

    @Test func aBackupWithoutTemplatesKeepsThem() throws {
        let (groups, _) = GroupStore.archiving()
        let mine = GroupTemplate.named("Mine")
        let (templates, persistence) = templateStore([mine])
        let backup = try SettingsBackup.decode(from: Data(Version080Fixtures.backup.utf8))
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: [], currentTemplates: templates.templates)

        try backup.restore(to: groups, preferences: preferences(), templates: templates)

        #expect(templates.templates == [mine])
        #expect(persistence.saveCount == 0)
        #expect(summary.replacedTemplatesNote == "It has no templates; yours are kept.")
        #expect(summary.templatesNote == nil)
    }

    @Test func whenTheTemplatesCantBeWrittenNothingIsRestored() throws {
        let (groups, _) = GroupStore.archiving()
        let home = groups.addGroup(named: "Home")
        groups.archiveGroup(groups.addGroup(named: "Old").id)
        let before = StoredGroups(active: groups.groups, archived: groups.archivedGroups)
        let preferences = preferences()
        preferences.update { $0.theme = .light }
        let (templates, persistence) = templateStore([.named("Mine")])
        persistence.failsToSave = true

        #expect(throws: MemoryTemplatePersistence.Failure.self) {
            try Self.backup.restore(to: groups, preferences: preferences, templates: templates)
        }

        #expect(StoredGroups(active: groups.groups, archived: groups.archivedGroups) == before)
        #expect(groups.group(withID: home.id) != nil)
        #expect(preferences.preferences.theme == .light)
        #expect(templates.templates.map(\.name) == ["Mine"])
    }

    @Test func mergingAddsTemplatesThatArentHereYet() throws {
        let (groups, _) = GroupStore.archiving()
        let (templates, _) = templateStore([.named("coding starter"), .named("Writing")])
        let other = GroupTemplate.named("Notes")
        let backup = SettingsBackup(appVersion: "0.9.0", groups: [], templates: [Version090TemplateFixtures.template, other], preferences: PopupPreferences())
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: [], currentTemplates: templates.templates)

        let result = try backup.merge(into: groups, templates: templates)

        #expect(result.addedTemplates == [other], "“Coding Starter” is here already")
        #expect(templates.templates.map(\.name) == ["coding starter", "Writing", "Notes"])
        #expect(summary.mergedTemplateCount == 1)
        #expect(summary.mergedTemplatesNote == "It adds 1 template.")
        #expect(summary.templatesNote == "It also has 2 templates.")
        #expect(summary.replacedTemplatesNote == "Your 2 templates are replaced too.")
    }

    @Test func mergingNeverGoesBeyondFifty() throws {
        let (templates, _) = templateStore((1...49).map { .named("Mine \($0)") })
        let incoming = (1...5).map { GroupTemplate.named("New \($0)") }

        let added = try templates.mergeTemplates(incoming)

        #expect(added.map(\.name) == ["New 1"])
        #expect(templates.templates.count == GroupTemplate.maximumCount)
        #expect(try templates.mergeTemplates(incoming).isEmpty)
    }

    @Test func theSummaryCountsTemplates() {
        let one = SettingsRestoreSummary(
            backup: SettingsBackup(appVersion: "0.9.0", groups: [], templates: [.named("A")], preferences: PopupPreferences()),
            currentGroups: [],
            currentTemplates: [.named("B")]
        )
        #expect(one.templateCount == 1 && one.currentTemplateCount == 1 && one.mergedTemplateCount == 1)
        #expect(one.templatesNote == "It also has 1 template.")
        #expect(one.replacedTemplatesNote == "Your template is replaced too.")
        let none = SettingsRestoreSummary(backup: SettingsBackup(appVersion: "0.9.0", groups: [], preferences: PopupPreferences()), currentGroups: [])
        #expect(none.templatesNote == nil && none.replacedTemplatesNote == nil && none.mergedTemplatesNote == nil)
        let many = SettingsRestoreSummary(
            backup: SettingsBackup(appVersion: "0.9.0", groups: [], templates: [.named("A"), .named("B"), .named("C")], preferences: PopupPreferences()),
            currentGroups: []
        )
        #expect(many.mergedTemplatesNote == "It adds 3 templates.")
    }

    @Test func aBackupOfTheStoresHasTheTemplates() throws {
        let (groups, _) = GroupStore.archiving()
        groups.addGroup(named: "Work")
        let (templates, _) = templateStore([Version090TemplateFixtures.template])

        let backup = SettingsBackup(groups: groups, preferences: preferences(), templates: templates, appVersion: "0.9.0")

        #expect(backup.templates == [Version090TemplateFixtures.template])
        #expect(SettingsBackup(groups: groups, preferences: preferences(), appVersion: "0.9.0").templates.isEmpty)
    }
}
