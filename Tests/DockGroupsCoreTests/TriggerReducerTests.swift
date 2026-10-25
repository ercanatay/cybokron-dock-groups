import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: firings that come together, and the budget")
struct TriggerReducerTests {
    private static let work = UUID()
    private static let design = UUID()
    private static let home = UUID()
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func firing(_ action: TriggerAction, _ group: UUID, at seconds: TimeInterval = 0, order: Int = 0, finishWhenEnded: Bool = false) -> TriggerFiring {
        TriggerFiring(triggerID: UUID(), groupID: group, action: action, occurrence: Self.base.addingTimeInterval(seconds), isFinishWhenEnded: finishWhenEnded, order: order)
    }

    @Test func oneStartWinsTheLatest() {
        let early = firing(.start, Self.work, at: 0, order: 0)
        let late = firing(.start, Self.design, at: 1, order: 1)
        let reduction = TriggerReducer.reduce([early, late])
        #expect(reduction.run == [late])
        #expect(reduction.skipped == [TriggerSkip(firing: early, reason: .anotherTrigger)])
    }

    @Test func aTieGoesToTheTriggerListedFirst() {
        let second = firing(.start, Self.design, order: 3)
        let first = firing(.start, Self.work, order: 1)
        #expect(TriggerReducer.reduce([second, first]).run == [first])
        // The same group twice: once, the other "just done".
        let again = firing(.start, Self.work, order: 2)
        #expect(TriggerReducer.reduce([first, again]).skipped == [TriggerSkip(firing: again, reason: .alreadyDone)])
    }

    @Test func theOrderIsFinishesStartOpenAllsPopup() {
        let popup = firing(.showPopup, Self.home, at: 3, order: 0)
        let openAll = firing(.openAll, Self.home, at: 2, order: 1)
        let start = firing(.start, Self.work, at: 1, order: 2)
        let finish = firing(.finish, Self.design, at: 0, order: 3)
        let reduction = TriggerReducer.reduce([popup, openAll, start, finish])
        #expect(reduction.run == [finish, start, openAll])
        // Home is being opened: its popup is skipped.
        #expect(reduction.skipped == [TriggerSkip(firing: popup, reason: .alreadyDone)])
    }

    @Test func theStartedGroupIsntFinishedOrOpenedToo() {
        let start = firing(.start, Self.work, at: 1)
        let finish = firing(.finish, Self.work, at: 0)
        let openAll = firing(.openAll, Self.work, at: 0)
        let popup = firing(.showPopup, Self.work, at: 0)
        let reduction = TriggerReducer.reduce([finish, openAll, popup, start])
        #expect(reduction.run == [start])
        #expect(Set(reduction.skipped.map(\.reason)) == [.anotherTrigger, .alreadyDone])
    }

    @Test func eachGroupIsFinishedAndOpenedOnce() {
        let finishes = [firing(.finish, Self.work, at: 0), firing(.finish, Self.work, at: 1), firing(.finish, Self.design, at: 2)]
        let reduction = TriggerReducer.reduce(finishes)
        #expect(reduction.run.map(\.groupID) == [Self.work, Self.design])
        #expect(reduction.run.first?.occurrence == Self.base.addingTimeInterval(1))
        let openAlls = [firing(.openAll, Self.home, order: 1), firing(.openAll, Self.home, order: 0)]
        #expect(TriggerReducer.reduce(openAlls).run.count == 1)
    }

    @Test func atMostOnePopupTheLatest() {
        let work = firing(.showPopup, Self.work, at: 0)
        let design = firing(.showPopup, Self.design, at: 5)
        let reduction = TriggerReducer.reduce([work, design])
        #expect(reduction.run == [design])
        #expect(reduction.skipped == [TriggerSkip(firing: work, reason: .anotherTrigger)])
        #expect(TriggerReducer.reduce([]).run.isEmpty)
    }

    // MARK: - Budget

    @Test func twelveAnHourThenNoMore() {
        let now = Self.base
        let eleven = (1...11).map { now.addingTimeInterval(-Double($0) * 60) }
        #expect(TriggerBudget.allows(eleven, now: now))
        let twelve = eleven + [now.addingTimeInterval(-30)]
        #expect(!TriggerBudget.allows(twelve, now: now))
        // Runs older than an hour don't count; nor do runs "in the future" (a clock set back).
        let old = twelve.map { $0.addingTimeInterval(-3_600) }
        #expect(TriggerBudget.allows(old, now: now))
        #expect(TriggerBudget.allows(twelve.map { $0.addingTimeInterval(7_200) }, now: now))
        #expect(TriggerBudget.pauseMessage == "Triggers paused for an hour: they ran 12 times in an hour.")
    }

    @Test func pauseLengths() {
        let calendar = TriggerTime.calendar()
        let now = TriggerTime.date(2026, 10, 28, 15, 20)
        #expect(TriggerPauseLength.oneHour.end(from: now, calendar: calendar) == now.addingTimeInterval(3_600))
        #expect(TriggerPauseLength.untilTomorrow.end(from: now, calendar: calendar) == TriggerTime.date(2026, 10, 29))
        #expect(TriggerPauseLength.untilResumed.end(from: now, calendar: calendar) == .distantFuture)
        var state = TriggerState()
        state.pause(until: now.addingTimeInterval(60), reason: .user)
        #expect(state.isPaused(at: now) && !state.isPaused(at: now.addingTimeInterval(60)))
        state.resume()
        #expect(!state.isPaused(at: now) && state.pauseReason == nil)
    }

    @Test func recentRunsAreBounded() {
        var state = TriggerState()
        let id = UUID()
        for second in 0..<80 {
            state.recordRun(.openAll, for: id, at: Self.base.addingTimeInterval(Double(second)))
        }
        #expect(state.recentRuns.count == TriggerState.maximumRecentRuns)
        #expect(state.recentRuns.last == Self.base.addingTimeInterval(79))
        #expect(state.entry(for: id).lastOutcome == .ran(.openAll))
    }
}
