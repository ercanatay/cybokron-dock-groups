import Foundation
import Testing
@testable import DockGroupsCore

/// Launch actions that come from a file someone may have handed over (threat model D4, T11): a
/// backup's groups, archived groups and templates bring their actions in turned off and needing
/// review, and those aren't written again. Standalone agents carry none.
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
        // Turned off, they aren't written again: exporting what was read carries none.
        #expect(!Self.text(try read.encoded()).contains("launchAction"))
    }

    @Test func aBackupsInvalidActionsComeInForReviewAndArentWritten() throws {
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
        #expect(!written.contains("launchAction"))
        #expect(!written.contains("remote-debugging"))
    }

    @Test func aBackupWithoutActionsCountsNone() throws {
        let plain = SettingsBackup(appVersion: "0.13.0", groups: [DockGroup(name: "Work", apps: [Self.mail])], preferences: PopupPreferences())
        let read = try SettingsBackup.decode(from: plain.encoded())
        #expect(read.disabledLaunchActionCount == 0)
        #expect(read.groups == plain.groups)
    }

    // MARK: - Restoring and merging

    @Test func restoringLeavesNoActionOnDisk() throws {
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
        // On disk: nothing, so a restart has no action at all.
        #expect(!(try stores.groupsFile()).contains("launchAction"))
        #expect(!Self.text(try JSONEncoder().encode(stores.templates.saved)).contains("launchAction"))
        let reloaded = stores.groups()
        #expect(reloaded.groups.first?.apps.first?.launchActionSetting == nil)
        #expect(reloaded.groups.first?.apps.map(\.bundleIdentifier) == Self.workGroup.apps.map(\.bundleIdentifier))
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
        #expect(!(try stores.groupsFile()).contains("launchAction"))
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
        // Only the local action is on disk.
        #expect(try stores.groupsFile().components(separatedBy: "\"launchAction\"").count - 1 == 1)
        #expect(!Self.text(try JSONEncoder().encode(stores.templates.saved)).contains("launchAction"))
    }

    // MARK: - Standalone agents

    @Test func agentsCarryNoLaunchAction() throws {
        let configuration = AgentConfiguration(group: Self.workGroup, preferences: PopupPreferences())
        #expect(configuration.group.apps.allSatisfy { $0.launchActionSetting == nil })
        #expect(configuration.group.apps.map(\.bundleIdentifier) == Self.workGroup.apps.map(\.bundleIdentifier))
        #expect(!Self.text(try configuration.encoded()).contains("launchAction"))

        // A config file someone wrote one into: read without it.
        var object = try #require(JSONSerialization.jsonObject(with: configuration.encoded()) as? [String: Any])
        var group = try #require(object["group"] as? [String: Any])
        var apps = try #require(group["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = ["template": "browserProfile", "browser": "chrome", "profile": "Work"]
        group["apps"] = apps
        object["group"] = group
        let read = try AgentConfiguration.decode(from: JSONSerialization.data(withJSONObject: object))
        #expect(read.group.apps.allSatisfy { $0.launchActionSetting == nil })
        #expect(read == configuration)
    }
}
