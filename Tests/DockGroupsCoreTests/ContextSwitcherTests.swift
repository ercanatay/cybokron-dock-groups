import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: carrying Start and Finish out")
@MainActor
struct ContextSwitcherTests {
    private static let design = DockGroup.of("Design", ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.tinyspeck.slackmacgap"])
    private static func coding(_ switching: GroupSwitching = GroupSwitching()) -> DockGroup {
        .of("Coding", ["com.apple.dt.Xcode", "com.tinyspeck.slackmacgap"], switching: switching)
    }

    /// Design, then Coding with `switching`; Design's apps and Slack running.
    private func rig(_ switching: GroupSwitching = GroupSwitching(), protected: [GroupItem] = [], answer: TransitionConfirmation.Answer = .quit) -> (SwitchingRig, DockGroup, DockGroup) {
        let coding = Self.coding(switching)
        let rig = SwitchingRig(groups: [Self.design, coding], protected: protected, answer: answer)
        rig.apps.run("com.figma.Desktop", name: "Figma")
        rig.apps.run("com.bohemiancoding.sketch3", name: "Sketch")
        rig.apps.run("com.tinyspeck.slackmacgap", name: "Slack")
        return (rig, Self.design, coding)
    }

    /// Makes Design current, then forgets what that did.
    private func startDesign(_ rig: SwitchingRig) async throws {
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
    }

    @Test func startHidesThePreviousGroupThenOpensItsItemsAndBecomesCurrent() async throws {
        let (rig, design, coding) = rig()
        try await startDesign(rig)
        let before = rig.log.events.count

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        // Hidden first, in the group's order; then the items open (apps launch side by side).
        let events = Array(rig.log.events.dropFirst(before))
        #expect(Array(events.prefix(2)) == ["hide:com.figma.desktop", "hide:com.bohemiancoding.sketch3"])
        #expect(Set(events.dropFirst(2)) == ["launch:com.apple.dt.Xcode", "launch:com.tinyspeck.slackmacgap"])
        #expect(events.count == 4)
        #expect(report.outcome == .done)
        #expect(report.hidden.done.map(\.name) == ["Figma", "Sketch"])
        #expect(report.kept.map(\.app.name) == ["Slack"])
        #expect(report.launch?.entries.count == 2)
        #expect(rig.session.current == coding.id)
        #expect(rig.session.previous == design.id)
        #expect(report.summary == "Started “Coding”: opened 2 items and hid 2 apps of “Design”.")
    }

    @Test func finishHidesTheGroupAndShowsThePreviousOneAgain() async throws {
        let (rig, design, coding) = rig()
        try await startDesign(rig)
        _ = try await rig.switcher.start(coding.id, trigger: .userAction)
        rig.apps.run("com.apple.dt.Xcode", name: "Xcode")
        let before = rig.log.events.count

        let report = try await rig.switcher.finish(coding.id, trigger: .userAction)

        let events = Array(rig.log.events.dropFirst(before))
        #expect(events == ["hide:com.apple.dt.xcode", "unhide:com.figma.desktop", "unhide:com.bohemiancoding.sketch3", "front:com.figma.desktop"])
        #expect(!events.contains { $0.hasPrefix("launch:") || $0.hasPrefix("quit:") })
        #expect(rig.session.current == design.id)
        #expect(report.summary == "Finished “Coding”: hid 1 app and showed “Design” again.")
    }

    @Test func finishingAGroupThatIsntCurrentShowsNothing() async throws {
        let (rig, design, _) = rig()
        let report = try await rig.switcher.finish(design.id, trigger: .userAction)
        #expect(report.hidden.done.count == 3)
        #expect(report.shown.done.isEmpty && report.plan.next == nil)
        #expect(rig.session.current == nil)
    }

    @Test func theUsersClickQuitsGracefullyWithoutAsking() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(rig.log.events(withPrefix: "quit:") == ["com.figma.desktop", "com.bohemiancoding.sketch3"])
        #expect(rig.log.events(withPrefix: "force:").isEmpty, "never forced")
        #expect(report.quit.done.count == 2)
    }

    @Test func aLinkAsksBeforeQuitting() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)

        let report = try await rig.switcher.start(coding.id, trigger: .link)

        #expect(rig.transitionPrompt.asked == [TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma", "Sketch"])])
        #expect(rig.log.events(withPrefix: "quit:").count == 2)
        #expect(report.outcome == .done)
    }

    @Test func aLinkThatHidesDoesntAsk() async throws {
        let (rig, _, coding) = rig()
        try await startDesign(rig)
        _ = try await rig.switcher.start(coding.id, trigger: .link)
        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(rig.log.events(withPrefix: "hide:").count == 2)
    }

    @Test func hideInsteadHides() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup), answer: .hideInstead)
        try await startDesign(rig)

        let report = try await rig.switcher.start(coding.id, trigger: .link)

        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "hide:") == ["com.figma.desktop", "com.bohemiancoding.sketch3"])
        #expect(report.plan.quit.isEmpty && report.outcome == .done)
        #expect(rig.session.current == coding.id)
    }

    @Test func cancelDoesNothing() async throws {
        let (rig, design, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup), answer: .cancel)
        try await startDesign(rig)
        let before = rig.log.events.count

        let report = try await rig.switcher.start(coding.id, trigger: .link)

        #expect(report.outcome == .declined)
        #expect(rig.log.events.count == before)
        #expect(rig.session.current == design.id)
        #expect(report.summary == "Didn't switch to “Coding”.")
    }

    @Test func aLinksQuestionIsDroppedWhileAnotherQuestionShows() async throws {
        let (rig, design, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)
        // A quit link's question is showing (and is answered Cancel) when the transition's
        // question would be asked.
        rig.quitPrompt.answer = false
        var dropped: TransitionConfirmation.Answer?? = .none
        rig.quitPrompt.whileAsking = {
            dropped = rig.quitRequests.askBeforeTransition(TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma"]))
        }
        _ = rig.quitRequests.request(design, mode: .graceful, from: .link)
        #expect(dropped == .some(nil))
        #expect(rig.transitionPrompt.asked.isEmpty)

        // And a transition that finds a question showing does nothing.
        let busy = BusyQuestions()
        let switcher = ContextSwitcher(
            store: rig.store, preferences: rig.preferences, session: rig.session,
            launcher: GroupLauncher(workspace: rig.workspace, locator: ScriptedLocator()),
            terminator: rig.terminator, applications: rig.apps, questions: busy
        )
        let report = try await switcher.start(coding.id, trigger: .link)
        #expect(report.outcome == .dropped)
        #expect(rig.session.current == design.id)
    }

    @Test func siriAsksInItsOwnWayAndDecliningDoesNothing() async throws {
        let (rig, design, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)
        let before = rig.log.events.count
        let asked = QuestionRecorder()

        await #expect(throws: Declined.self) {
            try await rig.switcher.start(coding.id, trigger: .intent) { question in
                asked.questions.append(question)
                throw Declined()
            }
        }

        #expect(asked.questions.map(\.appNames) == [["Figma", "Sketch"]])
        #expect(asked.questions.first?.intentDialog.hasPrefix("Switch to “Coding” and quit 2 apps?") == true)
        #expect(rig.transitionPrompt.asked.isEmpty, "not the app's alert")
        #expect(rig.log.events.count == before)
        #expect(rig.session.current == design.id)

        _ = try await rig.switcher.start(coding.id, trigger: .intent) { _ in }
        #expect(rig.log.events(withPrefix: "quit:").count == 2)
    }

    @Test func siriWithoutAWayToAskHidesInstead() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)
        _ = try await rig.switcher.start(coding.id, trigger: .intent)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "hide:").count == 2)
    }

    @Test func aFocusHidesInsteadOfQuittingAndNeverAsks() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup))
        try await startDesign(rig)
        _ = try await rig.switcher.start(coding.id, trigger: .focus)
        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "hide:").count == 2)
        #expect(rig.session.startTrigger == .focus)
    }

    @Test func protectedAppsAreLeftAlone() async throws {
        let (rig, _, coding) = rig(GroupSwitching(onStart: .quitPreviousGroup), protected: [AppReference(bundleIdentifier: "com.figma.Desktop", name: "Figma")])
        try await startDesign(rig)

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        #expect(rig.log.events(withPrefix: "quit:") == ["com.bohemiancoding.sketch3"])
        #expect(report.kept.map(\.reason) == [.protected, .shared])
        #expect(report.summary.hasSuffix("Figma is protected and stays open."))
    }

    @Test func startingTheCurrentGroupAgainRightAwayDoesNothing() async throws {
        let (rig, _, coding) = rig()
        _ = try await rig.switcher.start(coding.id, trigger: .focus)
        let launches = rig.workspace.launched.count

        let repeated = try await rig.switcher.start(coding.id, trigger: .intent)
        #expect(repeated.outcome == .repeated)
        #expect(rig.workspace.launched.count == launches)
        #expect(repeated.summary == "“Coding” was just started.")

        rig.clock.advance(ContextSession.repeatInterval)
        #expect(try await rig.switcher.start(coding.id, trigger: .userAction).outcome == .done)
        #expect(rig.workspace.launched.count == 2 * launches)
    }

    @Test func transitionsRunOneAtATime() async throws {
        let (rig, design, coding) = rig()
        rig.workspace.holdsLaunches = true
        let switcher = rig.switcher

        let first = Task { try await switcher.start(design.id, trigger: .userAction) }
        while rig.workspace.heldLaunchCount == 0 { await Task.yield() }
        let second = Task { try await switcher.start(coding.id, trigger: .userAction) }
        for _ in 0..<20 { await Task.yield() }

        // Design is still opening its items: Coding hasn't hidden anything yet.
        #expect(rig.log.events(withPrefix: "hide:").isEmpty)
        #expect(switcher.isBusy)

        while !rig.log.events(withPrefix: "hide:").contains("com.figma.desktop") {
            rig.workspace.releaseLaunches()
            await Task.yield()
        }
        while rig.workspace.heldLaunchCount < 2 { await Task.yield() }
        rig.workspace.releaseLaunches()
        _ = try await first.value
        _ = try await second.value

        let events = rig.log.events
        let designLaunches = ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.tinyspeck.slackmacgap"].compactMap { events.firstIndex(of: "launch:\($0)") }
        let firstCodingHide = try #require(events.firstIndex(of: "hide:com.figma.desktop"))
        #expect(designLaunches.count == 3)
        #expect(designLaunches.allSatisfy { $0 < firstCodingHide })
        #expect(rig.session.current == coding.id && rig.session.previous == design.id)
        #expect(!switcher.isBusy)
    }

    @Test func unknownAndDeletedGroups() async throws {
        let (rig, design, coding) = rig()
        await #expect(throws: ContextSwitchingError.groupNotFound(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!)) {
            try await rig.switcher.start(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, trigger: .link)
        }
        _ = try await rig.switcher.start(design.id, trigger: .userAction)
        rig.clock.advance(10)
        _ = try await rig.switcher.start(coding.id, trigger: .userAction)

        rig.store.deleteGroup(design.id)
        #expect(rig.session.history == [coding.id], "deleted groups leave the history")
        let report = try await rig.switcher.finish(coding.id, trigger: .userAction)
        #expect(report.plan.next == nil && rig.session.current == nil)
    }

    @Test func afterFinishingDoNothingShowsNothing() async throws {
        let (rig, _, coding) = rig(GroupSwitching(afterFinish: .nothing))
        try await startDesign(rig)
        _ = try await rig.switcher.start(coding.id, trigger: .userAction)

        let report = try await rig.switcher.finish(coding.id, trigger: .userAction)

        #expect(report.shown.done.isEmpty && rig.log.events(withPrefix: "unhide:").isEmpty)
        #expect(rig.session.current == nil)
    }
}

private struct Declined: Error {}

@MainActor
private final class QuestionRecorder {
    var questions: [TransitionConfirmation] = []
}

/// Another link's question is always showing.
@MainActor
private final class BusyQuestions: TransitionQuestioning {
    func askBeforeTransition(_ confirmation: TransitionConfirmation) -> TransitionConfirmation.Answer? { nil }
}
