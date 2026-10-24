import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Launch options: delays")
@MainActor
struct DelayedLaunchesTests {
    private let workspace = OpenerRecordingWorkspace()
    private let sleeper = FakeSleeper()
    private let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
    private let pending: DelayedLaunches
    private let launcher: GroupLauncher
    private let reports = ReportRecorder()

    init() {
        let store = self.store
        pending = DelayedLaunches(sleeper: sleeper) { store.group(withID: $0) }
        launcher = GroupLauncher(workspace: workspace, locator: ScriptedLocator(), catalog: FakeCatalog(), pendingLaunches: pending)
        let reports = self.reports
        pending.onFinished = { reports.reports.append($0) }
        workspace.installed = ["com.apple.Xcode", "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Music"]
    }

    private static let xcode = AppReference(bundleIdentifier: "com.apple.Xcode", name: "Xcode")
    private static let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack").launching(after: 3)
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail").launching(after: 3)
    private static let music = AppReference(bundleIdentifier: "com.apple.Music", name: "Music").launching(after: 10)

    /// A group in the store with these items.
    private func group(_ items: [GroupItem]) -> DockGroup {
        let group = store.addGroup(named: "Work")
        store.addItems(items, toGroup: group.id)
        return store.group(withID: group.id)!
    }

    @Test func openAllOpensTheRestNowAndTheDelayedItemsLater() async {
        let group = group([Self.slack, Self.xcode, Self.music, Self.mail])

        let report = await launcher.openAll(group)

        #expect(report.entries.map(\.outcome) == [.scheduled(seconds: 3), .launched, .scheduled(seconds: 10), .scheduled(seconds: 3)])
        #expect(report.problems.isEmpty && report.scheduled.count == 3)
        #expect(workspace.events == ["launch:com.apple.Xcode"])
        #expect(report.summary == "Opened 1 app in “Work”. 3 more open in a few seconds.")
        await settle { sleeper.sleepingCount == 2 }
        // One wait per delay, counted from Open All.
        #expect(sleeper.requested.sorted() == [3, 10])
        #expect(pending.pendingCount(of: group.id) == 3)

        sleeper.wake(upTo: 3)
        await settle { workspace.events.count == 3 }
        // Slack and Mail open side by side, then Music.
        #expect(Set(workspace.events.dropFirst()) == ["launch:com.tinyspeck.slackmacgap", "launch:com.apple.mail"])
        #expect(reports.reports.isEmpty, "reported once, when the last delayed item opened")
        #expect(pending.pendingCount(of: group.id) == 1)

        sleeper.wake(upTo: 10)
        await settle { !reports.reports.isEmpty }
        #expect(workspace.events.last == "launch:com.apple.Music")
        #expect(reports.reports.count == 1)
        #expect(Set(reports.reports[0].entries.map(\.app.name)) == ["Slack", "Mail", "Music"])
        #expect(reports.reports[0].problems.isEmpty)
        #expect(!pending.hasPending)
    }

    @Test func aDelayedItemIsCheckedWhenItsTimeComes() async {
        let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file).launching(after: 5)
        let group = group([report])

        _ = await launcher.openAll(group)
        await settle { sleeper.sleepingCount == 1 }
        // The file isn't there any more (the locator finds nothing).
        sleeper.wakeAll()
        await settle { !reports.reports.isEmpty }

        #expect(reports.reports.first?.entries.map(\.outcome) == [.notFound])
        #expect(workspace.events.isEmpty)
    }

    @Test func itemsRemovedOrChangedMeanwhileDontOpen() async {
        let group = group([Self.slack, Self.mail, Self.music])
        _ = await launcher.openAll(group)
        await settle { sleeper.sleepingCount == 2 }

        store.removeApp(bundleIdentifier: Self.slack.bundleIdentifier, fromGroup: group.id)
        store.updateLaunchOptions(ItemLaunchOptions(delay: 30), ofItem: Self.mail.bundleIdentifier, inGroup: group.id)
        sleeper.wakeAll()
        await settle { !reports.reports.isEmpty }

        #expect(workspace.events == ["launch:com.apple.Music"])
        #expect(reports.reports.first?.entries.map(\.app.name) == ["Music"])
    }

    @Test func aDeletedGroupOpensNothing() async {
        let group = group([Self.slack])
        _ = await launcher.openAll(group)
        await settle { sleeper.sleepingCount == 1 }
        store.deleteGroup(group.id)
        sleeper.wakeAll()
        await settle { !pending.hasPending }
        #expect(workspace.events.isEmpty && reports.reports.isEmpty)
    }

    @Test func cancellingAGroupLeavesTheOthers() async {
        let work = group([Self.slack])
        let home = store.addGroup(named: "Home")
        store.addItems([Self.music], toGroup: home.id)
        _ = await launcher.openAll(work)
        _ = await launcher.openAll(store.group(withID: home.id)!)
        await settle { sleeper.sleepingCount == 2 }

        pending.cancel(group: work.id)
        #expect(pending.pendingCount(of: work.id) == 0)
        #expect(pending.pendingCount(of: home.id) == 1)
        sleeper.wakeAll()
        await settle { !reports.reports.isEmpty }

        #expect(workspace.events == ["launch:com.apple.Music"])
        pending.cancelAll()
        #expect(!pending.hasPending)
    }

    @Test func hideAllAndCloseAllCancelTheGroupsDelayedItems() async {
        let apps = FakeRunningApps()
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: 1, listing: apps, pendingLaunches: pending)
        let work = group([Self.slack])
        let home = store.addGroup(named: "Home")
        store.addItems([Self.music], toGroup: home.id)

        _ = await launcher.openAll(work)
        _ = await launcher.openAll(store.group(withID: home.id)!)
        _ = terminator.hideAll(work)
        #expect(pending.pendingCount(of: work.id) == 0 && pending.pendingCount(of: home.id) == 1)
        _ = terminator.closeAll(store.group(withID: home.id)!, mode: .graceful)
        #expect(!pending.hasPending)

        sleeper.wakeAll()
        await settle { false }
        #expect(workspace.events.isEmpty && reports.reports.isEmpty)
    }

    @Test func cancellingAfterSomeOpenedReportsThose() async {
        let group = group([Self.slack, Self.music])
        _ = await launcher.openAll(group)
        await settle { sleeper.sleepingCount == 2 }
        sleeper.wake(upTo: 3)
        await settle { workspace.events.count == 1 }

        pending.cancel(group: group.id)
        // Slack's batch may still be finishing: it's reported once it's done.
        await settle { !reports.reports.isEmpty }

        #expect(reports.reports.first?.entries.map(\.app.name) == ["Slack"])
        sleeper.wakeAll()
        await settle { false }
        #expect(workspace.events == ["launch:com.tinyspeck.slackmacgap"])
        #expect(reports.reports.count == 1)
    }

    @Test func withoutDelayedLaunchesEveryItemOpensRightAway() async {
        // As in versions without delays, and as the app is until it hands its launcher one.
        let launcher = GroupLauncher(workspace: workspace, locator: ScriptedLocator(), catalog: FakeCatalog())
        let report = await launcher.openAll(DockGroup(name: "Work", apps: [Self.slack, Self.xcode]))
        #expect(report.entries.map(\.outcome) == [.launched, .launched])
        #expect(report.scheduled.isEmpty)
        #expect(sleeper.requested.isEmpty)
    }

    @Test func scheduledItemsArentProblems() {
        #expect(!LaunchReport.Outcome.scheduled(seconds: 3).isProblem)
        #expect(LaunchReport.Outcome.scheduled(seconds: 3).isScheduled)
        #expect(!LaunchReport.Outcome.launched.isScheduled)
        let report = LaunchReport(groupName: "Work", entries: [
            .init(app: Self.xcode, outcome: .notFound),
            .init(app: Self.slack, outcome: .scheduled(seconds: 3)),
        ])
        #expect(report.summary == "Couldn't open Xcode. 1 more opens in a few seconds.")
        // Without delayed items the summaries are as before.
        #expect(LaunchReport(groupName: "Work", entries: [.init(app: Self.xcode, outcome: .launched)]).summary == "Opened the app in “Work”.")
    }
}

@Suite("Launch options: Start and Finish")
@MainActor
struct DelayedLaunchesSwitchingTests {
    @Test func startCancelsEveryDelayedItemAndFinishTheGroups() async throws {
        let sleeper = FakeSleeper()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
        let pending = DelayedLaunches(sleeper: sleeper) { store.group(withID: $0) }
        let workspace = OpenerRecordingWorkspace()
        workspace.installed = ["com.tinyspeck.slackmacgap", "com.apple.Music"]
        let launcher = GroupLauncher(workspace: workspace, locator: ScriptedLocator(), catalog: FakeCatalog(), pendingLaunches: pending)
        let apps = FakeRunningApps()
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: 1, listing: apps, pendingLaunches: pending)
        let switcher = ContextSwitcher(
            store: store,
            preferences: PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero),
            session: ContextSession(),
            launcher: launcher,
            terminator: terminator,
            applications: apps,
            questions: GroupQuitRequests(prompt: FakeQuitPrompt(answer: false)) { group, mode in terminator.closeAll(group, mode: mode) }
        )
        let design = store.addGroup(named: "Design")
        store.addItems([AppReference(bundleIdentifier: "com.apple.Music", name: "Music").launching(after: 5)], toGroup: design.id)
        let coding = store.addGroup(named: "Coding")
        store.addItems([AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack").launching(after: 3)], toGroup: coding.id)

        _ = await launcher.openAll(store.group(withID: design.id)!)
        #expect(pending.pendingCount(of: design.id) == 1)

        let started = try await switcher.start(coding.id, trigger: .userAction)
        #expect(pending.pendingCount(of: design.id) == 0, "starting another group cancels it")
        #expect(pending.pendingCount(of: coding.id) == 1, "the started group's own are scheduled")
        #expect(started.summary == "Started “Coding”. 1 more item opens in a few seconds.")

        _ = try await switcher.finish(coding.id, trigger: .userAction)
        #expect(!pending.hasPending)
        sleeper.wakeAll()
        await settle { false }
        #expect(workspace.events.isEmpty)
    }
}

@MainActor
private final class ReportRecorder {
    var reports: [LaunchReport] = []
}
