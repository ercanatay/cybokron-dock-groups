import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Settings backup")
@MainActor
struct SettingsBackupTests {
    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let notes = AppReference(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private static let exportDate = Date(timeIntervalSince1970: 1_792_000_000)

    private static let sampleGroups: [DockGroup] = [
        DockGroup(
            name: "Work",
            emoji: "💼",
            apps: [safari, mail],
            tile: TileAppearance(kind: .grid),
            isPinned: true,
            isStandalone: true,
            popup: PopupOverrides(columns: .fixed(3), maxRows: 2, showsTitles: false, anchor: .dockIcon),
            freeLayoutSlots: ["com.apple.safari": 4, "com.apple.mail": 0]
        ),
        DockGroup(name: "Notes", apps: [notes]),
    ]

    private static var samplePreferences: PopupPreferences {
        PopupPreferences(
            theme: .light,
            usesFrostedGlass: false,
            columns: .fixed(5),
            maxRows: 3,
            showsTitles: false,
            anchor: .dockIcon,
            usesFreeLayout: true,
            shortcutsEnabled: true,
            showsMostUsed: false,
            mostUsedLimit: MostUsedRanking.allowedLimits.last ?? MostUsedRanking.defaultLimit,
            mostUsedSessionSeconds: 900,
            automaticallyChecksForUpdates: false
        )
    }

    private static func sampleBackup(groups: [DockGroup]? = nil) -> SettingsBackup {
        SettingsBackup(appVersion: "0.5.2", exportedAt: exportDate, groups: groups ?? sampleGroups, preferences: samplePreferences)
    }

    private static func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Format

    @Test func roundTripKeepsGroupsAndPreferences() throws {
        let backup = Self.sampleBackup()

        let decoded = try SettingsBackup.decode(from: backup.encoded())

        #expect(decoded == backup)
        #expect(decoded.groups == Self.sampleGroups)
        #expect(decoded.groups.first?.freeLayoutSlots == ["com.apple.safari": 4, "com.apple.mail": 0])
        #expect(decoded.preferences == Self.samplePreferences)
        #expect(decoded.preferences.usesFreeLayout)
        #expect(decoded.schemaVersion == SettingsBackup.currentSchemaVersion)
        #expect(decoded.appVersion == "0.5.2")
        #expect(decoded.exportedAt == Self.exportDate)
        #expect(decoded.appCount == 3)
    }

    @Test func emptyGroupListRoundTrips() throws {
        let backup = Self.sampleBackup(groups: [])

        let decoded = try SettingsBackup.decode(from: backup.encoded())

        #expect(decoded.groups.isEmpty)
        #expect(decoded.appCount == 0)
        #expect(decoded.preferences == Self.samplePreferences)
    }

    @Test func fileHasHeaderGroupsAndPreferencesLikePreferencesJSON() throws {
        let data = try Self.sampleBackup().encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["schemaVersion", "app", "appVersion", "exportedAt", "groups", "preferences"])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["app"] as? String == "cybokron-dock-groups")
        #expect(object["appVersion"] as? String == "0.5.2")
        let exportedAt = try #require(object["exportedAt"] as? String)
        #expect(ISO8601DateFormatter().date(from: exportedAt) == Self.exportDate)
        #expect((object["groups"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Work", "Notes"])

        // The preferences are stored exactly as preferences.json has them.
        let preferences = try #require(object["preferences"] as? [String: Any])
        #expect(preferences["formatVersion"] as? Int == 1)
        #expect(preferences["freeLayout"] as? Bool == true)
        #expect(preferences["panelTheme"] as? String == "light")
        let preferencesData = try JSONSerialization.data(withJSONObject: preferences)
        let asFile = try JSONDecoder().decode(PreferencesDocument.self, from: preferencesData)
        #expect(asFile.preferences == Self.samplePreferences)
    }

    @Test func readsHandWrittenBackup() throws {
        let id = UUID()
        let data = Self.json("""
        {
          "schemaVersion": 1,
          "app": "cybokron-dock-groups",
          "appVersion": "0.5.2",
          "exportedAt": "2026-10-18T09:30:00Z",
          "groups": [{ "id": "\(id.uuidString)", "name": "Dev", "apps": [] }],
          "preferences": { "formatVersion": 1, "freeLayout": true }
        }
        """)

        let backup = try SettingsBackup.decode(from: data)

        #expect(backup.groups.map(\.id) == [id])
        #expect(backup.groups.first?.emoji == DockGroup.defaultEmoji)
        #expect(backup.preferences == PopupPreferences(usesFreeLayout: true))
    }

    @Test func defaultFileNameHasDateAndExtension() {
        let date = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14 17:46 UTC
        let name = SettingsBackup.defaultFileName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "cybokron-dock-groups-backup-2026-10-14.dockgroups")
    }

    // MARK: - Rejected files

    @Test func newerSchemaVersionIsRejectedAsNewer() throws {
        let data = Self.json("""
        { "schemaVersion": 2, "app": "cybokron-dock-groups", "something": "else" }
        """)
        #expect(throws: SettingsBackupError.newerSchemaVersion(2)) {
            try SettingsBackup.decode(from: data)
        }
    }

    @Test(arguments: [
        // Missing, zero, negative or non-numeric schema version.
        #"{ "app": "cybokron-dock-groups", "groups": [], "preferences": {} }"#,
        #"{ "schemaVersion": 0, "app": "cybokron-dock-groups", "groups": [], "preferences": {} }"#,
        #"{ "schemaVersion": -1, "app": "cybokron-dock-groups", "groups": [], "preferences": {} }"#,
        #"{ "schemaVersion": "1", "app": "cybokron-dock-groups", "groups": [], "preferences": {} }"#,
        // Another app's file, or no app marker.
        #"{ "schemaVersion": 1, "app": "something-else", "groups": [], "preferences": {} }"#,
        #"{ "schemaVersion": 1, "groups": [], "preferences": {} }"#,
        // Missing or malformed parts.
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "preferences": {} }"#,
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "groups": [] }"#,
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "groups": {}, "preferences": {} }"#,
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "groups": [{ "name": "No ID" }], "preferences": {} }"#,
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "groups": [], "preferences": [] }"#,
        // A groups.json file isn't a backup.
        #"{ "formatVersion": 1, "groups": [] }"#,
    ])
    func invalidBackupIsRejected(text: String) {
        #expect(throws: SettingsBackupError.notABackup) {
            try SettingsBackup.decode(from: Self.json(text))
        }
    }

    @Test(arguments: [
        "",
        "not json at all",
        "[1, 2, 3]",
        "null",
        #"{ "schemaVersion": 1, "app": "cybokron-dock-groups", "groups": ["#,
    ])
    func corruptJSONIsRejected(text: String) {
        #expect(throws: SettingsBackupError.notABackup) {
            try SettingsBackup.decode(from: Self.json(text))
        }
    }

    @Test func truncatedBackupIsRejected() throws {
        let full = try Self.sampleBackup().encoded()
        #expect(throws: SettingsBackupError.notABackup) {
            try SettingsBackup.decode(from: full.prefix(full.count / 2))
        }
    }

    @Test func rejectionMessagesSayWhatsWrong() {
        #expect(SettingsBackupError.notABackup.localizedDescription == "This file isn't a Cybokron Dock Groups backup.")
        #expect(SettingsBackupError.newerSchemaVersion(3).localizedDescription.contains("newer version"))
    }

    // MARK: - Summary

    @Test func summaryCountsGroupsAppsAndSameNamedGroups() {
        let current = [
            DockGroup(name: "work"),
            DockGroup(name: "Games"),
            DockGroup(name: "Music"),
        ]

        let summary = SettingsRestoreSummary(backup: Self.sampleBackup(), currentGroups: current)

        #expect(summary.groupCount == 2)
        #expect(summary.appCount == 3)
        #expect(summary.replacedGroupCount == 1)
        #expect(summary.removedGroupCount == 2)
        // Merging adds "Notes" only; "Work" matches the current "work".
        #expect(summary.mergedGroupCount == 1)
        #expect(summary.mergedAppCount == 1)
        #expect(summary.skippedGroupCount == 1)
    }

    @Test func mergeSkipsSameNamedAndSameIdentifierGroups() {
        let current = [DockGroup(name: " WORK "), DockGroup(name: "Games")]
        let renamed = DockGroup(id: current[1].id, name: "Play")
        let incoming = [
            DockGroup(name: "work"),
            renamed,
            DockGroup(name: "Music"),
            DockGroup(name: "music"),
        ]

        let added = GroupStore.groupsAddedByMerging(incoming, into: current)

        #expect(added.map(\.name) == ["Music"])
    }

    // MARK: - Restoring

    private struct Stores {
        let directory: TemporaryDirectory
        let groupsURL: URL
        let preferencesURL: URL

        init() throws {
            directory = try TemporaryDirectory()
            groupsURL = directory.url.appending(components: "DockGroups", "groups.json")
            preferencesURL = directory.url.appending(components: "DockGroups", "preferences.json")
        }

        @MainActor func groups(persistence: GroupPersisting? = nil) -> GroupStore {
            GroupStore(persistence: persistence ?? JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero)
        }

        @MainActor func preferences() -> PreferencesStore {
            PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .zero)
        }

        func files() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: groupsURL.deletingLastPathComponent().path).sorted()
        }
    }

    @Test func restoreReplacesGroupsAndPreferencesAndKeepsCopies() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let preferences = stores.preferences()
        let old = groups.addGroup(named: "Work")
        groups.addApps([Self.notes], toGroup: old.id)
        groups.addGroup(named: "Games")
        preferences.update { $0.theme = .system }

        let copies = try Self.sampleBackup().restore(to: groups, preferences: preferences)

        #expect(groups.groups == Self.sampleGroups)
        #expect(preferences.preferences == Self.samplePreferences)
        // Written to disk, so a restart shows the same.
        #expect(stores.groups().groups == Self.sampleGroups)
        #expect(stores.preferences().preferences == Self.samplePreferences)
        // The previous files are kept next to the new ones.
        #expect(copies.count == 2)
        let names = try stores.files()
        #expect(names.contains { $0.hasPrefix("groups.pre-import-") && $0.hasSuffix(".json") })
        #expect(names.contains { $0.hasPrefix("preferences.pre-import-") && $0.hasSuffix(".json") })
        let groupsCopy = try #require(copies.first { $0.lastPathComponent.hasPrefix("groups.") })
        let previous = try JSONFileGroupPersistence(fileURL: groupsCopy).loadGroups()
        #expect(previous.map(\.name) == ["Work", "Games"])
        #expect(previous.first?.apps == [Self.notes])
    }

    @Test func theLatestThreeImportCopiesAreKept() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let preferences = stores.preferences()
        groups.addGroup(named: "First")
        preferences.update { $0.theme = .system }
        let folder = stores.groupsURL.deletingLastPathComponent()
        // Three older imports' copies, and an unreadable file kept aside, which must stay.
        for day in ["20200101", "20200102", "20200103"] {
            try Data("[]".utf8).write(to: folder.appending(path: "groups.pre-import-\(day)-000000.json"))
        }
        try Data("{".utf8).write(to: folder.appending(path: "groups.unreadable-20200101-000000.json"))

        try Self.sampleBackup().restore(to: groups, preferences: preferences)

        let names = try stores.files()
        let groupCopies = names.filter { $0.hasPrefix("groups.pre-import-") }
        #expect(groupCopies.count == 3)
        #expect(!names.contains("groups.pre-import-20200101-000000.json"), "the oldest copy goes")
        #expect(names.contains("groups.pre-import-20200102-000000.json"))
        #expect(names.contains("groups.pre-import-20200103-000000.json"))
        #expect(names.contains("groups.unreadable-20200101-000000.json"))
        #expect(names.filter { $0.hasPrefix("preferences.pre-import-") }.count == 1)
    }

    @Test func restoreWithoutSavedFilesMakesNoCopies() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }

        let copies = try Self.sampleBackup(groups: []).restore(to: stores.groups(), preferences: stores.preferences())

        #expect(copies.isEmpty)
        #expect(try stores.files() == ["groups.json", "preferences.json"])
        #expect(stores.groups().groups.isEmpty)
    }

    @Test func restoreCleansUpGroupsLikeEdits() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let shared = UUID()
        let backup = Self.sampleBackup(groups: [
            DockGroup(id: shared, name: "  ", emoji: "", apps: [Self.safari, Self.safari, Self.mail]),
            DockGroup(id: shared, name: "Duplicate ID"),
        ])

        try backup.restore(to: groups, preferences: stores.preferences())

        #expect(groups.groups.count == 1)
        #expect(groups.groups.first?.name == DockGroup.defaultName)
        #expect(groups.groups.first?.emoji == DockGroup.defaultEmoji)
        #expect(groups.groups.first?.apps == [Self.safari, Self.mail])
    }

    // MARK: - Merging

    @Test func mergeAddsNewGroupsAndKeepsCurrentOnesAndPreferences() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let preferences = stores.preferences()
        let work = groups.addGroup(named: "work")
        groups.addApps([Self.notes], toGroup: work.id)
        groups.addGroup(named: "Games")
        preferences.update { $0.theme = .system }
        let preferencesBefore = preferences.preferences
        let currentBefore = groups.groups

        let result = try Self.sampleBackup().merge(into: groups)

        // "Work" is already here as "work" and keeps its own apps; "Notes" is added after.
        #expect(result.addedGroups.map(\.name) == ["Notes"])
        #expect(groups.groups.map(\.name) == ["work", "Games", "Notes"])
        #expect(Array(groups.groups.prefix(2)) == currentBefore)
        #expect(groups.groups.last == Self.sampleGroups[1])
        #expect(preferences.preferences == preferencesBefore)
        // Written to disk, with a safety copy of the previous groups only.
        #expect(stores.groups().groups.map(\.name) == ["work", "Games", "Notes"])
        let copy = try #require(result.copyURL)
        #expect(copy.lastPathComponent.hasPrefix("groups.pre-import-"))
        #expect(try JSONFileGroupPersistence(fileURL: copy).loadGroups() == currentBefore)
        #expect(try !stores.files().contains { $0.hasPrefix("preferences.pre-import-") })
    }

    @Test func mergeKeepsFreeLayoutSlotsAndCleansUpAddedGroups() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let backup = Self.sampleBackup(groups: [
            Self.sampleGroups[0],
            DockGroup(name: "Mail", emoji: "", apps: [Self.mail, Self.mail]),
        ])

        try backup.merge(into: groups)

        #expect(groups.groups.first?.freeLayoutSlots == ["com.apple.safari": 4, "com.apple.mail": 0])
        #expect(groups.groups.last?.apps == [Self.mail])
        #expect(groups.groups.last?.emoji == DockGroup.defaultEmoji)
    }

    @Test func mergeWithNothingNewChangesNothing() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        groups.addGroup(named: "Work")
        groups.addGroup(named: "Notes")
        let before = try stores.files()

        let result = try Self.sampleBackup().merge(into: groups)

        #expect(result.addedGroups.isEmpty)
        #expect(result.copyURL == nil)
        #expect(groups.groups.map(\.name) == ["Work", "Notes"])
        #expect(try stores.files() == before)
    }

    @Test func failedMergeChangesNothing() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups(persistence: FailingSavePersistence(groups: [DockGroup(name: "Kept")]))

        #expect(throws: FailingSavePersistence.Failure.self) {
            try Self.sampleBackup().merge(into: groups)
        }

        #expect(groups.groups.map(\.name) == ["Kept"])
    }

    @Test func failedRestoreChangesNothing() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let persistence = FailingSavePersistence(groups: [DockGroup(name: "Kept")])
        let groups = stores.groups(persistence: persistence)
        let preferences = stores.preferences()
        preferences.update { $0.theme = .system }
        let before = preferences.preferences

        #expect(throws: FailingSavePersistence.Failure.self) {
            try Self.sampleBackup().restore(to: groups, preferences: preferences)
        }

        #expect(groups.groups.map(\.name) == ["Kept"])
        #expect(preferences.preferences == before)
        #expect(stores.preferences().preferences == before)
    }
}

/// Loads a fixed list and refuses to save.
private final class FailingSavePersistence: GroupPersisting {
    struct Failure: Error {}
    let groups: [DockGroup]

    init(groups: [DockGroup]) {
        self.groups = groups
    }

    func loadGroups() throws -> [DockGroup] { groups }
    func saveGroups(_ groups: [DockGroup]) throws { throw Failure() }
    func preserveUnreadableData() throws -> URL? { nil }
}
