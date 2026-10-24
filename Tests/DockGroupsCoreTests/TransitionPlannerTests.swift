import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: planning Start")
struct TransitionPlannerStartTests {
    private static func app(_ id: String, pid: pid_t, hidden: Bool = false, regular: Bool = true) -> RunningAppSnapshot {
        RunningAppSnapshot(processIdentifier: pid, identity: id, name: id, isHidden: hidden, isRegular: regular)
    }

    private static let figma = app("com.figma.desktop", pid: 11)
    private static let sketch = app("com.bohemiancoding.sketch3", pid: 12)
    private static let slack = app("com.tinyspeck.slackmacgap", pid: 13)
    private static let xcode = app("com.apple.dt.xcode", pid: 21)
    private static let music = app("com.apple.music", pid: 31)
    private static let finder = app("com.apple.finder", pid: 41)
    private static let ownApp = app("com.cybokron.dockgroups", pid: 51)
    private static let agent = app(AgentIdentity.bundleIdentifier(for: UUID()).lowercased(), pid: 52)
    private static let helper = app("com.example.helper", pid: 61, regular: false)

    private static let running = [figma, sketch, slack, xcode, music, finder, ownApp, agent, helper]

    private static func design(_ extra: [String] = []) -> DockGroup {
        .of("Design", ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.tinyspeck.slackmacgap"] + extra)
    }

    private static func coding(_ onStart: GroupSwitching.OnStart = .hidePreviousGroup) -> DockGroup {
        .of("Coding", ["com.apple.dt.Xcode", "com.tinyspeck.slackmacgap"], switching: GroupSwitching(onStart: onStart))
    }

    private func start(
        _ target: DockGroup,
        previous: DockGroup? = TransitionPlannerStartTests.design(),
        running: [RunningAppSnapshot] = TransitionPlannerStartTests.running,
        protected: [GroupItem] = [],
        trigger: TransitionTrigger = .userAction
    ) -> TransitionPlan {
        TransitionPlanner.start(target, previous: previous, running: running, protected: ProtectedApps(protected), trigger: trigger)
    }

    @Test func startHidesThePreviousGroupsAppsButNotTheSharedOnesByDefault() {
        let plan = start(Self.coding())

        #expect(plan.groupName == "Coding")
        #expect(plan.hide.map(\.app) == [Self.figma, Self.sketch])
        #expect(plan.hide.allSatisfy { $0.reason == .inPreviousGroup })
        #expect(plan.quit.isEmpty)
        #expect(plan.kept == [.init(app: Self.slack, reason: .shared)])
        #expect(plan.open?.name == "Coding")
        #expect(plan.otherGroupName == "Design")
        #expect(!plan.requiresConfirmation)
    }

    @Test func withoutAPreviousGroupStartOnlyOpens() {
        let target = Self.coding(.quitPreviousGroup)
        // No group is current, or the group being started is.
        for previous in [nil, target] as [DockGroup?] {
            let plan = start(target, previous: previous)
            #expect(plan.hide.isEmpty && plan.quit.isEmpty && plan.kept.isEmpty)
            #expect(plan.open?.id == target.id)
            #expect(plan.next == target.id)
            #expect(plan.otherGroupName == nil)
        }
    }

    @Test func leavingOthersOpenTouchesNothing() {
        let plan = start(Self.coding(.leaveOthers))
        #expect(plan.hide.isEmpty && plan.quit.isEmpty && plan.unhide.isEmpty && plan.kept.isEmpty)
        #expect(plan.open != nil)
    }

    @Test func quittingThePreviousGroupQuitsGracefullyAndAsksLinksAndSiri() {
        let plan = start(Self.coding(.quitPreviousGroup))
        #expect(plan.quit.map(\.app) == [Self.figma, Self.sketch])
        #expect(plan.hide.isEmpty)
        #expect(plan.kept.map(\.app) == [Self.slack])
        #expect(!plan.requiresConfirmation, "the user's own click doesn't ask")
        for trigger in [TransitionTrigger.link, .intent] {
            #expect(start(Self.coding(.quitPreviousGroup), trigger: trigger).requiresConfirmation)
        }
        // Hiding settings never ask, whoever asked for them.
        #expect(!start(Self.coding(), trigger: .link).requiresConfirmation)
    }

    @Test func aFocusNeverQuitsAndNeverAsks() {
        let plan = start(Self.coding(.quitPreviousGroup), trigger: .focus)
        #expect(plan.quit.isEmpty)
        #expect(plan.hide.map(\.app) == [Self.figma, Self.sketch])
        #expect(!plan.requiresConfirmation)
    }

    @Test func hidingAllOtherAppsSparesTheGroupProtectedAppsAndThisApp() {
        let plan = start(Self.coding(.hideAllOtherApps), protected: [AppReference(bundleIdentifier: "com.apple.Music", name: "Music")])

        // Finder may be hidden; this app, its groups' apps and helpers are never touched.
        #expect(plan.hide.map(\.app) == [Self.figma, Self.sketch, Self.finder])
        #expect(plan.hide.allSatisfy { $0.reason == .notInStartedGroup })
        #expect(plan.kept == [
            .init(app: Self.music, reason: .protected),
            .init(app: Self.ownApp, reason: .alwaysProtected),
            .init(app: Self.agent, reason: .alwaysProtected),
        ])
        #expect(!plan.hide.contains { $0.app == Self.helper } && !plan.kept.contains { $0.app == Self.helper })
    }

    @Test func protectedAppsAreNeverHiddenOrQuit() {
        let protected = [AppReference(bundleIdentifier: "COM.FIGMA.DESKTOP", name: "Figma")]
        for onStart in [GroupSwitching.OnStart.hidePreviousGroup, .quitPreviousGroup] {
            let plan = start(Self.coding(onStart), protected: protected)
            #expect(!plan.hide.contains { $0.app == Self.figma } && !plan.quit.contains { $0.app == Self.figma })
            #expect(plan.kept.first == .init(app: Self.figma, reason: .protected))
        }
    }

    @Test func finderAndThisAppAreNeverQuit() {
        let previous = DockGroup.of("Files", ["com.apple.finder", "com.cybokron.dockgroups", "com.figma.Desktop"])
        let plan = start(Self.coding(.quitPreviousGroup), previous: previous)
        #expect(plan.quit.map(\.app) == [Self.figma])
        #expect(plan.kept == [.init(app: Self.finder, reason: .alwaysProtected), .init(app: Self.ownApp, reason: .alwaysProtected)])
        // Hiding them is allowed for Finder only.
        let hiding = start(Self.coding(), previous: previous)
        #expect(hiding.hide.map(\.app) == [Self.finder, Self.figma])
        #expect(hiding.kept == [.init(app: Self.ownApp, reason: .alwaysProtected)])
    }

    @Test func hiddenAppsArentHiddenAgainButAreStillQuit() {
        let hiddenFigma = Self.app("com.figma.desktop", pid: 11, hidden: true)
        let running = [hiddenFigma, Self.sketch]
        #expect(start(Self.coding(), running: running).hide.map(\.app) == [Self.sketch])
        #expect(start(Self.coding(.quitPreviousGroup), running: running).quit.map(\.app) == [hiddenFigma, Self.sketch])
    }

    @Test func listsFollowTheGroupsOrderAndEveryInstance() {
        // Sketch is listed first in the group, and two copies of Figma run.
        let previous = DockGroup.of("Design", ["com.bohemiancoding.sketch3", "com.figma.Desktop", "com.figma.desktop"])
        let secondFigma = Self.app("com.figma.desktop", pid: 14)
        let plan = start(Self.coding(), previous: previous, running: [Self.figma, secondFigma, Self.sketch, Self.figma])
        #expect(plan.hide.map(\.app.processIdentifier) == [12, 11, 14])
    }

    @Test func websitesFilesAndFoldersHaveNoProcess() {
        let previous = DockGroup(name: "Mixed", apps: [
            AppReference(websiteURL: URL(string: "https://figma.com")!),
            GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.pdf"), kind: .file),
        ])
        let impostor = Self.app("https://figma.com", pid: 70)
        #expect(start(Self.coding(), previous: previous, running: [impostor]).hide.isEmpty)
    }

    @Test func appsWithoutABundleIdentifierMatchByLocation() {
        let tool = AppReference(bundleIdentifier: "/Users/me/Tools/Builder.app", name: "Builder")
        let running = Self.app(RunningApplicationLookup.normalizedLocation(of: URL(fileURLWithPath: "/Users/me/Tools/Builder.app")), pid: 80)
        let plan = start(Self.coding(), previous: DockGroup(name: "Tools", apps: [tool]), running: [running])
        #expect(plan.hide.map(\.app) == [running])
    }

    @Test func hidingInsteadOfQuittingKeepsReasonsAndSkipsHiddenApps() {
        let hiddenFigma = Self.app("com.figma.desktop", pid: 11, hidden: true)
        let plan = start(Self.coding(.quitPreviousGroup), running: [hiddenFigma, Self.sketch], trigger: .link)
        let hiding = TransitionPlanner.hidingInsteadOfQuitting(plan)
        #expect(hiding.quit.isEmpty)
        #expect(hiding.hide == [.init(app: Self.sketch, reason: .inPreviousGroup)])
        #expect(!hiding.requiresConfirmation)
        #expect(hiding.open == plan.open)
    }
}

@Suite("Switching: planning Finish")
struct TransitionPlannerFinishTests {
    private static func app(_ id: String, pid: pid_t, hidden: Bool = false) -> RunningAppSnapshot {
        RunningAppSnapshot(processIdentifier: pid, identity: id, name: id, isHidden: hidden)
    }

    private static let xcode = app("com.apple.dt.xcode", pid: 21)
    private static let simulator = app("com.apple.iphonesimulator", pid: 22)
    private static let slack = app("com.tinyspeck.slackmacgap", pid: 13)
    private static let figma = app("com.figma.desktop", pid: 11, hidden: true)
    private static let sketch = app("com.bohemiancoding.sketch3", pid: 12)

    private static func coding(_ onFinish: GroupSwitching.OnFinish = .hideApps) -> DockGroup {
        .of("Coding", ["com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.tinyspeck.slackmacgap"], switching: GroupSwitching(onFinish: onFinish))
    }

    private static let design = DockGroup.of("Design", ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.tinyspeck.slackmacgap"])
    private static let running = [xcode, simulator, slack, figma, sketch]

    private func finish(_ group: DockGroup, next: DockGroup? = TransitionPlannerFinishTests.design, protected: [GroupItem] = [], trigger: TransitionTrigger = .userAction) -> TransitionPlan {
        TransitionPlanner.finish(group, next: next, running: Self.running, protected: ProtectedApps(protected), trigger: trigger)
    }

    @Test func finishHidesTheGroupAndShowsThePreviousOneAgain() {
        let plan = finish(Self.coding())

        #expect(plan.hide.map(\.app) == [Self.xcode, Self.simulator])
        #expect(plan.hide.allSatisfy { $0.reason == .inFinishedGroup })
        #expect(plan.kept == [.init(app: Self.slack, reason: .shared)])
        // Only hidden apps are shown again; the first of the group comes to the front.
        #expect(plan.unhide == [.init(app: Self.figma, reason: .inNextGroup)])
        #expect(plan.front == Self.figma)
        #expect(plan.open == nil, "Finish never launches anything")
        #expect(plan.next == Self.design.id)
        #expect(plan.otherGroupName == "Design")
    }

    @Test func withoutANextGroupNothingIsShown() {
        let plan = finish(Self.coding(), next: nil)
        #expect(plan.hide.map(\.app) == [Self.xcode, Self.simulator, Self.slack])
        #expect(plan.unhide.isEmpty && plan.front == nil && plan.next == nil)
    }

    @Test func quittingAsksLinksAndSiriAndAFocusHidesInstead() {
        let plan = finish(Self.coding(.quitApps))
        #expect(plan.quit.map(\.app) == [Self.xcode, Self.simulator])
        #expect(!plan.requiresConfirmation)
        #expect(finish(Self.coding(.quitApps), trigger: .intent).requiresConfirmation)
        let focus = finish(Self.coding(.quitApps), trigger: .focus)
        #expect(focus.quit.isEmpty && focus.hide.map(\.app) == [Self.xcode, Self.simulator])
    }

    @Test func leavingAppsOpenOnlyShowsTheNextGroup() {
        let plan = finish(Self.coding(.leaveApps))
        #expect(plan.hide.isEmpty && plan.quit.isEmpty && plan.kept.isEmpty)
        #expect(plan.unhide.map(\.app) == [Self.figma])
    }

    @Test func protectedAppsStay() {
        let plan = finish(Self.coding(.quitApps), protected: [AppReference(bundleIdentifier: "com.apple.iphonesimulator", name: "Simulator")])
        #expect(plan.quit.map(\.app) == [Self.xcode])
        #expect(plan.kept.contains(.init(app: Self.simulator, reason: .protected)))
    }

    @Test func finishingTheGroupItGoesBackToIsJustFinishing() {
        let group = Self.coding()
        let plan = finish(group, next: group)
        #expect(plan.next == nil && plan.unhide.isEmpty)
    }
}
