import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: groups")
@MainActor
struct GroupItemStoreTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!, name: "GitHub")
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)

    private static func file(_ path: String) -> GroupItem {
        GroupItem(fileURL: URL(fileURLWithPath: path), kind: .file)
    }

    private func makeStore(_ persistence: GroupPersisting = CountingPersistence()) -> GroupStore {
        GroupStore(persistence: persistence, saveDelay: .zero)
    }

    @Test func aGroupHoldsEveryKindOnceInOneList() {
        let store = makeStore()
        let group = store.addGroup(named: "Mixed")

        #expect(store.addItems([Self.mail, Self.report, Self.github, Self.projects], toGroup: group.id) == 4)
        // The same location in another case is the same item, as APFS sees it.
        #expect(store.addItems([Self.file("/USERS/me/Documents/q3 report.pdf"), Self.mail], toGroup: group.id) == 0)
        #expect(store.addApps([Self.file("/Users/me/Documents/Plan.key")], toGroup: group.id) == 1)

        #expect(store.group(withID: group.id)?.apps.map(\.kind) == [.application, .file, .website, .folder, .file])
    }

    @Test func filesThatCantBeItemsAreLeftOut() {
        let store = makeStore()
        let group = store.addGroup(named: "Scripts")

        #expect(store.addItems([Self.file("/Users/me/run.command"), Self.file("/Applications/Safari.app"), Self.report], toGroup: group.id) == 1)
        #expect(store.group(withID: group.id)?.apps == [Self.report])
    }

    @Test func reorderingSortingFreeLayoutMovingAndRemovingWorkForEveryKind() {
        let store = makeStore()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        let zip = Self.file("/Users/me/Archive.zip")
        store.addItems([Self.projects, Self.mail, zip, Self.github, Self.report], toGroup: work.id)

        store.sortAppsByName(inGroup: work.id)
        #expect(store.group(withID: work.id)?.apps.map(\.displayName) == ["Archive.zip", "GitHub", "Mail", "Projects", "Q3 Report.pdf"])

        store.moveApp(bundleIdentifier: Self.report.bundleIdentifier, inGroup: work.id, to: 0)
        store.moveApps(inGroup: work.id, fromOffsets: [1], toOffset: 5)
        #expect(store.group(withID: work.id)?.apps == [Self.report, Self.github, Self.mail, Self.projects, zip])

        store.arrangeApps(inGroup: work.id, freeLayoutSlots: [
            Self.projects.normalizedBundleIdentifier: 0, zip.normalizedBundleIdentifier: 7, Self.report.normalizedBundleIdentifier: 3,
        ])
        #expect(store.group(withID: work.id)?.apps.prefix(3).map(\.bundleIdentifier) == [Self.projects, Self.report, zip].map(\.bundleIdentifier))
        #expect(store.group(withID: work.id)?.freeLayoutSlots[zip.normalizedBundleIdentifier] == 7)

        #expect(store.moveApp(bundleIdentifier: zip.bundleIdentifier, fromGroup: work.id, toGroup: home.id))
        #expect(store.group(withID: home.id)?.apps == [zip])
        #expect(store.group(withID: work.id)?.freeLayoutSlots[zip.normalizedBundleIdentifier] == nil)

        store.removeApp(bundleIdentifier: Self.projects.bundleIdentifier.uppercased(), fromGroup: work.id)
        #expect(store.group(withID: work.id)?.apps.contains(Self.projects) == false)
        #expect(store.group(withID: work.id)?.freeLayoutSlots == [Self.report.normalizedBundleIdentifier: 3])
    }

    @Test func detailsChangeWithOneSaveAndOnlyWhenTheyDiffer() {
        let persistence = CountingPersistence()
        let store = makeStore(persistence)
        let group = store.addGroup(named: "Work")
        store.addItems([Self.mail, Self.report], toGroup: group.id)
        let saves = persistence.saveCount
        let details = ItemDetails(alias: "Quarterly report", tags: ["finance"], notes: "Fridays")

        #expect(store.updateDetails(details, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(persistence.saveCount == saves + 1)
        #expect(store.group(withID: group.id)?.apps.last?.details == details)
        #expect(store.group(withID: group.id)?.apps.last?.displayName == "Quarterly report")

        // The same details again, or an unknown item or group: nothing is saved, so a standalone
        // group's app isn't rebuilt.
        #expect(!store.updateDetails(ItemDetails(alias: " Quarterly report ", tags: ["#finance"], notes: "Fridays\n"), ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(!store.updateDetails(details, ofItem: "com.example.none", inGroup: group.id))
        #expect(!store.updateDetails(details, ofItem: Self.report.bundleIdentifier, inGroup: UUID()))
        #expect(persistence.saveCount == saves + 1)
    }

    @Test func movingAndRemovingKeepDetails() {
        let store = makeStore()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        var report = Self.report
        report.details = ItemDetails(tags: ["finance"])
        store.addItems([report, Self.mail], toGroup: work.id)

        store.moveApp(bundleIdentifier: report.bundleIdentifier, inGroup: work.id, to: 1)
        #expect(store.group(withID: work.id)?.apps.last == report)
        #expect(store.moveApp(bundleIdentifier: report.bundleIdentifier, fromGroup: work.id, toGroup: home.id))
        #expect(store.group(withID: home.id)?.apps == [report])
    }

    @Test func locatingAMovedFileKeepsItsDetailsPlaceAndCell() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        let store = makeStore(JSONFileGroupPersistence(fileURL: fileURL))
        let group = store.addGroup(named: "Work")
        var report = Self.report
        report.details = ItemDetails(alias: "Quarterly report", tags: ["finance"])
        store.addItems([Self.mail, report, Self.projects], toGroup: group.id)
        store.updateGroup(group.id) { $0.freeLayoutSlots = [report.normalizedBundleIdentifier: 6, Self.mail.normalizedBundleIdentifier: 0] }
        let moved = URL(fileURLWithPath: "/Users/me/Archive/Q3 Report (final).pdf")

        #expect(store.relinkItem(report.bundleIdentifier, inGroup: group.id, to: moved))

        let relinked = try #require(store.group(withID: group.id)?.apps[1])
        #expect(relinked.bundleIdentifier == "file:///Users/me/Archive/Q3%20Report%20(final).pdf")
        #expect(relinked.kind == .file)
        #expect(relinked.name == "Q3 Report (final).pdf")
        #expect(relinked.details == report.details)
        #expect(store.group(withID: group.id)?.freeLayoutSlots == [relinked.normalizedBundleIdentifier: 6, Self.mail.normalizedBundleIdentifier: 0])
        #expect(makeStore(JSONFileGroupPersistence(fileURL: fileURL)).group(withID: group.id)?.apps[1] == relinked)
    }

    @Test func locatingRefusesDuplicatesAppsAndPrograms() {
        let store = makeStore()
        let group = store.addGroup(named: "Work")
        let plan = Self.file("/Users/me/Plan.key")
        store.addItems([Self.mail, Self.report, plan], toGroup: group.id)
        let before = store.groups

        // Another item of the group is already there.
        #expect(!store.relinkItem(Self.report.bundleIdentifier, inGroup: group.id, to: URL(fileURLWithPath: "/Users/me/plan.KEY")))
        // Only files and folders can be located; and a file can't become a program.
        #expect(!store.relinkItem(Self.mail.bundleIdentifier, inGroup: group.id, to: URL(fileURLWithPath: "/Users/me/x.pdf")))
        #expect(!store.relinkItem(Self.report.bundleIdentifier, inGroup: group.id, to: URL(fileURLWithPath: "/Users/me/run.command")))
        #expect(!store.relinkItem("file:///Users/me/none.pdf", inGroup: group.id, to: URL(fileURLWithPath: "/Users/me/x.pdf")))
        #expect(store.groups == before)
        // Its own location (another case) is fine.
        #expect(store.relinkItem(plan.bundleIdentifier, inGroup: group.id, to: URL(fileURLWithPath: "/Users/me/Plan.key")))
    }
}

@Suite("Group items: no processes")
@MainActor
struct GroupItemProcessTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)

    @Test func closeAllAndHideAllLeaveFilesAndFoldersAlone() {
        let applications = EverythingRuns()
        let terminator = GroupTerminator(applications: applications, ownProcessIdentifier: 1)
        let group = DockGroup(name: "Work", apps: [Self.report, Self.mail, Self.projects])

        #expect(terminator.closeAll(group, mode: .graceful).quit == [Self.mail])
        #expect(terminator.hideAll(group).hidden == [Self.mail])
        #expect(terminator.hasRunningApps(DockGroup(name: "Files", apps: [Self.report, Self.projects])) == false)
        #expect(applications.asked.allSatisfy { $0 == Self.mail.bundleIdentifier })
    }

    @Test func filesAndFoldersAreNeverRunningNorCountedAsLaunches() {
        #expect(RunningApplicationLookup.runningApplications(identifiedBy: "file:///System/Applications/Calculator.app/").isEmpty)
        #expect(RunningApplicationLookup.runningApplications(identifiedBy: Self.report.bundleIdentifier).isEmpty)
        #expect(!UsageTracker.isTracked(bundleIdentifier: Self.report.bundleIdentifier))
        #expect(!UsageTracker.isTracked(bundleIdentifier: "FILE:///Users/me/Projects/"))
        var tracker = UsageTracker()
        let recorded = tracker.recordLaunch(of: Self.projects, at: Date())
        #expect(!recorded)
        #expect(tracker.stats.isEmpty)
    }
}

/// Records how often the groups are saved.
private final class CountingPersistence: GroupPersisting {
    private(set) var saveCount = 0
    private var saved: [DockGroup] = []

    func loadGroups() throws -> [DockGroup] { saved }

    func saveGroups(_ groups: [DockGroup]) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}

/// Says every app asked about is running, and records which were asked about.
@MainActor
private final class EverythingRuns: RunningApplicationsProviding {
    final class App: QuittableApplication {
        let processIdentifier: pid_t = 42
        let isTerminated = false
        let isHidden = false
        func hide() -> Bool { true }
        func terminate() -> Bool { true }
        func forceTerminate() -> Bool { true }
    }

    private(set) var asked: [String] = []

    func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] {
        asked.append(bundleIdentifier)
        return [App()]
    }
}
