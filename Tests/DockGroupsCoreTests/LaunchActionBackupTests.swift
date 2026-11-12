import Foundation
import Testing
@testable import DockGroupsCore

/// Launch actions that come from a file someone may have handed over (threat model D4, T11): a
/// backup's groups, archived groups and templates bring their actions in turned off and needing
/// review, and are written so (`"status": "review", "reason": "imported"`), so they stay off after a
/// restart (launch-action-review-persistence.md). Standalone agents carry the group's actions and
/// check them against the approval file (launch-action-approvals.md).
@Suite("Launch actions: backups, restore and agents")
@MainActor
struct LaunchActionBackupTests {
    static let chromeWork = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")
    static let firefoxDev = LaunchAction.browserProfile(browser: .firefox, profileName: "dev-edition")
    static let braveHome = LaunchAction.browserProfile(browser: .brave, profileName: "Home")
    static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")

    static func website(_ address: String, _ action: LaunchAction?) -> GroupItem {
        var item = GroupItem(websiteURL: URL(string: address)!)
        item.setLaunchAction(action)
        return item
    }

    static let workGroup = DockGroup(name: "Work", apps: [website("https://github.com/cybokron", chromeWork), mail])
    static let oldGroup = DockGroup(name: "Old", apps: [website("https://example.com/", firefoxDev)])
    static let templateGroup = DockGroup(name: "Blueprint", apps: [website("https://youtube.com/", braveHome)])

    static func backup(groups: [DockGroup]? = nil) -> SettingsBackup {
        SettingsBackup(
            appVersion: "0.13.0",
            exportedAt: Date(timeIntervalSince1970: 1_792_000_000),
            groups: groups ?? [workGroup],
            archivedGroups: [ArchivedGroup(group: oldGroup, archivedAt: Date(timeIntervalSince1970: 1_791_000_000))],
            templates: [GroupTemplate(saving: templateGroup, named: "Blueprint")],
            preferences: PopupPreferences()
        )
    }

    static func allItems(_ backup: SettingsBackup) -> [GroupItem] {
        (backup.groups + backup.archivedGroups.map(\.group) + backup.templates.map(\.group)).flatMap(\.apps)
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private struct Stores {
        let directory: TemporaryDirectory
        let groupsURL: URL
        let preferencesURL: URL
        let templates = MemoryTemplatePersistence()

        init() throws {
            directory = try TemporaryDirectory()
            groupsURL = directory.url.appending(components: "DockGroups", "groups.json")
            preferencesURL = directory.url.appending(components: "DockGroups", "preferences.json")
        }

        @MainActor func groups() -> GroupStore {
            GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero)
        }

        @MainActor func preferences() -> PreferencesStore {
            PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .zero)
        }

        @MainActor func templateStore() -> TemplateStore {
            TemplateStore(persistence: templates, saveDelay: .zero)
        }

        func groupsFile() throws -> String {
            try String(contentsOf: groupsURL, encoding: .utf8)
        }
    }

    // MARK: - Reading a backup

    @Test func anExportWritesValidActions() throws {
        let written = Self.text(try Self.backup().encoded())
        #expect(written.contains(#""launchAction""#))
        #expect(written.contains(#""browser" : "chrome""#))
        #expect(written.contains(#""profile" : "dev-edition""#))
        #expect(written.contains(#""browser" : "brave""#))
        #expect(written.components(separatedBy: #""status" : "enabled""#).count - 1 == 3)
    }

    @Test func aBackupsActionsComeInTurnedOff() throws {
        let read = try SettingsBackup.decode(from: Self.backup().encoded())

        #expect(read.disabledLaunchActionCount == 3)
        let items = Self.allItems(read)
        #expect(items.map(\.launchActionSetting) == [
            .needsReview(.imported(Self.chromeWork)), nil,
            .needsReview(.imported(Self.firefoxDev)),
            .needsReview(.imported(Self.braveHome)),
        ])
        #expect(items.allSatisfy { $0.launchAction == nil })
        // The items themselves are kept.
        #expect(read.groups.first?.apps.map(\.bundleIdentifier) == Self.workGroup.apps.map(\.bundleIdentifier))
        // Turned off, they're written so: exporting what was read carries them under review.
        let exported = Self.text(try read.encoded())
        #expect(exported.components(separatedBy: #""reason" : "imported""#).count - 1 == 3)
        #expect(!exported.contains(#""status" : "enabled""#))
        #expect(Self.allItems(try SettingsBackup.decode(from: read.encoded())).map(\.launchActionSetting) == items.map(\.launchActionSetting))
    }

    /// Was "…AndArentWritten": now written under review as invalid, without the forbidden key.
    @Test func aBackupsInvalidActionsComeInForReviewAndAreWrittenSo() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Self.backup(groups: [DockGroup(name: "Work", apps: [Self.website("https://github.com/", nil)])]).encoded()) as? [String: Any])
        var groups = try #require(object["groups"] as? [[String: Any]])
        var apps = try #require(groups[0]["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = ["template": "browserProfile", "browser": "chrome", "profile": "Work", "args": ["--remote-debugging-port=9222"]]
        groups[0]["apps"] = apps
        object["groups"] = groups

        let read = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: object))

        #expect(read.groups.first?.apps.first?.launchActionSetting == .needsReview(.invalid(.forbiddenKey)))
        #expect(read.disabledLaunchActionCount == 3)
        let written = Self.text(try read.encoded())
        #expect(written.contains(#""reason" : "invalid""#))
        #expect(!written.contains("remote-debugging") && !written.contains(#""args""#))
    }

    @Test func aBackupWithoutActionsCountsNone() throws {
        let plain = SettingsBackup(appVersion: "0.13.0", groups: [DockGroup(name: "Work", apps: [Self.mail])], preferences: PopupPreferences())
        let read = try SettingsBackup.decode(from: plain.encoded())
        #expect(read.disabledLaunchActionCount == 0)
        #expect(read.groups == plain.groups)
    }

    // MARK: - Restoring and merging

    /// Was "restoringLeavesNoActionOnDisk": with nothing on disk the item opened plainly after a
    /// restart; the actions are now written under review and stay so when the groups are read again.
    @Test func restoringWritesTheActionsUnderReview() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let templates = stores.templateStore()
        let read = try SettingsBackup.decode(from: Self.backup().encoded())

        try read.restore(to: groups, preferences: stores.preferences(), templates: templates)

        // In memory: off, needing review.
        #expect(groups.groups.first?.apps.first?.launchActionSetting == .needsReview(.imported(Self.chromeWork)))
        #expect(groups.archivedGroups.first?.group.apps.first?.launchActionSetting == .needsReview(.imported(Self.firefoxDev)))
        #expect(templates.templates.first?.group.apps.first?.launchActionSetting == .needsReview(.imported(Self.braveHome)))
        #expect((groups.groups + groups.archivedGroups.map(\.group) + templates.templates.map(\.group)).flatMap(\.apps).allSatisfy { $0.launchAction == nil })
        // On disk: under review, so a restart keeps them off.
        let file = try stores.groupsFile()
        #expect(file.components(separatedBy: #""reason" : "imported""#).count - 1 == 2, "the group's and the archived group's")
        #expect(!file.contains(#""status" : "enabled""#))
        let templatesFile = Self.text(try JSONEncoder().encode(stores.templates.saved))
        #expect(templatesFile.contains(#""reason":"imported""#) && !templatesFile.contains(#""status":"enabled""#))
        let reloaded = stores.groups()
        #expect(reloaded.groups.first?.apps.first?.launchActionSetting == .needsReview(.imported(Self.chromeWork)))
        #expect(reloaded.archivedGroups.first?.group.apps.first?.launchActionSetting == .needsReview(.imported(Self.firefoxDev)))
        #expect(reloaded.groups.first?.apps.first?.launchActionStatus == .imported(Self.chromeWork))
        #expect(reloaded.groups.first?.apps.map(\.bundleIdentifier) == Self.workGroup.apps.map(\.bundleIdentifier))
        let reloadedTemplates = try JSONDecoder().decode([GroupTemplate].self, from: JSONEncoder().encode(stores.templates.saved))
        #expect(reloadedTemplates.first?.group.apps.first?.launchActionSetting == .needsReview(.imported(Self.braveHome)))
    }

    @Test func restoringABackupBuiltInCodeTurnsItsActionsOffToo() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let templates = stores.templateStore()
        // Not read from a file, so `sanitizedForImport` never ran: restoring turns them off anyway.
        let backup = Self.backup()
        #expect(Self.allItems(backup).compactMap(\.launchAction) == [Self.chromeWork, Self.firefoxDev, Self.braveHome])

        try backup.restore(to: groups, preferences: stores.preferences(), templates: templates)

        let restored = (groups.groups + groups.archivedGroups.map(\.group) + templates.templates.map(\.group)).flatMap(\.apps)
        #expect(restored.compactMap(\.launchAction).isEmpty)
        #expect(restored.filter { $0.launchActionNeedsReview }.count == 3)
        #expect(!(try stores.groupsFile()).contains(#""status" : "enabled""#))
        #expect(stores.groups().groups.first?.apps.first?.launchActionSetting == .needsReview(.imported(Self.chromeWork)))
    }

    @Test func mergingTurnsTheAddedActionsOff() throws {
        let stores = try Stores()
        defer { stores.directory.remove() }
        let groups = stores.groups()
        let templates = stores.templateStore()
        // A group of this Mac keeps its own enabled action.
        let local = groups.addGroup(named: "Local")
        groups.addApps([Self.website("https://news.ycombinator.com/", Self.chromeWork)], toGroup: local.id)
        let localAction = groups.groups.first?.apps.first?.launchAction
        #expect(localAction == Self.chromeWork)

        let result = try Self.backup().merge(into: groups, templates: templates)

        #expect(result.groups.addedGroups.map(\.name) == ["Work"])
        #expect(groups.groups.first { $0.name == "Local" }?.apps.first?.launchAction == localAction)
        let added = (result.groups.addedGroups + result.groups.addedArchivedGroups.map(\.group) + result.addedTemplates.map(\.group)).flatMap(\.apps)
        #expect(added.compactMap(\.launchAction).isEmpty)
        #expect(added.filter { $0.launchActionNeedsReview }.count == 3)
        // Only the local action is on disk turned on; the added ones are there under review.
        let file = try stores.groupsFile()
        #expect(file.components(separatedBy: #""status" : "enabled""#).count - 1 == 1)
        #expect(file.components(separatedBy: #""reason" : "imported""#).count - 1 == 2)
        let templatesFile = Self.text(try JSONEncoder().encode(stores.templates.saved))
        #expect(templatesFile.contains(#""reason":"imported""#) && !templatesFile.contains(#""status":"enabled""#))
        let reloaded = stores.groups()
        #expect(reloaded.groups.first { $0.name == "Local" }?.apps.first?.launchAction == localAction)
        #expect(reloaded.groups.first { $0.name == "Work" }?.apps.first?.launchActionSetting == .needsReview(.imported(Self.chromeWork)))
    }

    // MARK: - Standalone agents

    /// Agents carry the group's actions, status included (D11, launch-action-approvals.md); the
    /// agent's launcher checks them against this Mac's approval file like the app's.
    @Test func agentsCarryTheirLaunchActions() throws {
        var group = Self.workGroup
        var imported = AppReference(websiteURL: URL(string: "https://example.com/imported")!, name: "Imported")
        imported.launchActionSetting = .needsReview(.imported(Self.chromeWork))
        group.apps.append(imported)
        let configuration = AgentConfiguration(group: group, preferences: PopupPreferences())
        #expect(configuration.group.apps.map(\.launchActionSetting) == group.apps.map(\.launchActionSetting))
        #expect(Self.text(try configuration.encoded()).contains("launchAction"))

        let read = try AgentConfiguration.decode(from: configuration.encoded())
        #expect(read == configuration)
        #expect(read.group.apps.map(\.launchActionSetting) == group.apps.map(\.launchActionSetting))
        #expect(read.group.apps.last?.launchAction == nil, "one under review stays so")
    }
}
