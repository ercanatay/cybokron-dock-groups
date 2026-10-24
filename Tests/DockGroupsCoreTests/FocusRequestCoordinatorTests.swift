import Foundation
import Testing
@testable import DockGroupsCore

/// Records what a Focus asked the app to do: "start:<group>:<trigger>",
/// "finish:<group>:<trigger>:<shows previous>", "openAll:<group>", "popup:<group>".
@MainActor
private final class FakeFocusHandler: FocusRequestHandling {
    var groups: [DockGroup]
    var current: DockGroup.ID?
    var trigger: TransitionTrigger?
    private(set) var calls: [String] = []

    init(groups: [DockGroup]) {
        self.groups = groups
    }

    private func name(_ id: DockGroup.ID) -> String {
        groups.first { $0.id == id }?.name ?? id.uuidString
    }

    func group(withID id: DockGroup.ID) -> DockGroup? { groups.first { $0.id == id } }
    var currentGroupID: DockGroup.ID? { current }
    var currentGroupStartTrigger: TransitionTrigger? { trigger }

    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async {
        calls.append("start:\(name(id)):\(trigger.rawValue)")
        current = id
        self.trigger = trigger
    }

    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async {
        calls.append("finish:\(name(id)):\(trigger.rawValue):\(showsPrevious)")
        if current == id {
            current = nil
            self.trigger = nil
        }
    }

    func openAllItems(of group: DockGroup) async { calls.append("openAll:\(group.name)") }
    func showPopup(of group: DockGroup) { calls.append("popup:\(group.name)") }
}

@Suite("Focus: turning Focus calls into actions")
@MainActor
struct FocusRequestCoordinatorTests {
    private let sleeper = FakeSleeper()
    private let clock = TestClock()
    private let coordinator: FocusRequestCoordinator
    private let handler: FakeFocusHandler
    private static let coding = DockGroup.of("Coding", ["com.apple.dt.Xcode"])
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private static let home = DockGroup.of("Home", ["com.apple.Music"])

    init() {
        let clock = self.clock
        coordinator = FocusRequestCoordinator(sleeper: sleeper, clock: { clock.now })
        handler = FakeFocusHandler(groups: [Self.coding, Self.design, Self.home])
        coordinator.handler = handler
    }

    /// The Focus filter is called with `requests`, quickly one after the other; then their wait
    /// ends and the result is carried out.
    private func focus(_ requests: FocusRequest...) async {
        for request in requests {
            // Each call waits once; a wait that a later call replaced is never woken for nothing.
            let waits = sleeper.requested.count
            coordinator.receive(request)
            await settle { sleeper.requested.count > waits }
        }
        sleeper.wakeAll()
        await settle { coordinator.isIdle }
    }

    private static func on(_ group: DockGroup, _ action: FocusGroupAction = .start, finishes: Bool = false) -> FocusRequest {
        FocusRequest(groupID: group.id, action: action, finishesWhenFocusEnds: finishes)
    }

    @Test func aFocusStartsItsGroupAfterASecondAndNeverAsTheUser() async {
        coordinator.receive(Self.on(Self.coding))
        await settle { sleeper.sleepingCount > 0 }
        #expect(handler.calls.isEmpty, "nothing before the wait ends")
        #expect(sleeper.requested == [1])
        sleeper.wakeAll()
        await settle { coordinator.isIdle }
        #expect(handler.calls == ["start:Coding:focus"])
        #expect(coordinator.lastRequest == Self.on(Self.coding))
    }

    @Test func callsInARowComeDownToTheLast() async {
        // From one Focus to another…
        await focus(Self.on(Self.coding), Self.on(Self.design))
        #expect(handler.calls == ["start:Design:focus"])
        // …and off, then on again.
        await focus(.focusEnded, Self.on(Self.home))
        #expect(handler.calls == ["start:Design:focus", "start:Home:focus"])
    }

    @Test func theFocusEndingFinishesItsGroupOnlyWhenItsFilterSaysSo() async {
        await focus(Self.on(Self.coding, finishes: true))
        await focus(.focusEnded)
        #expect(handler.calls == ["start:Coding:focus", "finish:Coding:focus:true"])

        // Off by default: the group stays.
        await focus(Self.on(Self.design))
        await focus(.focusEnded)
        #expect(handler.calls.last == "start:Design:focus")
        #expect(handler.current == Self.design.id)
    }

    @Test func theFocusEndingLeavesAGroupTheUserStartedSince() async {
        await focus(Self.on(Self.coding, finishes: true))
        // The user starts Home from the popup.
        handler.current = Self.home.id
        handler.trigger = .userAction
        await focus(.focusEnded)
        #expect(handler.calls == ["start:Coding:focus"])
        // A Focus request that only shows a popup finishes nothing either when it ends.
        await focus(Self.on(Self.design, .showPopup, finishes: true))
        await focus(.focusEnded)
        #expect(handler.calls == ["start:Coding:focus", "popup:Design"])
    }

    @Test func switchingFocusFinishesThePreviousGroupFirstOnlyWhenAsked() async {
        await focus(Self.on(Self.coding, finishes: true))
        await focus(Self.on(Self.home))
        // Finished without showing the group before it: Home is about to start.
        #expect(handler.calls == ["start:Coding:focus", "finish:Coding:focus:false", "start:Home:focus"])

        await focus(Self.on(Self.design))
        #expect(handler.calls.suffix(1) == ["start:Design:focus"], "Home's filter didn't ask to finish it")

        // Another Focus naming the same group doesn't finish it before starting it again.
        await focus(Self.on(Self.coding, finishes: true))
        clock.advance(10)
        await focus(Self.on(Self.coding, finishes: true))
        #expect(handler.calls.suffix(2) == ["start:Coding:focus", "start:Coding:focus"])
    }

    @Test func callsBeforeTheAppIsReadyWaitAndOnlyTheLastIsCarriedOut() async {
        let early = FocusRequestCoordinator(sleeper: sleeper)
        early.receive(Self.on(Self.coding))
        await settle { sleeper.sleepingCount > 0 }
        sleeper.wakeAll()
        await settle { early.isIdle }
        early.receive(Self.on(Self.design, .openAll))
        await settle { sleeper.sleepingCount > 0 }
        sleeper.wakeAll()
        await settle { early.isIdle }

        let late = FakeFocusHandler(groups: [Self.coding, Self.design])
        early.handler = late
        await settle { early.isIdle && !late.calls.isEmpty }
        #expect(late.calls == ["openAll:Design"])
    }

    @Test func openAllAndShowPopupAskedAgainWithinThreeSecondsAreDoneOnce() async {
        await focus(Self.on(Self.design, .openAll))
        clock.advance(1)
        await focus(Self.on(Self.design, .openAll))
        #expect(handler.calls == ["openAll:Design"])
        clock.advance(5)
        await focus(Self.on(Self.design, .openAll))
        await focus(Self.on(Self.design, .showPopup))
        #expect(handler.calls == ["openAll:Design", "openAll:Design", "popup:Design"])
    }

    @Test func aGroupThatNoLongerExistsDoesNothing() async {
        await focus(FocusRequest(groupID: UUID(), action: .start, finishesWhenFocusEnds: true))
        await focus(.focusEnded)
        #expect(handler.calls.isEmpty)
    }
}

/// The coordinator with the real `ContextSwitcher`: what a Focus does to apps.
@MainActor
private final class SwitcherFocusHandler: FocusRequestHandling {
    let rig: SwitchingRig
    private(set) var reports: [TransitionReport] = []

    init(rig: SwitchingRig) {
        self.rig = rig
    }

    func group(withID id: DockGroup.ID) -> DockGroup? { rig.store.group(withID: id) }
    var currentGroupID: DockGroup.ID? { rig.session.current }
    var currentGroupStartTrigger: TransitionTrigger? { rig.session.startTrigger }

    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async {
        if let report = try? await rig.switcher.start(id, trigger: trigger) { reports.append(report) }
    }

    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async {
        if let report = try? await rig.switcher.finish(id, trigger: trigger, showsPrevious: showsPrevious) { reports.append(report) }
    }

    func openAllItems(of group: DockGroup) async {}
    func showPopup(of group: DockGroup) {}
}

@Suite("Focus: what a Focus does to apps")
@MainActor
struct FocusTransitionTests {
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    /// Set to quit everything it can: a Focus must hide instead.
    private static let coding = DockGroup.of(
        "Coding",
        ["com.apple.dt.Xcode"],
        switching: GroupSwitching(onStart: .quitPreviousGroup, onFinish: .quitApps)
    )

    @Test func aFocusNeverQuitsAppsAndNeverAsks() async throws {
        let rig = SwitchingRig(groups: [Self.design, Self.coding])
        rig.apps.run("com.figma.Desktop", name: "Figma")
        rig.apps.run("com.apple.dt.Xcode", name: "Xcode")
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
        let sleeper = FakeSleeper()
        let coordinator = FocusRequestCoordinator(sleeper: sleeper)
        let handler = SwitcherFocusHandler(rig: rig)
        coordinator.handler = handler
        let deliver = { (request: FocusRequest) in
            coordinator.receive(request)
            await settle { sleeper.sleepingCount > 0 }
            sleeper.wakeAll()
            await settle { coordinator.isIdle }
        }
        let before = rig.log.events.count

        await deliver(FocusRequest(groupID: Self.coding.id, action: .start, finishesWhenFocusEnds: true))
        rig.clock.advance(10)
        await deliver(.focusEnded)

        let events = Array(rig.log.events.dropFirst(before))
        #expect(!events.contains { $0.hasPrefix("quit:") || $0.hasPrefix("force:") })
        #expect(events.contains("hide:com.figma.desktop"), "the previous group is hidden instead")
        #expect(events.contains("hide:com.apple.dt.xcode"), "finishing hides instead")
        #expect(rig.transitionPrompt.asked.isEmpty, "a Focus never asks")
        #expect(handler.reports.map(\.plan.trigger) == [.focus, .focus])
        #expect(rig.session.current == Self.design.id, "finishing went back to Design")
    }

    @Test func aFocusAndAShortcutsAutomationStartingTheGroupStartItOnce() async throws {
        let rig = SwitchingRig(groups: [Self.design, Self.coding])
        let sleeper = FakeSleeper()
        let coordinator = FocusRequestCoordinator(sleeper: sleeper)
        let handler = SwitcherFocusHandler(rig: rig)
        coordinator.handler = handler
        coordinator.receive(FocusRequest(groupID: Self.coding.id))
        await settle { sleeper.sleepingCount > 0 }
        sleeper.wakeAll()
        await settle { coordinator.isIdle }
        rig.clock.advance(1)

        // The automation's Start Group, a second later.
        let automation = try await rig.switcher.start(Self.coding.id, trigger: .intent)

        #expect(handler.reports.map(\.outcome) == [.done])
        #expect(automation.outcome == .repeated)
        #expect(rig.workspace.launched == ["com.apple.dt.Xcode"], "launched once")
    }

    @Test func finishingWithoutShowingThePreviousGroup() async throws {
        let rig = SwitchingRig(groups: [Self.design, .of("Home", ["com.apple.Music"])])
        rig.apps.run("com.figma.Desktop", name: "Figma", hidden: true)
        let home = rig.store.groups[1]
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
        _ = try await rig.switcher.start(home.id, trigger: .focus)
        let before = rig.log.events.count

        let report = try await rig.switcher.finish(home.id, trigger: .focus, showsPrevious: false)

        #expect(!rig.log.events.dropFirst(before).contains { $0.hasPrefix("unhide:") || $0.hasPrefix("front:") })
        #expect(report.plan.next == nil)
        #expect(rig.session.current == nil)
    }
}

@Suite("Focus: the filter's values and what Settings says")
struct FocusFilterModelTests {
    @Test func actionsKeepTheirRawValues() throws {
        // macOS keeps these in its Focus settings: they must never change.
        #expect(FocusGroupAction.allCases.map(\.rawValue) == ["start", "openAll", "showPopup"])
        let encoded = try JSONEncoder().encode(FocusGroupAction.allCases)
        #expect(String(data: encoded, encoding: .utf8) == #"["start","openAll","showPopup"]"#)
        #expect(try JSONDecoder().decode([FocusGroupAction].self, from: encoded) == FocusGroupAction.allCases)
        #expect(FocusGroupAction(rawValue: "quit") == nil, "there is no quitting action")
    }

    @Test func aRequestDefaultsToStartingWithoutFinishing() {
        let request = FocusRequest(groupID: UUID())
        #expect(request.action == .start && !request.finishesWhenFocusEnds)
        #expect(FocusRequest.focusEnded.groupID == nil && !FocusRequest.focusEnded.finishesWhenFocusEnds)
    }

    @Test func theAppsFilterOffersTheSameActionsWithTheSameDefaults() throws {
        let url = LocalizationTests.root.appending(path: "Sources/CybokronDockGroups/Intents/GroupFocusFilter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("enum FocusFilterAction: String, AppEnum {\n    case start\n    case openAll\n    case showPopup\n"))
        #expect(source.contains("@Parameter(title: \"When This Focus Turns On\", default: .start)"))
        #expect(source.contains("@Parameter(title: \"Finish the Group When This Focus Turns Off\", default: false)"))
        let delegate = try String(contentsOf: LocalizationTests.root.appending(path: "Sources/CybokronDockGroups/App/AppDelegate.swift"), encoding: .utf8)
        #expect(delegate.contains("FocusFilterBridge.coordinator.handler = self"))
    }

    @Test func settingsSaysWhatTheCurrentFocusAsksFor() {
        let coding = DockGroup.of("Coding", [])
        let groups = [coding]
        #expect(FocusFilterStatus(nil, groups: groups) == .none)
        #expect(FocusFilterStatus(.focusEnded, groups: groups).text == "No Focus asks Cybokron Dock Groups for anything right now.")
        #expect(FocusFilterStatus(FocusRequest(groupID: UUID()), groups: groups).text == "The current Focus names a group that no longer exists.")
        #expect(FocusFilterStatus(FocusRequest(groupID: coding.id), groups: groups).text == "The current Focus starts “Coding”.")
        #expect(FocusFilterStatus(FocusRequest(groupID: coding.id, finishesWhenFocusEnds: true), groups: groups).text
            == "The current Focus starts “Coding”. When it turns off, the group is finished: its apps are hidden.")
        #expect(FocusFilterStatus(FocusRequest(groupID: coding.id, action: .openAll, finishesWhenFocusEnds: true), groups: groups).text
            == "The current Focus opens the items of “Coding”.", "only a started group is finished")
        #expect(FocusFilterStatus(FocusRequest(groupID: coding.id, action: .showPopup), groups: groups).text == "The current Focus shows the popup of “Coding”.")
    }
}
