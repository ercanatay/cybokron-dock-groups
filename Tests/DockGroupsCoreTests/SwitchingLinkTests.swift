import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: links")
struct SwitchingLinkTests {
    private func command(_ string: String) -> SwitchingURLCommand? {
        URL(string: string).flatMap(SwitchingURLCommand.init(url:))
    }

    @Test func parsesStartSwitchAndFinish() {
        #expect(command("cybokrondockgroups://start/coding") == .start("coding"))
        #expect(command("cybokrondockgroups://switch/Deep%20Work") == .start("Deep Work"))
        #expect(command("CybokronDockGroups://START/Coding/") == .start("Coding"))
        #expect(command("cybokrondockgroups:finish/coding") == .finish("coding"))
        #expect(command("cybokrondockgroups://finish/Dev%2FOps") == .finish("Dev/Ops"))
        #expect(command("cybokrondockgroups://finish/Dev%2FOps")?.group == "Dev/Ops")
    }

    @Test(arguments: [
        "cybokrondockgroups://start",
        "cybokrondockgroups://finish/",
        "cybokrondockgroups://launch/coding",
        "cybokrondockgroups://quit/coding",
        "https://start/coding",
        "cybokrondockgroups://starts/coding",
    ])
    func rejectsOtherLinks(_ string: String) {
        #expect(command(string) == nil)
    }

    @Test func theOtherCommandsAreUnchanged() {
        // Start and finish links aren't URL commands, so the app's handling of those is as before.
        for string in ["cybokrondockgroups://start/coding", "cybokrondockgroups://switch/coding", "cybokrondockgroups://finish/coding"] {
            #expect(URL(string: string).flatMap(URLCommand.init(url:)) == nil)
        }
        #expect(URL(string: "cybokrondockgroups://launch/coding").flatMap(URLCommand.init(url:)) == .launchGroup("coding"))
        #expect(URL(string: "cybokrondockgroups://quit/coding?mode=force").flatMap(URLCommand.init(url:)) == .quitGroup("coding", .force))
        #expect(URLCommand.launchGroup("a").groupActionKey == URLCommand.groupAppsKey)
    }

    @Test func spellingsOfTheSameRequestShareACooldownKey() {
        #expect(SwitchingURLCommand.start("Deep Work").throttleKey == SwitchingURLCommand.start("deep-work").throttleKey)
        #expect(command("cybokrondockgroups://switch/coding")?.throttleKey == command("cybokrondockgroups://start/Coding")?.throttleKey)
        #expect(SwitchingURLCommand.start("coding").throttleKey != SwitchingURLCommand.finish("coding").throttleKey)
        #expect(SwitchingURLCommand.finish("coding").groupActionKey == URLCommand.groupAppsKey)
    }

    @Test func startAndFinishShareTheGroupAppsCooldownWithLaunchAndHide() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var gate = URLCommandGate()
        let results = [
            gate.accept(SwitchingURLCommand.start("coding"), at: start),
            gate.accept(URLCommand.launchGroup("design"), at: start.addingTimeInterval(1)),
            gate.accept(SwitchingURLCommand.finish("design"), at: start.addingTimeInterval(2)),
            gate.accept(URLCommand.hideGroup("mail"), at: start.addingTimeInterval(3)),
            gate.accept(SwitchingURLCommand.start("coding"), at: start.addingTimeInterval(4)),
            gate.accept(URLCommand.showGroup("coding"), at: start.addingTimeInterval(4)),
            gate.accept(SwitchingURLCommand.finish("coding"), at: start.addingTimeInterval(5)),
            gate.accept(SwitchingURLCommand.finish("coding"), at: start.addingTimeInterval(6)),
        ]
        #expect(results == [.accepted, .groupActionLimited, .groupActionLimited, .groupActionLimited, .repeated, .accepted, .accepted, .repeated])
    }

    @Test func aQuestionsAnswerRestartsTheCooldown() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var gate = URLCommandGate(interval: 5)
        let finish = SwitchingURLCommand.finish("coding")
        let first = gate.accept(finish, at: start)
        gate.restartCooldown(for: finish, at: start.addingTimeInterval(20))
        let soonAfter = gate.accept(finish, at: start.addingTimeInterval(21))
        let later = gate.accept(finish, at: start.addingTimeInterval(25))
        #expect([first, soonAfter, later] == [.accepted, .repeated, .accepted])
    }
}

@Suite("Switching: the question before quitting")
struct TransitionConfirmationTests {
    @Test func startQuestion() {
        let question = TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma", "Sketch"])
        #expect(question.title == "Switch to “Coding” and quit 2 apps?")
        #expect(question.detail == "“Coding” is set to quit the apps of “Design” it doesn't use: Figma, Sketch.")
        #expect(question.message == """
            “Coding” is set to quit the apps of “Design” it doesn't use: Figma, Sketch.

            A link opened by another app, a script or a web page asked for this.

            Apps can still ask to save changes.
            """)
        #expect(question.intentDialog == "Switch to “Coding” and quit 2 apps?\n\n“Coding” is set to quit the apps of “Design” it doesn't use: Figma, Sketch.")
        #expect(question.confirmButton == "Quit and Switch")
        #expect(question.hideInsteadButton == "Hide Instead")
        #expect(question.cancelButton == "Cancel")
        #expect(TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma"]).title == "Switch to “Coding” and quit 1 app?")
    }

    @Test func finishQuestion() {
        let question = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: "Design"), appNames: ["Xcode", "Simulator", "Instruments"])
        #expect(question.title == "Finish “Coding” and quit 3 apps?")
        #expect(question.detail == "Finishing “Coding” quits Xcode, Simulator, Instruments. Protected apps and apps “Design” uses stay open.")
        #expect(question.confirmButton == "Quit Apps")
        let alone = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: nil), appNames: ["Xcode"])
        #expect(alone.title == "Finish “Coding” and quit 1 app?")
        #expect(alone.detail == "Finishing “Coding” quits Xcode. Protected apps stay open.")
    }

    @Test func theQuitButtonWaitsAsCloseAllsDoes() {
        #expect(TransitionConfirmation.confirmButtonDelay == QuitConfirmation.confirmButtonDelay)
    }

    @Test func onlyPlansThatQuitHaveAQuestion() {
        let design = DockGroup.of("Design", ["com.figma.Desktop"])
        let running = [RunningAppSnapshot(processIdentifier: 3, identity: "com.figma.desktop", name: "Figma")]
        let hiding = TransitionPlanner.start(.of("Coding", []), previous: design, running: running, protected: ProtectedApps(), trigger: .link)
        #expect(TransitionConfirmation(plan: hiding) == nil)

        let quitting = TransitionPlanner.start(.of("Coding", [], switching: GroupSwitching(onStart: .quitPreviousGroup)), previous: design, running: running, protected: ProtectedApps(), trigger: .link)
        #expect(TransitionConfirmation(plan: quitting) == TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma"]))
        let finishing = TransitionPlanner.finish(.of("Design", ["com.figma.Desktop"], switching: GroupSwitching(onFinish: .quitApps)), next: nil, running: running, protected: ProtectedApps(), trigger: .intent)
        #expect(TransitionConfirmation(plan: finishing)?.kind == .finish(group: "Design", nextGroup: nil))
    }
}

@Suite("Switching: summaries")
struct TransitionSummaryTests {
    private func plan(_ kind: TransitionPlan.Kind, other: String?) -> TransitionPlan {
        TransitionPlan(kind: kind, trigger: .intent, groupName: "Coding", otherGroupName: other)
    }

    private static func app(_ name: String) -> RunningAppSnapshot {
        RunningAppSnapshot(processIdentifier: 1, identity: "com.example.\(name.lowercased())", name: name)
    }

    @Test func summariesSayWhatHappened() {
        var started = TransitionReport(outcome: .done, plan: plan(.start(UUID()), other: nil))
        #expect(started.summary == "Started “Coding”.")
        started.launch = LaunchReport(groupName: "Coding", entries: [
            .init(app: AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"), outcome: .launched),
            .init(app: AppReference(bundleIdentifier: "com.example.gone", name: "Gone"), outcome: .notFound),
        ])
        #expect(started.summary == "Started “Coding”: opened 1 item. Couldn't open Gone.")

        var finished = TransitionReport(outcome: .done, plan: plan(.finish(UUID()), other: "Design"))
        finished.hidden = RunningAppsReport(done: [Self.app("Xcode")], refused: [Self.app("Simulator")])
        finished.quit = RunningAppsReport(done: [Self.app("Instruments"), Self.app("Music")])
        #expect(finished.summary == "Finished “Coding”: hid 1 app, asked 2 apps to quit and showed “Design” again. Couldn't hide Simulator.")
        #expect(finished.hasProblems)

        #expect(TransitionReport(outcome: .declined, plan: plan(.finish(UUID()), other: nil)).summary == "Didn't finish “Coding”.")
        #expect(TransitionReport(outcome: .dropped, plan: plan(.start(UUID()), other: nil)).summary == "Didn't switch to “Coding”.")
    }

    @Test func joiningNames() {
        #expect(TransitionReport.joined([]) == "")
        #expect(TransitionReport.joined(["a"]) == "a")
        #expect(TransitionReport.joined(["a", "b"]) == "a and b")
        #expect(TransitionReport.joined(["a", "b", "c"]) == "a, b and c")
    }
}
