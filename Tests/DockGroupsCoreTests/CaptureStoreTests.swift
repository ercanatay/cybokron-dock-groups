import Combine
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("App item gate")
struct AppItemPolicyTests {
    @Test(arguments: ["com.apple.Safari", "com.example.app-name_2", "COM.EXAMPLE.APP", "x"])
    func bundleIdentifiersAreKeptWithTheirAppBundleLocation(identifier: String) {
        let item = AppReference(bundleIdentifier: identifier, name: "App", path: "/Applications/App.app")
        #expect(AppItemPolicy.isBundleIdentifier(identifier))
        #expect(AppItemPolicy.sanitized(item) == item)
    }

    @Test func aFallbackLocationThatIsntAnAppBundleIsDropped() {
        for path in ["/Users/me/run.command", "/bin/sh", "/Applications", "relative/App.app", "/Applications/../tmp/x.app"] {
            let item = AppReference(bundleIdentifier: "com.example.app", name: "App", path: path)
            #expect(AppItemPolicy.sanitized(item) == AppReference(bundleIdentifier: "com.example.app", name: "App"), "\(path)")
        }
    }

    @Test func anAppIdentifiedByLocationMustBeAnAppBundle() {
        let bundle = AppReference(bundleIdentifier: "/Applications/Games/Old Tool.app", name: "Old Tool", path: "/Applications/Games/Old Tool.app")
        #expect(AppItemPolicy.sanitized(bundle) == bundle)
        for location in ["/Users/me/run.command", "/bin/sh", "/Applications/Games", "/Applications/../Evil.app"] {
            #expect(AppItemPolicy.sanitized(AppReference(bundleIdentifier: location, name: "Evil", path: location)) == nil, "\(location)")
        }
    }

    @Test func anIdentityWithASlashOrColonIsntAnApp() {
        for identity in ["com.example/evil", "file:///Users/me/run.command", "https://example.com", "com.example:app"] {
            #expect(!AppItemPolicy.isBundleIdentifier(identity))
            #expect(AppItemPolicy.sanitized(AppReference(bundleIdentifier: identity, name: "Evil")) == nil, "\(identity)")
        }
    }

    @Test func websitesFilesAndFoldersAreLeftToTheirOwnRules() throws {
        let website = AppReference(websiteURL: try WebsiteAddress.parse("https://github.com"))
        let file = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/run.command"), kind: .file)
        let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true), kind: .folder)
        #expect(AppItemPolicy.sanitized(website) == website)
        // `FileItemPolicy` refuses the script; this gate doesn't decide for files.
        #expect(AppItemPolicy.sanitized(file) == file)
        #expect(AppItemPolicy.sanitized(folder) == folder)
    }

    /// The backup's rule, now `AppItemPolicy`'s: the same items are left out or cleaned up.
    @Test func backupsLeaveOutTheSameApps() throws {
        let group = DockGroup(name: "Imported", apps: [
            AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            AppReference(bundleIdentifier: "com.example.app", name: "App", path: "/Users/me/run.command"),
            AppReference(bundleIdentifier: "/Users/me/run.command", name: "Script", path: "/Users/me/run.command"),
            AppReference(bundleIdentifier: "com.example/evil", name: "Evil"),
            AppReference(bundleIdentifier: "/Applications/Games/Old Tool.app", name: "Old Tool", path: "/Applications/Games/Old Tool.app"),
        ])
        let backup = SettingsBackup(appVersion: "0.10.0", groups: [group], preferences: PopupPreferences())
        let read = try SettingsBackup.decode(from: backup.encoded())

        #expect(read.leftOutItemCount == 2)
        #expect(read.groups.first?.apps == [
            AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            AppReference(bundleIdentifier: "com.example.app", name: "App"),
            AppReference(bundleIdentifier: "/Applications/Games/Old Tool.app", name: "Old Tool", path: "/Applications/Games/Old Tool.app"),
        ])
        #expect(read.groups.first?.apps == group.apps.compactMap(AppItemPolicy.sanitized))
    }
}

@Suite("Capture: the store")
@MainActor
struct GroupStoreCaptureTests {
    private static let xcode = AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
    private static let terminal = AppReference(bundleIdentifier: "com.apple.Terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app")

    @Test func aNewGroupWithItemsIsOneChangeAndOneSave() {
        let persistence = CountingGroupPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        store.addGroup(named: "Coding")
        var changes = 0
        let subscription = store.$groups.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }
        let saves = persistence.saveCount

        let group = store.addGroup(named: "  Xcode +2 ", items: [Self.xcode, Self.safari, Self.terminal])

        #expect(changes == 1)
        #expect(persistence.saveCount == saves + 1)
        #expect(store.groups.last == group)
        #expect(store.groups.count == 2)
        #expect(group.name == "Xcode +2")
        #expect(group.apps == [Self.xcode, Self.safari, Self.terminal])
        #expect(!group.isStandalone && group.shortcut == nil && group.emoji == DockGroup.defaultEmoji)
    }

    @Test func aTypedNameIsKeptAndABlankOneGetsTheDefault() {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        store.addGroup(named: "Work")
        #expect(store.addGroup(named: "Work", items: []).name == "Work")
        #expect(store.addGroup(named: "   ", items: [Self.xcode]).name == "New Group")
        #expect(store.addGroup(named: "", items: []).name == "New Group 2")
    }

    @Test func itemsPassTheGateAndEachComesOnce() {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let items = [
            Self.xcode,
            AppReference(bundleIdentifier: "COM.APPLE.DT.XCODE", name: "Xcode again"),
            AppReference(bundleIdentifier: "/Users/me/run.command", name: "Script", path: "/Users/me/run.command"),
            AppReference(bundleIdentifier: "com.example.app", name: "App", path: "/Users/me/run.command"),
            AppReference(bundleIdentifier: "file:///Users/me/evil.command", name: "Evil"),
            GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/run.command"), kind: .file),
        ]
        let group = store.addGroup(named: "Mixed", items: items)
        #expect(group.apps == [Self.xcode, AppReference(bundleIdentifier: "com.example.app", name: "App")])
    }

    /// Every caller of `addItems` passes the gate now — Add Apps…, Add a Running App, capture.
    @Test func addingItemsToAGroupPassesTheSameGate() throws {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let work = store.addGroup(named: "Work", items: [Self.safari])
        let added = store.addItems([
            AppReference(bundleIdentifier: "/Users/me/run.command", name: "Script", path: "/Users/me/run.command"),
            AppReference(bundleIdentifier: "com.example.app", name: "App", path: "/bin/sh"),
            Self.xcode,
            AppReference(bundleIdentifier: "com.apple.safari", name: "Safari"),
        ], toGroup: work.id)

        #expect(added == 2)
        #expect(store.group(withID: work.id)?.apps == [Self.safari, AppReference(bundleIdentifier: "com.example.app", name: "App"), Self.xcode])
    }

    @Test func itemsFromAnAddAppsPanelAndARunningAppPassUnchanged() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bundle = try directory.makeAppBundle(named: "Tool", info: ["CFBundleIdentifier": "com.example.tool", "CFBundleName": "Tool"])
        let script = try directory.makeScriptAppBundle(named: "Wrapper")
        let fromPanel = try [AppReference(applicationURL: bundle), AppReference(applicationURL: script)]
        let fromRunningApp = AppReference(bundleIdentifier: "com.apple.Terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app")
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let group = store.addGroup(named: "Tools")

        #expect(store.addItems(fromPanel + [fromRunningApp], toGroup: group.id) == 3)
        #expect(store.group(withID: group.id)?.apps == fromPanel + [fromRunningApp])
    }

    /// Add Open Apps… appends in the order captured; Free Layout cells of the group stay.
    @Test func addingCapturedAppsKeepsTheOrderAndTheFreeLayout() throws {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let group = store.addGroup(named: "Work", items: [Self.safari])
        store.arrangeApps(inGroup: group.id, freeLayoutSlots: ["com.apple.safari": 3])
        let snapshot = OpenAppsSnapshot(apps: [CaptureApps.terminal, CaptureApps.safari, CaptureApps.xcode], windows: CaptureApps.windows(onScreen: [103, 102, 101]))
        let current = try #require(store.group(withID: group.id))
        let plan = CapturePlanner.plan(snapshot, settings: CaptureSettings(), target: .group(group.id), targetItems: current.apps)

        #expect(plan.defaultSelection == ["com.apple.terminal", "com.apple.dt.xcode"])
        #expect(store.addItems(plan.defaultItems, toGroup: group.id) == 2)
        let updated = try #require(store.group(withID: group.id))
        #expect(updated.apps.map(\.name) == ["Safari", "Terminal", "Xcode"])
        #expect(updated.freeLayoutSlots["com.apple.safari"] == 3)
    }
}
