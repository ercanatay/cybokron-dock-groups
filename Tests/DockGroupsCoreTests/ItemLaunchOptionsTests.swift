import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Launch options: the model")
struct ItemLaunchOptionsTests {
    private static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true), kind: .folder)
    private static let app = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")

    private func decode(_ json: String) throws -> GroupItem {
        try JSONDecoder().decode(GroupItem.self, from: Data(json.utf8))
    }

    private func object(_ item: GroupItem) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    }

    @Test func delaysStayWithinAMinute() {
        #expect(ItemLaunchOptions(delay: 5).delay == 5)
        #expect(ItemLaunchOptions(delay: -3).delay == 0)
        #expect(ItemLaunchOptions(delay: 600).delay == ItemLaunchOptions.maximumDelay)
        #expect(ItemLaunchOptions.allowedDelays == [0, 1, 2, 3, 5, 10, 15, 30, 60])
        #expect(ItemLaunchOptions().isEmpty)
        #expect(!ItemLaunchOptions(delay: 1).isEmpty)
        #expect(!ItemLaunchOptions(opener: .app("com.apple.Preview")).isEmpty)
    }

    @Test func openersAreBundleIdentifiersOnly() {
        #expect(ItemOpener(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code")?.normalizedBundleIdentifier == "com.microsoft.vscode")
        for bad in ["", "/Applications/Terminal.app", "file:///Applications/Terminal.app", "com.apple.Terminal; rm -rf ~", "com.apple.términal", "com apple", String(repeating: "a", count: 256)] {
            #expect(ItemOpener(bundleIdentifier: bad, name: "x") == nil, "\(bad)")
        }
        #expect(ItemOpener(bundleIdentifier: "com.example.app", name: "  Two\nlines\t ")?.name == "Two lines")
        #expect(ItemOpener(bundleIdentifier: "com.example.app", name: " ")?.name == "com.example.app")
        #expect(ItemOpener(bundleIdentifier: "com.example.app", name: String(repeating: "n", count: 200))?.name.count == ItemOpener.maximumNameLength)
    }

    @Test func appsNeverHaveAnOpener() {
        var app = Self.app
        app.launch = ItemLaunchOptions(delay: 5, opener: .app("com.apple.Terminal"))
        #expect(app.launch == ItemLaunchOptions(delay: 5))
        #expect(ItemLaunchOptions(delay: 2, opener: .app("com.apple.Preview")).allowed(for: .application) == ItemLaunchOptions(delay: 2))
        var folder = Self.folder
        folder.launch = ItemLaunchOptions(opener: .app("com.apple.Terminal"))
        #expect(folder.launch.opener?.bundleIdentifier == "com.apple.Terminal")
    }

    @Test func optionsAreWrittenFlatAndOnlyWhenSet() throws {
        #expect(Set(try object(Self.folder).keys) == ["bundleIdentifier", "kind", "name"])
        let folder = Self.folder.launching(after: 3, with: .app("com.microsoft.VSCode", "Visual Studio Code"))
        let saved = try object(folder)
        #expect(saved["launchDelay"] as? Int == 3)
        #expect(saved["openWith"] as? [String: String] == ["bundleIdentifier": "com.microsoft.VSCode", "name": "Visual Studio Code"])
        #expect(try JSONDecoder().decode(GroupItem.self, from: JSONEncoder().encode(folder)) == folder)
        #expect(Set(try object(Self.app.launching(after: 5)).keys) == ["bundleIdentifier", "name", "launchDelay"])
    }

    @Test func unreadableOptionsFallBackOneByOne() throws {
        let item = try decode(#"""
        { "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "kind": "folder", "name": "cybokron",
          "launchDelay": "soon", "openWith": { "bundleIdentifier": "com.microsoft.VSCode" }, "tags": ["dev"] }
        """#)
        #expect(item.launch == ItemLaunchOptions(opener: .app("com.microsoft.VSCode")))
        #expect(item.details.tags == ["dev"])

        for openWith in ["42", #""com.microsoft.VSCode""#, #"{ "name": "No identifier" }"#, #"{ "bundleIdentifier": "/bin/sh", "name": "Shell" }"#, #"{ "bundleIdentifier": "" }"#] {
            let decoded = try decode(#"{ "bundleIdentifier": "https://github.com", "kind": "website", "name": "GitHub", "launchDelay": 3.5, "openWith": \#(openWith) }"#)
            #expect(decoded.launch.isEmpty, "\(openWith)")
            #expect(decoded.isWebsite)
        }
        #expect(try decode(#"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "launchDelay": 3600 }"#).launch.delay == 60)
        #expect(try decode(#"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "launchDelay": -5 }"#).launch.delay == 0)
    }

    @Test func anAppsSavedOpenerIsDropped() throws {
        let item = try decode(#"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "launchDelay": 2, "openWith": { "bundleIdentifier": "com.apple.Terminal", "name": "Terminal" } }"#)
        #expect(item.launch == ItemLaunchOptions(delay: 2))
        // Also when a file item couldn't be read and stays as an app that can't be found.
        let broken = try decode(#"{ "bundleIdentifier": "file:///Users/me/../x.txt", "kind": "file", "name": "x", "openWith": { "bundleIdentifier": "com.apple.TextEdit" } }"#)
        #expect(broken.kind == .application && broken.launch.opener == nil)
    }

    @Test func aGroupsFileWithLaunchOptionsIsSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        try Data(LaunchOptionsFixtures.groupsFile.utf8).write(to: fileURL)
        let persistence = JSONFileGroupPersistence(fileURL: fileURL)

        let groups = try persistence.loadGroups()

        #expect(groups == [LaunchOptionsFixtures.group])
        #expect(groups[0].apps.map(\.launch.delay) == [0, 3, 0, 5, 10])
        #expect(groups[0].apps.map { $0.launch.opener?.bundleIdentifier } == [nil, "com.microsoft.VSCode", "com.google.Chrome", nil, "com.apple.Preview"])
        try persistence.saveGroups(groups)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == LaunchOptionsFixtures.groupsFile)
    }

    @Test func groupsWithoutLaunchOptionsAreSavedAsBy070() throws {
        // The 0.7.0 fixtures have none; their bytes are checked by `Version070CompatibilityTests`.
        #expect(Version070Fixtures.codingGroup.apps.allSatisfy { $0.launch.isEmpty })
        #expect(!Version070Fixtures.groupsFile.contains("launchDelay") && !Version070Fixtures.groupsFile.contains("openWith"))
    }
}

@Suite("Launch options: groups, backups and standalone groups")
@MainActor
struct ItemLaunchOptionsStoreTests {
    private static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true), kind: .folder)
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Report.pdf"), kind: .file)
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")

    @Test func optionsChangeWithOneSaveAndOnlyWhenTheyDiffer() {
        let persistence = MemoryGroupPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addItems([Self.mail, Self.folder], toGroup: group.id)
        let saves = persistence.saveCount
        let options = ItemLaunchOptions(delay: 3, opener: .app("com.microsoft.VSCode"))

        #expect(store.updateLaunchOptions(options, ofItem: Self.folder.bundleIdentifier, inGroup: group.id))
        #expect(store.group(withID: group.id)?.apps.last?.launch == options)
        #expect(!store.updateLaunchOptions(options, ofItem: Self.folder.bundleIdentifier, inGroup: group.id))
        #expect(!store.updateLaunchOptions(options, ofItem: "com.example.none", inGroup: group.id))
        #expect(persistence.saveCount == saves + 1)

        // An app keeps its delay but no opener.
        #expect(store.updateLaunchOptions(ItemLaunchOptions(delay: 5, opener: .app("com.apple.Terminal")), ofItem: Self.mail.bundleIdentifier, inGroup: group.id))
        #expect(store.group(withID: group.id)?.apps.first?.launch == ItemLaunchOptions(delay: 5))
    }

    @Test func movingAndLocatingKeepTheOptions() {
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        let report = Self.report.launching(after: 10, with: .app("com.apple.Preview"))
        store.addItems([report, Self.mail], toGroup: work.id)

        #expect(store.relinkItem(report.bundleIdentifier, inGroup: work.id, to: URL(fileURLWithPath: "/Users/me/Archive/Report.pdf")))
        let relinked = store.group(withID: work.id)?.apps.first
        #expect(relinked?.launch == report.launch)

        #expect(store.moveApp(bundleIdentifier: relinked!.bundleIdentifier, fromGroup: work.id, toGroup: home.id))
        #expect(store.group(withID: home.id)?.apps.first?.launch == report.launch)
    }

    @Test func backupsKeepOptionsButNotRunnersFromAnotherMac() throws {
        let terminalFolder = Self.folder.launching(after: 2, with: .app("com.apple.Terminal", "Terminal"))
        let iTermFolder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/other"), kind: .folder).launching(with: .app("com.googlecode.iterm2"))
        let pythonFile = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/notes.txt"), kind: .file).launching(with: .app("org.python.PythonLauncher"))
        let warpWebsite = AppReference(websiteURL: URL(string: "https://example.com")!).launching(with: .app("dev.warp.Warp-Stable"))
        let applet = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.txt"), kind: .file).launching(with: .app("com.apple.ScriptEditor.id.MyApplet"))
        let preview = Self.report.launching(after: 5, with: .app("com.apple.Preview", "Preview"))
        let group = DockGroup(name: "Work", apps: [terminalFolder, iTermFolder, pythonFile, warpWebsite, applet, preview, Self.mail.launching(after: 3)])
        let backup = SettingsBackup(appVersion: "0.8.0", groups: [group], preferences: PopupPreferences())

        let imported = try SettingsBackup.decode(from: backup.encoded())

        let items = try #require(imported.groups.first?.apps)
        #expect(items.count == 7, "items are kept; only their opener goes")
        #expect(items.map { $0.launch.opener?.bundleIdentifier } == [nil, nil, nil, nil, nil, "com.apple.Preview", nil])
        #expect(items.map(\.launch.delay) == [2, 0, 0, 0, 0, 5, 3])
        #expect(imported.resetLaunchOptionCount == 5)
        #expect(imported.leftOutItemCount == 0)
        #expect(SettingsRestoreSummary(backup: imported, currentGroups: []).resetLaunchOptionCount == 5)
        // A backup being written counts nothing.
        #expect(backup.resetLaunchOptionCount == 0)
    }

    @Test func aStandaloneGroupIsRebuiltForLaunchOptionsOnly() throws {
        let group = DockGroup(name: "Work", apps: [Self.mail, Self.folder], isStandalone: true)
        var delayed = group
        delayed.apps[0].launch = ItemLaunchOptions(delay: 5)
        let base = AgentConfiguration(group: group, preferences: PopupPreferences())
        let changed = AgentConfiguration(group: delayed, preferences: PopupPreferences())

        // The agent's Open All applies them, so its configuration carries them.
        #expect(changed.group.apps[0].launch.delay == 5)
        #expect(changed != base)
        let desired = DesiredAgent(configuration: changed, folderName: "work.app", sourceDigest: "d")
        let installed = InstalledAgent(bundleURL: URL(fileURLWithPath: "/tmp/Agents/work.app"), bundleIdentifier: desired.bundleIdentifier, configuration: base, sourceDigest: "d")
        #expect(AgentPlanner.plan(desired: [desired], installed: [installed], runningBundleIdentifiers: []).builds.map(\.reason) == [.outdated])
        #expect(try AgentConfiguration.decode(from: changed.encoded()) == changed)
    }
}
