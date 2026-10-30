import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Application presence trigger evaluation")
struct AppPresenceEvaluatorTests {
    private let groupID = UUID(uuidString: "0C0D1E00-0000-4000-8000-000000000080")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func rule(edge: TriggerEdge = .starts, enabled: Bool = true) -> GroupTrigger {
        GroupTrigger(groupID: groupID, event: .applicationPresence(bundleIdentifier: "com.example.App", edge: edge),
                     action: .showPopup, isEnabled: enabled)
    }

    private func evaluate(_ signal: TriggerSignal, _ rule: GroupTrigger, state: TriggerState = TriggerState(),
                          environment: TriggerEnvironment = TriggerEnvironment(), active: Bool = true) -> TriggerEvaluation {
        TriggerEvaluator.evaluate(signal, rules: [rule], state: state, environment: environment,
                                  activeGroups: active ? [groupID] : [], now: now, calendar: calendar)
    }

    @Test func matchingRuleAndEdgeFiresOnlyWhenEligible() {
        let trigger = rule()
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger).firings.map(\.triggerID) == [trigger.id])
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .ends), trigger).firings.isEmpty)
        #expect(evaluate(.applicationEdge(triggerID: UUID(), edge: .starts), trigger).firings.isEmpty)
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger, active: false).firings.isEmpty)
        let disabled = rule(enabled: false)
        #expect(evaluate(.applicationEdge(triggerID: disabled.id, edge: .starts), disabled).firings.isEmpty)
        let invalid = GroupTrigger(groupID: groupID, event: .applicationPresence(bundleIdentifier: "bad/id", edge: .starts), action: .start)
        #expect(evaluate(.applicationEdge(triggerID: invalid.id, edge: .starts), invalid).firings.isEmpty)
    }

    @Test func pauseEchoCooldownAndDailyLimitApply() {
        let trigger = rule()
        var paused = TriggerState()
        paused.pause(until: now.addingTimeInterval(60), reason: .user)
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger, state: paused).state.entry(for: trigger.id).lastOutcome == .skipped(.paused))
        let echo = TriggerEnvironment(echoUntil: now.addingTimeInterval(15))
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger, environment: echo).state.entry(for: trigger.id).lastOutcome == .skipped(.rightAfterAutomaticAction))
        var cooldown = TriggerState()
        cooldown.entries[trigger.id] = .init(lastRunAt: now.addingTimeInterval(-10))
        #expect(evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger, state: cooldown).state.entry(for: trigger.id).lastOutcome == .skipped(.cooldown))
        var daily = trigger
        daily.oncePerDay = true
        var ran = TriggerState()
        ran.entries[daily.id] = .init(lastRunAt: now.addingTimeInterval(-120))
        #expect(evaluate(.applicationEdge(triggerID: daily.id, edge: .starts), daily, state: ran).state.entry(for: daily.id).lastOutcome == .skipped(.alreadyRanToday))
    }

    @Test func sleepingOrInactiveEventsDoNotRunOrReplay() {
        let trigger = rule()
        for environment in [TriggerEnvironment(screensAsleep: true), TriggerEnvironment(sessionActive: false)] {
            let missed = evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), trigger, environment: environment)
            #expect(missed.firings.isEmpty)
            let wakeSignal: TriggerSignal = environment.screensAsleep ? .screens(asleep: false) : .session(active: true)
            #expect(evaluate(wakeSignal, trigger, state: missed.state, environment: environment).firings.isEmpty)
        }
    }
}
