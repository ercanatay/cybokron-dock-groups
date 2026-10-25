import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: turning signals into firings")
struct TriggerEvaluatorTests {
    private static let work = DockGroup.of("Work", ["com.apple.mail"])
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private let calendar = TriggerTime.calendar()
    private let active: Set<DockGroup.ID> = [work.id, design.id]

    /// Wednesday 2026-10-28 at hour:minute:second in Istanbul.
    private func wednesday(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        TriggerTime.date(2026, 10, 28, hour, minute, second)
    }

    private func evaluate(
        _ signal: TriggerSignal,
        _ rules: [GroupTrigger],
        state: TriggerState,
        environment: TriggerEnvironment = TriggerEnvironment(),
        active: Set<DockGroup.ID>? = nil,
        at now: Date
    ) -> TriggerEvaluation {
        TriggerEvaluator.evaluate(signal, rules: rules, state: state, environment: environment, activeGroups: active ?? self.active, now: now, calendar: calendar)
    }

    /// The state once `rules` were set up at `date`, as the coordinator does.
    private func baseline(_ rules: [GroupTrigger], at date: Date) -> TriggerState {
        TriggerEvaluator.baseline(rules: rules, state: TriggerState(), now: date, calendar: calendar)
    }

    // MARK: - Times

    @Test func aTimeFiresOncePerOccurrence() {
        let nine = GroupTrigger.at(9, 0, days: TriggerTime.weekdays, group: Self.work)
        var state = baseline([nine], at: wednesday(8, 59))

        let atNine = evaluate(.clock, [nine], state: state, at: wednesday(9, 0, 4))
        #expect(atNine.firings.map(\.triggerID) == [nine.id])
        #expect(atNine.firings.first?.occurrence == wednesday(9, 0))
        #expect(atNine.firings.first?.action == .start)
        state = atNine.state
        #expect(state.entry(for: nine.id).lastHandledOccurrence == wednesday(9, 0))

        // The clock looking again (a wake, a time zone change) doesn't run it twice.
        #expect(evaluate(.clock, [nine], state: state, at: wednesday(9, 10)).firings.isEmpty)
        #expect(evaluate(.launched(.normal), [nine], state: state, at: wednesday(9, 11)).firings.isEmpty)
    }

    @Test func aTriggerAddedAfterItsTimeWaitsForTheNextOne() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        let state = baseline([nine], at: wednesday(9, 5))
        #expect(evaluate(.clock, [nine], state: state, at: wednesday(9, 6)).firings.isEmpty)
        // A fresh state (a lost file, the first launch of 0.11.0) catches up nothing either.
        #expect(evaluate(.launched(.normal), [nine], state: TriggerState(), at: wednesday(9, 6)).firings.isEmpty)
    }

    @Test func aMissedTimeRunsUpToHalfAnHourLate() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        let state = baseline([nine], at: wednesday(8, 0))

        let twenty = evaluate(.clock, [nine], state: state, at: wednesday(9, 20))
        #expect(twenty.firings.map(\.occurrence) == [wednesday(9, 0)])
        let exactly = evaluate(.clock, [nine], state: state, at: wednesday(9, 30))
        #expect(exactly.firings.count == 1)

        let late = evaluate(.clock, [nine], state: state, at: wednesday(9, 45))
        #expect(late.firings.isEmpty)
        #expect(late.state.entry(for: nine.id).lastOutcome == .missed(.macAsleep))
        #expect(late.state.entry(for: nine.id).lastOutcomeAt == wednesday(9, 0))
        #expect(late.state.entry(for: nine.id).lastHandledOccurrence == wednesday(9, 0))

        let launched = evaluate(.launched(.normal), [nine], state: state, at: wednesday(10, 0))
        #expect(launched.state.entry(for: nine.id).lastOutcome == .missed(.appNotOpen))
        let session = evaluate(.session(active: true), [nine], state: state, environment: TriggerEnvironment(sessionActive: false), at: wednesday(10, 0))
        #expect(session.state.entry(for: nine.id).lastOutcome == .missed(.sessionInactive))
    }

    @Test func onlyTheLatestMissedOccurrenceCounts() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        // Set up on Monday; nothing ran until Wednesday 9:10.
        let state = baseline([nine], at: TriggerTime.date(2026, 10, 26, 8, 0))
        let result = evaluate(.launched(.normal), [nine], state: state, at: wednesday(9, 10))
        #expect(result.firings.map(\.occurrence) == [wednesday(9, 0)])
    }

    @Test func aTimeWaitsWhileTheScreensSleepOrTheSessionIsInactive() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        var state = baseline([nine], at: wednesday(8, 0))
        let asleep = TriggerEnvironment(screensAsleep: true)

        let deferred = evaluate(.clock, [nine], state: state, environment: asleep, at: wednesday(9, 0))
        #expect(deferred.firings.isEmpty)
        #expect(deferred.state.entry(for: nine.id).lastHandledOccurrence == wednesday(8, 0).addingTimeInterval(-23 * 3600))
        state = deferred.state

        // The screens wake at 9:10: it runs.
        let woke = evaluate(.screens(asleep: false), [nine], state: state, environment: asleep, at: wednesday(9, 10))
        #expect(woke.firings.count == 1)
        #expect(!woke.environment.screensAsleep)

        // Woken at 9:40: too late.
        let tooLate = evaluate(.screens(asleep: false), [nine], state: state, environment: asleep, at: wednesday(9, 40))
        #expect(tooLate.firings.isEmpty)
        #expect(tooLate.state.entry(for: nine.id).lastOutcome == .missed(.macAsleep))

        // Another user's session: the same.
        let inactive = TriggerEnvironment(sessionActive: false)
        #expect(evaluate(.clock, [nine], state: state, environment: inactive, at: wednesday(9, 0)).firings.isEmpty)
        #expect(evaluate(.session(active: true), [nine], state: state, environment: inactive, at: wednesday(9, 5)).firings.count == 1)
    }

    @Test func timesThatPassWhileOffOrArchivedDontCatchUp() {
        var nine = GroupTrigger.at(9, 0, group: Self.work)
        nine.isEnabled = false
        var state = baseline([nine], at: wednesday(8, 0))
        state = evaluate(.clock, [nine], state: state, at: wednesday(9, 0)).state
        #expect(state.entry(for: nine.id).lastHandledOccurrence == wednesday(9, 0))
        #expect(state.entry(for: nine.id).lastOutcome == nil)
        nine.isEnabled = true
        #expect(evaluate(.clock, [nine], state: state, at: wednesday(9, 5)).firings.isEmpty)

        // The group archived (not among the active groups) at 9:00, restored at 9:05.
        let other = GroupTrigger.at(9, 0, group: Self.design)
        var archived = baseline([other], at: wednesday(8, 0))
        archived = evaluate(.clock, [other], state: archived, active: [Self.work.id], at: wednesday(9, 0)).state
        #expect(evaluate(.clock, [other], state: archived, at: wednesday(9, 5)).firings.isEmpty)
    }

    @Test func turningATriggerOnStartsFromAFreshBaseline() {
        var nine = GroupTrigger.at(9, 0, group: Self.work)
        nine.isEnabled = false
        let previous = [nine]
        // Off since Monday, no clock signal meanwhile (no timer is armed for a trigger that's off).
        let state = baseline(previous, at: TriggerTime.date(2026, 10, 26, 8, 0))
        nine.isEnabled = true
        let rebased = TriggerEvaluator.rebaseline(previous: previous, rules: [nine], state: state, now: wednesday(9, 10), calendar: calendar)
        #expect(rebased.entry(for: nine.id).lastHandledOccurrence == wednesday(9, 0))
        #expect(evaluate(.clock, [nine], state: rebased, at: wednesday(9, 11)).firings.isEmpty)
        // Deleted triggers' entries go.
        #expect(TriggerEvaluator.rebaseline(previous: previous, rules: [], state: rebased, now: wednesday(9, 12), calendar: calendar).entries.isEmpty)
    }

    @Test func nextDueIsTheEarliestTimeThatCanRun() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        let eight = GroupTrigger.at(8, 30, group: Self.design)
        var off = GroupTrigger.at(7, 0, group: Self.work)
        off.isEnabled = false
        let archived = GroupTrigger.at(7, 30, group: DockGroup.of("Old", []))
        let rules = [nine, eight, off, archived, .on(.login, group: Self.work)]
        #expect(TriggerEvaluator.nextDue(rules: rules, activeGroups: active, after: wednesday(6, 0), calendar: calendar) == wednesday(8, 30))
        #expect(TriggerEvaluator.nextDue(rules: rules, activeGroups: active, after: wednesday(8, 30), calendar: calendar) == wednesday(9, 0))
        #expect(TriggerEvaluator.nextDue(rules: [.on(.login, group: Self.work)], activeGroups: active, after: wednesday(6, 0), calendar: calendar) == nil)
    }

    // MARK: - Login, launch, screens

    @Test func loginRunsOncePerSession() {
        let login = GroupTrigger.on(.login, group: Self.work)
        let opens = GroupTrigger.on(.appOpens, group: Self.design, action: .showPopup)
        let rules = [login, opens]
        let session = wednesday(8, 0)
        let state = baseline(rules, at: session)

        let first = evaluate(.launched(.login(session: session)), rules, state: state, at: wednesday(8, 1))
        #expect(Set(first.firings.map(\.triggerID)) == [login.id, opens.id])
        #expect(first.state.lastLoginSession == session)

        // Opened again in the same session (after quitting it): only "opens".
        let again = evaluate(.launched(.login(session: session)), rules, state: first.state, at: wednesday(10, 0))
        #expect(again.firings.map(\.triggerID) == [opens.id])
        #expect(evaluate(.launched(.normal), rules, state: first.state, at: wednesday(11, 0)).firings.map(\.triggerID) == [opens.id])
        // A quiet launch (a link, an update) runs neither.
        #expect(evaluate(.launched(.quiet), rules, state: state, at: wednesday(8, 1)).firings.isEmpty)
        // The next login session runs it again.
        let tomorrow = TriggerTime.date(2026, 10, 29, 8, 0)
        #expect(evaluate(.launched(.login(session: tomorrow)), rules, state: first.state, at: tomorrow).firings.count == 2)
    }

    @Test func screensWakeAndSleepAreChanges() {
        let wake = GroupTrigger.on(.screensWake, group: Self.work, action: .showPopup)
        let sleep = GroupTrigger.on(.screensSleep, group: Self.design, action: .finish)
        let rules = [wake, sleep]
        let state = baseline(rules, at: wednesday(8, 0))

        let asleep = evaluate(.screens(asleep: true), rules, state: state, at: wednesday(9, 0))
        #expect(asleep.firings.map(\.triggerID) == [sleep.id])
        #expect(asleep.environment.screensAsleep)
        // Told twice: nothing more.
        #expect(evaluate(.screens(asleep: true), rules, state: asleep.state, environment: asleep.environment, at: wednesday(9, 1)).firings.isEmpty)

        let awake = evaluate(.screens(asleep: false), rules, state: asleep.state, environment: asleep.environment, at: wednesday(9, 30))
        #expect(awake.firings.map(\.triggerID) == [wake.id])
        // Awake already: no wake.
        #expect(evaluate(.screens(asleep: false), rules, state: state, at: wednesday(9, 31)).firings.isEmpty)
    }

    // MARK: - Conditions

    @Test func aConditionFiresOnAChangeBetweenKnownReadings() {
        let connects = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: Self.work)
        let disconnects = GroupTrigger.on(.condition(.ethernet, edge: .ends), group: Self.design, action: .showPopup)
        let rules = [connects, disconnects]
        var state = baseline(rules, at: wednesday(8, 0))

        // The first reading is a baseline.
        let first = evaluate(.network(NetworkReading(usesEthernet: false)), rules, state: state, at: wednesday(9, 0))
        #expect(first.firings.isEmpty)
        state = first.state
        #expect(state.entry(for: connects.id).condition == 0)

        // Unknown changes nothing, either way.
        let unknown = evaluate(.network(.unknown), rules, state: state, at: wednesday(9, 1))
        #expect(unknown.firings.isEmpty)
        #expect(unknown.state.entry(for: connects.id).condition == 0)

        let plugged = evaluate(.network(NetworkReading(usesEthernet: true)), rules, state: unknown.state, at: wednesday(9, 2))
        #expect(plugged.firings.map(\.triggerID) == [connects.id])
        #expect(plugged.firings.first?.occurrence == wednesday(9, 2))
        let again = evaluate(.network(NetworkReading(usesEthernet: true)), rules, state: plugged.state, at: wednesday(9, 3))
        #expect(again.firings.isEmpty)

        let unplugged = evaluate(.network(NetworkReading(usesEthernet: false)), rules, state: again.state, at: wednesday(9, 5))
        #expect(unplugged.firings.map(\.triggerID) == [disconnects.id])
        // Display signals aren't about the network.
        #expect(evaluate(.displays([]), rules, state: unplugged.state, at: wednesday(9, 6)).state == unplugged.state)
    }

    @Test func lostSightOfTheNetworkIsNeverLeavingIt() {
        let leaves = GroupTrigger.on(.condition(.wifi(WiFiNetworkName("Office")!), edge: .ends), group: Self.work, action: .finish)
        var state = baseline([leaves], at: wednesday(8, 0))
        state = evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("Office")!))), [leaves], state: state, at: wednesday(8, 1)).state
        // Location access taken back: the name is unknown, nothing runs, the reading stays.
        let lost = evaluate(.network(NetworkReading(wifi: .unknown)), [leaves], state: state, at: wednesday(9, 0))
        #expect(lost.firings.isEmpty)
        #expect(lost.state.entry(for: leaves.id).condition == 1)
        // Really leaving: another network, or none.
        #expect(evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("Home")!))), [leaves], state: state, at: wednesday(9, 1)).firings.count == 1)
        #expect(evaluate(.network(NetworkReading(wifi: .notConnected)), [leaves], state: state, at: wednesday(9, 1)).firings.count == 1)
        // Names are matched exactly.
        #expect(evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("office")!))), [leaves], state: state, at: wednesday(9, 1)).firings.count == 1)
    }

    @Test func displaysCountWhatsConnected() {
        let anyExternal = GroupTrigger.on(.condition(.display(.anyExternal), edge: .starts), group: Self.work, action: .openAll)
        let lg = GroupTrigger.on(.condition(.display(.display(.monitor("LG", vendor: 7))), edge: .ends), group: Self.design, action: .showPopup)
        let desk = GroupTrigger.on(.condition(.displays(DisplayArrangement(displays: [.builtIn, .monitor("LG", vendor: 7)])), edge: .starts), group: Self.design, action: .start)
        let rules = [anyExternal, lg, desk]
        var state = baseline(rules, at: wednesday(8, 0))
        state = evaluate(.displays([.builtIn]), rules, state: state, at: wednesday(8, 1)).state

        let plugged = evaluate(.displays([.builtIn, .monitor("LG", vendor: 7)]), rules, state: state, at: wednesday(9, 0))
        #expect(Set(plugged.firings.map(\.triggerID)) == [anyExternal.id, desk.id])
        // A second external display is another one connecting.
        let second = evaluate(.displays([.builtIn, .monitor("LG", vendor: 7), .monitor("Dell", vendor: 8)]), rules, state: plugged.state, at: wednesday(9, 5))
        #expect(second.firings.map(\.triggerID) == [anyExternal.id])
        // The LG leaves: its end; the desk no longer matches (an end, but that trigger waits for the start).
        let unplugged = evaluate(.displays([.builtIn, .monitor("Dell", vendor: 8)]), rules, state: second.state, at: wednesday(9, 10))
        #expect(unplugged.firings.map(\.triggerID) == [lg.id])
        // Unreadable displays change nothing.
        #expect(evaluate(.displays(nil), rules, state: unplugged.state, at: wednesday(9, 11)).state == unplugged.state)
        // Closing the lid isn't an external display leaving.
        #expect(evaluate(.displays([.monitor("Dell", vendor: 8)]), rules, state: unplugged.state, at: wednesday(9, 12)).firings.isEmpty)
    }

    @Test func aStartsOwnFinishComesWithTheEnd() {
        let start = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: Self.work, finishesWhenEventEnds: true, oncePerDay: true)
        var state = baseline([start], at: wednesday(8, 0))
        state = evaluate(.network(NetworkReading(usesEthernet: false)), [start], state: state, at: wednesday(8, 1)).state
        let plugged = evaluate(.network(NetworkReading(usesEthernet: true)), [start], state: state, at: wednesday(9, 0))
        #expect(plugged.firings.map(\.action) == [.start])
        // It ran (as the coordinator records), then the cable comes out 20 seconds later: the finish
        // isn't held back by the cooldown or At most once a day.
        var ran = plugged.state
        ran.recordRun(.start, for: start.id, at: wednesday(9, 0, 5))
        let unplugged = evaluate(.network(NetworkReading(usesEthernet: false)), [start], state: ran, at: wednesday(9, 0, 25))
        #expect(unplugged.firings.count == 1)
        #expect(unplugged.firings.first?.action == .finish)
        #expect(unplugged.firings.first?.isFinishWhenEnded == true)
    }

    @Test func aTriggerAddedWhileItsConditionHoldsWaitsForTheNextChange() {
        let connects = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: Self.work)
        let state = baseline([connects], at: wednesday(9, 0))
        #expect(evaluate(.network(NetworkReading(usesEthernet: true)), [connects], state: state, at: wednesday(9, 0, 5)).firings.isEmpty)
    }

    /// Kept across launches: a change between the last reading before quitting and the first after
    /// launching is an edge; an unchanged one isn't.
    @Test func conditionsAreRememberedAcrossLaunches() throws {
        let joins = GroupTrigger.on(.condition(.wifi(WiFiNetworkName("Office")!), edge: .starts), group: Self.work)
        var state = baseline([joins], at: wednesday(8, 0))
        state = evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("Home")!))), [joins], state: state, at: wednesday(8, 1)).state
        let saved = try JSONEncoder().encode(state)
        let reloaded = JSONFileTriggerStatePersistence.decode(saved)
        #expect(reloaded == state)
        let office = evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("Office")!))), [joins], state: reloaded, at: wednesday(10, 0))
        #expect(office.firings.count == 1)
        let stillHome = evaluate(.network(NetworkReading(wifi: .connected(WiFiNetworkName("Home")!))), [joins], state: reloaded, at: wednesday(10, 0))
        #expect(stillHome.firings.isEmpty)
    }

    // MARK: - Gates

    @Test func theCooldownHoldsBackASecondRun() {
        let wake = GroupTrigger.on(.screensWake, group: Self.work, action: .showPopup)
        var state = baseline([wake], at: wednesday(8, 0))
        state.recordRun(.showPopup, for: wake.id, at: wednesday(9, 0))
        let asleep = TriggerEnvironment(screensAsleep: true)
        let soon = evaluate(.screens(asleep: false), [wake], state: state, environment: asleep, at: wednesday(9, 0, 40))
        #expect(soon.firings.isEmpty)
        #expect(soon.state.entry(for: wake.id).lastOutcome == .skipped(.cooldown))
        #expect(evaluate(.screens(asleep: false), [wake], state: state, environment: asleep, at: wednesday(9, 1, 1)).firings.count == 1)
    }

    @Test func atMostOnceADayWaitsForTheNextDay() {
        let wake = GroupTrigger.on(.screensWake, group: Self.work, action: .showPopup, oncePerDay: true)
        var state = baseline([wake], at: wednesday(8, 0))
        state.recordRun(.showPopup, for: wake.id, at: wednesday(9, 0))
        let asleep = TriggerEnvironment(screensAsleep: true)
        let later = evaluate(.screens(asleep: false), [wake], state: state, environment: asleep, at: wednesday(23, 59))
        #expect(later.state.entry(for: wake.id).lastOutcome == .skipped(.alreadyRanToday))
        #expect(evaluate(.screens(asleep: false), [wake], state: state, environment: asleep, at: TriggerTime.date(2026, 10, 29, 0, 1)).firings.count == 1)
    }

    @Test func theEchoWindowHoldsBackChangesOnly() {
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: Self.work)
        let nine = GroupTrigger.at(9, 0, group: Self.design, action: .openAll)
        let rules = [plugged, nine]
        var state = baseline(rules, at: wednesday(8, 0))
        state = evaluate(.network(NetworkReading(usesEthernet: false)), rules, state: state, at: wednesday(8, 1)).state
        let echo = TriggerEnvironment(echoUntil: wednesday(9, 0, 15))

        let change = evaluate(.network(NetworkReading(usesEthernet: true)), rules, state: state, environment: echo, at: wednesday(9, 0, 5))
        #expect(change.firings.isEmpty)
        #expect(change.state.entry(for: plugged.id).lastOutcome == .skipped(.rightAfterAutomaticAction))
        // The reading is taken: it won't fire later for the same change.
        #expect(change.state.entry(for: plugged.id).condition == 1)
        #expect(evaluate(.network(NetworkReading(usesEthernet: true)), rules, state: change.state, at: wednesday(9, 1)).firings.isEmpty)

        let time = evaluate(.clock, rules, state: state, environment: echo, at: wednesday(9, 0, 5))
        #expect(time.firings.map(\.triggerID) == [nine.id])
    }

    @Test func whatComesWhilePausedIsSkippedNotKept() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        var state = baseline([nine], at: wednesday(8, 0))
        state.pause(until: wednesday(10, 0), reason: .user)
        let paused = evaluate(.clock, [nine], state: state, at: wednesday(9, 0))
        #expect(paused.firings.isEmpty)
        #expect(paused.state.entry(for: nine.id).lastOutcome == .skipped(.paused))
        #expect(paused.state.entry(for: nine.id).lastHandledOccurrence == wednesday(9, 0))
        #expect(evaluate(.clock, [nine], state: paused.state, at: wednesday(10, 1)).firings.isEmpty)
    }

    @Test func triggersThatCantRunNeverFire() {
        let unsupported = GroupTrigger(groupID: Self.work.id, event: .unsupported(.object(["kind": .string("calendar")])), action: .start)
        let wrongAction = GroupTrigger(groupID: Self.work.id, event: .login, action: .finish)
        let badTime = GroupTrigger(groupID: Self.work.id, event: .schedule(TriggerSchedule(minuteOfDay: 2000, weekdays: [4])), action: .start)
        let deletedGroup = GroupTrigger.on(.login, group: DockGroup.of("Gone", []))
        let rules = [unsupported, wrongAction, badTime, deletedGroup]
        let state = baseline(rules, at: wednesday(8, 0))
        for signal in [TriggerSignal.clock, .launched(.login(session: wednesday(8, 0))), .launched(.normal), .network(NetworkReading(usesEthernet: true))] {
            #expect(evaluate(signal, rules, state: state, at: wednesday(9, 0)).firings.isEmpty)
        }
    }

    @Test func firingsCarryTheirPlaceInTheList() {
        let first = GroupTrigger.on(.login, group: Self.work)
        let second = GroupTrigger.on(.login, group: Self.design)
        let firings = evaluate(.launched(.login(session: wednesday(8, 0))), [first, second], state: TriggerState(), at: wednesday(8, 1)).firings
        #expect(firings.map(\.order) == [0, 1])
    }
}
