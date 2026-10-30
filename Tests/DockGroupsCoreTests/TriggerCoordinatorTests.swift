import Foundation
import Testing
@testable import DockGroupsCore

/// A coordinator with fakes: its rules and active groups can be changed between signals.
@MainActor
final class TriggerRig {
    static let work = DockGroup.of("Work", ["com.apple.mail"])
    static let design = DockGroup.of("Design", ["com.figma.Desktop"])

    var rules: [GroupTrigger]
    var active: Set<DockGroup.ID> = [work.id, design.id]
    let sleeper = FakeSleeper()
    let clock = TestClock()
    let handler = FakeAutomationHandler(groups: [work, design])
    let presenter = FakeNoticePresenter()
    let coordinator: TriggerCoordinator
    private(set) var savedStates: [TriggerState] = []

    init(_ rules: [GroupTrigger], state: TriggerState = TriggerState(), presenter withPresenter: Bool = true, handler withHandler: Bool = true) {
        self.rules = rules
        // Wednesday 2026-10-28 at 8:00 in Istanbul.
        clock.now = TriggerTime.date(2026, 10, 28, 8, 0)
        weak var box: TriggerRig?
        let clock = self.clock
        coordinator = TriggerCoordinator(
            state: state,
            rules: { box?.rules ?? [] },
            activeGroups: { box?.active ?? [] },
            sleeper: sleeper,
            clock: { clock.now },
            calendar: { TriggerTime.calendar() }
        )
        box = self
        coordinator.onStateChange = { [weak self] state in self?.savedStates.append(state) }
        if withHandler { coordinator.handler = handler }
        if withPresenter { coordinator.noticePresenter = presenter }
        coordinator.start()
    }

    /// Sends the signals, lets the settle end and waits until everything is carried out (or stuck).
    func send(_ signals: TriggerSignal...) async {
        for signal in signals {
            coordinator.receive(signal)
        }
        await settleDown()
    }

    func settleDown() async {
        await settle { sleeper.sleepingCount > 0 || coordinator.isIdle }
        sleeper.wakeAll()
        await settle { coordinator.isIdle || presenter.isShowing }
    }

    func outcome(_ trigger: GroupTrigger) -> TriggerOutcome? {
        coordinator.state.entry(for: trigger.id).lastOutcome
    }
}

@Suite("Triggers: carrying firings out")
@MainActor
struct TriggerCoordinatorTests {
    private let work = TriggerRig.work
    private let design = TriggerRig.design
    private var session: Date { TriggerTime.date(2026, 10, 28, 7, 59) }

    @Test func aTriggerStartsItsGroupAfterTheSettleNeverQuitting() async {
        let login = GroupTrigger.on(.login, group: work)
        let rig = TriggerRig([login])

        rig.coordinator.receive(.launched(.login(session: session)))
        await settle { rig.sleeper.sleepingCount > 0 }
        #expect(rig.sleeper.requested == [2])
        #expect(rig.handler.calls.isEmpty)
        rig.sleeper.wakeAll()
        await settle { rig.coordinator.isIdle }

        #expect(rig.handler.calls == ["start:Work:automation"])
        #expect(!TransitionTrigger.automation.mayQuit && !TransitionTrigger.automation.asksBeforeQuitting)
        #expect(rig.outcome(login) == .ran(.start))
        #expect(rig.coordinator.state.recentRuns == [rig.clock.now])
        #expect(rig.coordinator.environment.echoUntil == rig.clock.now.addingTimeInterval(15))
        #expect(rig.savedStates.last == rig.coordinator.state)
    }

    @Test func everyActionGoesToItsPath() async {
        for action in [TriggerAction.showPopup, .openAll] {
            let trigger = GroupTrigger.on(.appOpens, group: design, action: action)
            let rig = TriggerRig([trigger])
            await rig.send(.launched(.normal))
            #expect(rig.handler.calls == [action == .showPopup ? "popup:Design" : "openAll:Design"])
        }
    }

    // MARK: - Notices

    @Test func theNoticeComesFirst() async throws {
        let login = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([login])
        await rig.send(.launched(.login(session: session)))
        let notice = try #require(rig.presenter.shown.first)
        #expect(notice.groupName == "Work" && notice.action == .start && notice.runMode == .notice)
        #expect(notice.waits == .seconds(5))
        #expect(rig.handler.calls == ["start:Work:automation"])
    }

    @Test(arguments: [
        (TriggerNoticeAnswer.notNow, TriggerSkipReason.notNow),
        (.timedOut, .noAnswer),
        (.replaced, .anotherTrigger),
    ])
    func aNoticeCanBeAnsweredNo(answer: TriggerNoticeAnswer, reason: TriggerSkipReason) async {
        let login = GroupTrigger.on(.login, group: work, runMode: .askFirst)
        let rig = TriggerRig([login])
        rig.presenter.answers = [answer]
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.shown.first?.waits == .seconds(120))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(login) == .skipped(reason))
        #expect(rig.coordinator.state.recentRuns.isEmpty)
    }

    @Test func withoutANoticeNothingThatNeedsOneRuns() async {
        let notice = GroupTrigger.on(.login, group: work, runMode: .notice)
        let popup = GroupTrigger.on(.appOpens, group: design, action: .showPopup)
        let rig = TriggerRig([notice, popup], presenter: false)
        await rig.send(.launched(.login(session: session)))
        #expect(rig.handler.calls == ["popup:Design"])
        #expect(rig.outcome(notice) == .skipped(.noAnswer))
    }

    @Test func aNewerStartTakesTheNoticesPlace() async {
        let login = GroupTrigger.on(.login, group: work, runMode: .notice)
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: design, runMode: .notice)
        let rig = TriggerRig([login, plugged])
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.isShowing)

        rig.clock.advance(3)
        rig.presenter.holds = false
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { rig.coordinator.isIdle }

        #expect(rig.presenter.dismissCount == 1)
        #expect(rig.outcome(login) == .skipped(.anotherTrigger))
        #expect(rig.handler.calls == ["start:Design:automation"])
    }

    @Test func theGroupIsLookedAtAgainAfterTheNotice() async {
        let login = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([login])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        rig.handler.groups.removeAll { $0.id == TriggerRig.work.id }
        rig.active.remove(TriggerRig.work.id)
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(login) == .skipped(.groupMissing))
    }

    @Test func pausingDuringTheNoticeStopsIt() async {
        let login = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([login])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        rig.coordinator.pause(.oneHour)
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(login) == .skipped(.paused))
        #expect(rig.coordinator.isPaused)
        rig.coordinator.resume()
        #expect(!rig.coordinator.isPaused)
    }

    // MARK: - Finish

    @Test func finishIsOnlyForTheCurrentGroup() async {
        let sixPM = GroupTrigger.at(18, 0, group: work, action: .finish)
        let rig = TriggerRig([sixPM])
        rig.clock.now = TriggerTime.date(2026, 10, 28, 18, 0)
        await rig.send(.clock)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(sixPM) == .skipped(.notCurrentGroup))

        let current = TriggerRig([sixPM])
        current.handler.userStarted(TriggerRig.work.id)
        current.clock.now = TriggerTime.date(2026, 10, 28, 18, 0)
        await current.send(.clock)
        #expect(current.handler.calls == ["finish:Work:automation:true"])
        #expect(current.outcome(sixPM) == .ran(.finish))
    }

    @Test func aStartFinishesWhatItStartedWhenItsConditionEnds() async {
        let docked = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: work, finishesWhenEventEnds: true)
        let rig = TriggerRig([docked])
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        rig.clock.advance(60)
        await rig.send(.network(NetworkReading(usesEthernet: true)))
        #expect(rig.handler.calls == ["start:Work:automation"])
        rig.clock.advance(30)
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        #expect(rig.handler.calls == ["start:Work:automation", "finish:Work:automation:true"])
    }

    @Test func itDoesntFinishWhatTheUserStartedSince() async {
        let docked = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: work, finishesWhenEventEnds: true)
        let rig = TriggerRig([docked])
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        rig.clock.advance(60)
        await rig.send(.network(NetworkReading(usesEthernet: true)))
        rig.handler.userStarted(TriggerRig.work.id)
        rig.clock.advance(30)
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        #expect(rig.handler.calls == ["start:Work:automation"])
        #expect(rig.outcome(docked) == .skipped(.notStartedByTrigger))
    }

    @Test func aRepeatedStartIsJustDone() async {
        let login = GroupTrigger.on(.login, group: work)
        let rig = TriggerRig([login])
        rig.handler.startOutcome = .repeated
        await rig.send(.launched(.login(session: session)))
        #expect(rig.outcome(login) == .skipped(.alreadyDone))
        #expect(rig.coordinator.state.recentRuns.isEmpty)
    }

    // MARK: - Echo, budget, pause

    @Test func changesDuringAndRightAfterAnActionRunNothing() async {
        let login = GroupTrigger.on(.login, group: work)
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: design, action: .openAll)
        let rig = TriggerRig([login, plugged])
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        // The Start's apps include a VPN client or a dock driver: the network changes meanwhile.
        rig.handler.duringAction = { [coordinator = rig.coordinator] in
            coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        }
        await rig.send(.launched(.login(session: session)))
        rig.handler.duringAction = nil
        #expect(rig.handler.calls == ["start:Work:automation"])
        #expect(rig.outcome(plugged) == .skipped(.rightAfterAutomaticAction))

        // 10 seconds later, still in the window; 20 seconds later, out of it.
        rig.clock.advance(10)
        await rig.send(.network(NetworkReading(usesEthernet: false)), .network(NetworkReading(usesEthernet: true)))
        #expect(rig.handler.calls == ["start:Work:automation"])
        rig.clock.advance(10)
        await rig.send(.network(NetworkReading(usesEthernet: false)), .network(NetworkReading(usesEthernet: true)))
        #expect(rig.handler.calls == ["start:Work:automation", "openAll:Design"])
    }

    @Test func theThirteenthActionInAnHourPausesTriggers() async {
        let opens = GroupTrigger.on(.appOpens, group: design, action: .openAll)
        let now = TriggerTime.date(2026, 10, 28, 8, 0)
        let runs = (1...12).map { now.addingTimeInterval(-Double($0) * 120) }
        let rig = TriggerRig([opens], state: TriggerState(recentRuns: runs))
        await rig.send(.launched(.normal))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(opens) == .skipped(.budget))
        #expect(rig.coordinator.state.pauseReason == .budget)
        #expect(rig.coordinator.state.pausedUntil == now.addingTimeInterval(3_600))
        #expect(rig.coordinator.isPaused)
    }

    @Test func pausedTriggersSkip() async {
        let login = GroupTrigger.on(.login, group: work)
        let rig = TriggerRig([login])
        rig.coordinator.pause(.untilResumed)
        await rig.send(.launched(.login(session: session)))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(login) == .skipped(.paused))
        #expect(rig.coordinator.state.pausedUntil == .distantFuture)
    }

    // MARK: - Waiting

    @Test func firingsWaitForTheApp() async {
        let login = GroupTrigger.on(.login, group: work)
        let rig = TriggerRig([login], handler: false)
        rig.coordinator.receive(.launched(.login(session: session)))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        #expect(rig.coordinator.waitingFirings.count == 1)
        rig.coordinator.handler = rig.handler
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls == ["start:Work:automation"])
    }

    @Test func firingsWaitForTheScreensToWake() async {
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: work, action: .openAll)
        let rig = TriggerRig([plugged])
        await rig.send(.network(NetworkReading(usesEthernet: false)), .screens(asleep: true))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        #expect(rig.handler.calls.isEmpty)
        rig.clock.advance(300)
        await rig.send(.screens(asleep: false))
        #expect(rig.handler.calls == ["openAll:Work"])
    }

    @Test func aFiringThatWaitedTooLongIsMissed() async {
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: work, action: .openAll)
        let rig = TriggerRig([plugged])
        await rig.send(.network(NetworkReading(usesEthernet: false)), .screens(asleep: true))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        rig.clock.advance(3_600)
        await rig.send(.screens(asleep: false))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(plugged) == .missed(.macAsleep))
    }

    /// Nobody can answer a notice while the screens sleep: a trigger on them going to sleep runs
    /// then, without one — and can only finish (hide) the current group.
    @Test func screensSleepFinishesRightAway() async {
        let away = GroupTrigger.on(.screensSleep, group: design, action: .finish, runMode: .notice)
        let rig = TriggerRig([away], presenter: false)
        rig.handler.userStarted(TriggerRig.design.id)
        await rig.send(.screens(asleep: true))
        #expect(rig.handler.calls == ["finish:Design:automation:true"])
    }

    @Test func firingsOfTriggersTurnedOffOrDeletedAreDropped() async {
        let login = GroupTrigger.on(.login, group: work)
        let rig = TriggerRig([login], handler: false)
        rig.coordinator.receive(.launched(.login(session: session)))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        let previous = rig.rules
        rig.rules[0].isEnabled = false
        rig.coordinator.rulesChanged(previous: previous)
        #expect(rig.coordinator.waitingFirings.isEmpty)
        rig.coordinator.handler = rig.handler
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func changedEventCancelsPendingFiring() async {
        let trigger = GroupTrigger.on(.appOpens, group: work, action: .showPopup)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await settle { rig.sleeper.sleepingCount > 0 }
        let previous = rig.rules
        rig.rules[0].event = .screensWake
        rig.coordinator.rulesChanged(previous: previous)
        rig.sleeper.wakeAll()
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func disabledRuleCannotRunAfterNoticeIsAnswered() async {
        let trigger = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.isShowing)
        let previous = rig.rules
        rig.rules[0].isEnabled = false
        rig.coordinator.rulesChanged(previous: previous)
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func changedGroupCancelsQueuedFiring() async {
        let trigger = GroupTrigger.on(.appOpens, group: work, action: .showPopup)
        let rig = TriggerRig([trigger], handler: false)
        rig.coordinator.receive(.launched(.normal))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        let previous = rig.rules
        rig.rules[0].groupID = design.id
        rig.coordinator.rulesChanged(previous: previous)
        #expect(rig.coordinator.waitingFirings.isEmpty)
        rig.coordinator.handler = rig.handler
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func changedRuleWithoutNotificationIsRecheckedAfterNotice() async {
        let trigger = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.isShowing)
        rig.rules[0].event = .appOpens
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func disableThenReenableDoesNotReviveNotice() async {
        let trigger = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.isShowing)
        let beforeDisable = rig.rules
        rig.rules[0].isEnabled = false
        rig.coordinator.rulesChanged(previous: beforeDisable)
        let beforeEnable = rig.rules
        rig.rules[0].isEnabled = true
        rig.coordinator.rulesChanged(previous: beforeEnable)
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func ruleInvalidationAfterNoticeAnswerCannotBeUndone() async {
        let trigger = GroupTrigger.on(.login, group: work, runMode: .notice)
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        await rig.send(.launched(.login(session: session)))
        #expect(rig.presenter.isShowing)
        // Resume the notice, but change the rule before the main actor resumes its caller.
        rig.presenter.release(.run)
        let beforeDisable = rig.rules
        rig.rules[0].isEnabled = false
        rig.coordinator.rulesChanged(previous: beforeDisable)
        let beforeEnable = rig.rules
        rig.rules[0].isEnabled = true
        rig.coordinator.rulesChanged(previous: beforeEnable)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    // MARK: - Launches and the clock

    @Test func aQuietLaunchMarkerMakesTheNextLaunchQuiet() async {
        let opens = GroupTrigger.on(.appOpens, group: design, action: .showPopup)
        let rig = TriggerRig([opens])
        rig.coordinator.markQuietLaunch(until: rig.clock.now.addingTimeInterval(120))
        #expect(rig.coordinator.launchKind(.normal) == .quiet)
        await rig.send(.launched(rig.coordinator.launchKind(.normal)))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.state.quietLaunchUntil == nil)
        #expect(rig.coordinator.launchKind(.normal) == .normal)
    }

    @Test func nextDueAndTheBaselineAtStart() {
        let nine = GroupTrigger.at(9, 0, group: work)
        let rig = TriggerRig([nine])
        #expect(rig.coordinator.nextDue == TriggerTime.date(2026, 10, 28, 9, 0))
        #expect(rig.coordinator.state.entry(for: nine.id).lastHandledOccurrence == TriggerTime.date(2026, 10, 27, 9, 0))
    }

    @Test func aTimeRunsAtItsMoment() async {
        let nine = GroupTrigger.at(9, 0, group: work, action: .openAll)
        let rig = TriggerRig([nine])
        rig.clock.now = TriggerTime.date(2026, 10, 28, 9, 0, 10)
        await rig.send(.clock)
        #expect(rig.handler.calls == ["openAll:Work"])
        rig.clock.advance(120)
        await rig.send(.clock)
        #expect(rig.handler.calls == ["openAll:Work"])
    }
}
