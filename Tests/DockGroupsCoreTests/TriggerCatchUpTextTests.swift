import Foundation
import Testing
@testable import DockGroupsCore

/// What "run what was missed" shows (`docs/design/app-presence-catch-up.md` D7): the editor's
/// option for application triggers only, the notice's line, and the last-run line with its trace
/// "(after the Mac woke)", kept in `trigger-state.json` only as words.
@Suite("Triggers: run what was missed, texts")
@MainActor
struct TriggerCatchUpTextTests {
    private static let key = "com.example.app"
    private static let uk = Locale(identifier: "en_GB")
    private let work = TriggerRig.work

    private func rule(_ edge: TriggerEdge = .starts, action: TriggerAction = .openAll, catchUp: Bool = true) -> GroupTrigger {
        var trigger = GroupTrigger.on(.applicationPresence(bundleIdentifier: Self.key, edge: edge), group: TriggerRig.work, action: action)
        trigger.catchUp = catchUp
        return trigger
    }

    private func throughGap(_ rules: [GroupTrigger], before: [String: Int] = [key: 0], gap: TimeInterval = 600) -> CatchUpDriver {
        let driver = CatchUpDriver(TriggerRig(rules))
        #expect(driver.begin())
        #expect(driver.observe(before) == .accepted(isUncertain: false))
        driver.signal(.screens(asleep: true))
        driver.rig.clock.advance(gap)
        driver.signal(.screens(asleep: false))
        return driver
    }

    private func line(_ entry: TriggerState.Entry, now: Date) -> String {
        TriggerDescriptions.lastRun(entry, groupName: "Work", now: now, calendar: TriggerTime.calendar(locale: "en_GB"), locale: Self.uk)
    }

    // MARK: - Editor

    @Test func theOptionIsOfferedOnlyForApplicationTriggersAndOffByDefault() {
        let calendar = TriggerTime.calendar()
        var draft = TriggerDraft(calendar: calendar)
        #expect(!draft.catchUp)
        for when in TriggerDraft.When.offered {
            draft.setWhen(when)
            if case .application = when {
                #expect(draft.canCatchUp)
            } else {
                #expect(!draft.canCatchUp)
            }
        }
        draft.setWhen(.application(.starts))
        #expect(!draft.catchUp)
    }

    @Test func turnedOnItIsSavedAndReadBackWhenTheEditorOpensAgain() throws {
        let calendar = TriggerTime.calendar()
        for edge in [TriggerEdge.starts, .ends] {
            let saved = rule(edge, catchUp: false)
            var draft = try #require(TriggerDraft(editing: saved, calendar: calendar))
            #expect(!draft.catchUp)
            draft.catchUp = true
            let trigger = draft.trigger(groupID: work.id, replacing: saved)
            #expect(trigger.catchUp && trigger.catchesUp)
            let read = try JSONDecoder().decode(GroupTrigger.self, from: JSONEncoder().encode(trigger))
            let reopened = try #require(TriggerDraft(editing: read, calendar: calendar))
            #expect(reopened.catchUp)
            // Turned off again: saved off.
            var off = reopened
            off.catchUp = false
            #expect(!off.trigger(groupID: work.id, replacing: read).catchUp)
        }
    }

    @Test func anotherEventTurnsItOffAndComingBackKeepsItOff() throws {
        let calendar = TriggerTime.calendar()
        let saved = rule(.starts)
        for when in TriggerDraft.When.offered where when != .application(.starts) && when != .application(.ends) {
            var draft = try #require(TriggerDraft(editing: saved, calendar: calendar))
            #expect(draft.catchUp)
            draft.setWhen(when)
            #expect(!draft.catchUp)
            #expect(!draft.trigger(groupID: work.id, replacing: saved).catchUp)
            draft.setWhen(.application(.starts))
            #expect(!draft.catchUp)
        }
        // Opens ↔ closes keeps it: both are application triggers.
        var draft = try #require(TriggerDraft(editing: saved, calendar: calendar))
        draft.setWhen(.application(.ends))
        #expect(draft.catchUp)
        // A non-application trigger whose file says catchUp opens with it off.
        var login = GroupTrigger.on(.login, group: work)
        login.catchUp = true
        #expect(try #require(TriggerDraft(editing: login, calendar: calendar)).catchUp == false)
    }

    // MARK: - Notice

    @Test func theNoticeSaysTheAppOpenedOrQuitWhileTheMacWasAsleep() {
        let calendar = TriggerTime.calendar()
        func detail(_ trigger: GroupTrigger, _ isCatchUp: Bool) -> String {
            TriggerDescriptions.noticeDetail(trigger, isCatchUp: isCatchUp, appName: "Cybokron Dock Groups", calendar: calendar, locale: Self.uk)
        }
        #expect(detail(rule(.starts), true) == "com.example.app opened while the Mac was asleep")
        #expect(detail(rule(.ends), true) == "com.example.app quit while the Mac was asleep")
        // A firing that wasn't a catch-up: what the trigger waits for, as before.
        #expect(detail(rule(.starts), false) == "When com.example.app opens")
        #expect(detail(rule(.ends), false) == "When com.example.app closes")
        #expect(detail(rule(.starts), false) == TriggerDescriptions.event(rule(.starts).event, appName: "Cybokron Dock Groups", calendar: calendar, locale: Self.uk))
        // Only application triggers catch up; any other event reads as before.
        let wake = GroupTrigger.on(.screensWake, group: work)
        #expect(detail(wake, true) == "When the screens wake")
    }

    @Test func aCatchUpNoticeIsMarkedAndAnObservedOneIsNot() async {
        let caughtUp = throughGap([rule(.starts, action: .start)])
        caughtUp.observe([Self.key: 1])
        await caughtUp.rig.settleDown()
        #expect(caughtUp.rig.presenter.shown.map(\.isCatchUp) == [true])

        var notice = rule(.starts, action: .start)
        notice.runMode = .notice
        let observed = CatchUpDriver(TriggerRig([notice]))
        #expect(observed.begin())
        observed.observe([Self.key: 0])
        observed.observe([Self.key: 1])
        await observed.rig.settleDown()
        #expect(observed.rig.presenter.shown.map(\.isCatchUp) == [false])
    }

    // MARK: - Last-run line

    @Test func aCatchUpRunLeavesATraceInTheLastRunLine() async {
        let opens = rule(.starts)
        let driver = throughGap([opens])
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        let entry = driver.rig.coordinator.state.entry(for: opens.id)
        #expect(entry.lastOutcome == .ran(.openAll))
        #expect(entry.isCatchUp)
        let now = driver.rig.clock.now
        let text = line(entry, now: now)
        #expect(text.hasPrefix("Last ran today at "))
        #expect(text.hasSuffix(" (after the Mac woke): opened “Work”."))
        // The next observed run is an ordinary one again.
        driver.rig.clock.advance(120)
        driver.observe([Self.key: 0])
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        let next = driver.rig.coordinator.state.entry(for: opens.id)
        #expect(next.lastOutcome == .ran(.openAll))
        #expect(!next.isCatchUp)
        #expect(!line(next, now: driver.rig.clock.now).contains("after the Mac woke"))
    }

    @Test func anObservedRunIsDescribedAsBefore() async {
        let opens = rule(.starts)
        let driver = CatchUpDriver(TriggerRig([opens]))
        #expect(driver.begin())
        driver.observe([Self.key: 0])
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        let entry = driver.rig.coordinator.state.entry(for: opens.id)
        #expect(!entry.isCatchUp)
        let text = line(entry, now: driver.rig.clock.now)
        #expect(text.hasPrefix("Last ran today at "))
        #expect(text.hasSuffix(": opened “Work”."))
        #expect(!text.contains("after the Mac woke"))
    }

    @Test func skippedAndMissedCatchUpsSayWhy() async {
        let now = TriggerTime.date(2026, 10, 28, 10, 0)
        let today = TriggerTime.date(2026, 10, 28, 9, 0)
        #expect(line(.init(lastOutcome: .skipped(.rightAfterAutomaticAction), lastOutcomeAt: today, isCatchUp: true), now: now)
            == "Skipped today at 09:00 (after the Mac woke): it came right after another automatic action.")
        #expect(line(.init(lastOutcome: .skipped(.notNow), lastOutcomeAt: today, isCatchUp: true), now: now)
            == "Skipped today at 09:00 (after the Mac woke): you chose Not Now.")
        #expect(line(.init(lastOutcome: .missed(.macAsleep), lastOutcomeAt: today, isCatchUp: true), now: now)
            == "Missed today at 09:00 (after the Mac woke): it changed too long ago, or too many triggers caught up at once.")
        #expect(line(.init(lastOutcome: .missed(.sessionInactive), lastOutcomeAt: today, isCatchUp: true), now: now)
            == "Missed today at 09:00 (after the Mac woke): it changed too long ago, or too many triggers caught up at once.")
        // A missed time is described as before.
        #expect(line(.init(lastOutcome: .missed(.macAsleep), lastOutcomeAt: today), now: now) == "Missed today at 09:00: the Mac was asleep.")

        // Recorded by the coordinator: a gap over 30 minutes, the echo after the wake.
        let opens = rule(.starts)
        let long = throughGap([opens], gap: TriggerCoordinator.catchUpLongestGap + 1)
        long.observe([Self.key: 1])
        await long.rig.settleDown()
        let missed = long.rig.coordinator.state.entry(for: opens.id)
        #expect(missed.lastOutcome == .missed(.macAsleep) && missed.isCatchUp)
        #expect(line(missed, now: long.rig.clock.now).hasSuffix("(after the Mac woke): it changed too long ago, or too many triggers caught up at once."))

        let wake = GroupTrigger.on(.screensWake, group: TriggerRig.design, action: .openAll)
        let echo = throughGap([opens, wake])
        await echo.rig.settleDown()
        echo.rig.clock.advance(20)
        echo.observe([Self.key: 1])
        await echo.rig.settleDown()
        let skipped = echo.rig.coordinator.state.entry(for: opens.id)
        #expect(skipped.lastOutcome == .skipped(.rightAfterAutomaticAction) && skipped.isCatchUp)
        // The wake trigger's own run is not a catch-up.
        #expect(!echo.rig.coordinator.state.entry(for: wake.id).isCatchUp)
    }

    @Test func aSkipFromTheNoticeOfACatchUpIsMarked() async {
        let driver = throughGap([rule(.starts)])
        driver.rig.presenter.answers = [.notNow]
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        let entry = driver.rig.coordinator.state.entry(for: driver.rig.rules[0].id)
        #expect(entry.lastOutcome == .skipped(.notNow) && entry.isCatchUp)
    }

    // MARK: - Saving the trace

    @Test func theTraceIsWrittenOnlyWhenOnAndReadOnlyWithAnOutcome() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func encoded(_ entry: TriggerState.Entry) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(entry), as: UTF8.self)
        }
        func decode(_ json: String) throws -> TriggerState.Entry {
            try JSONDecoder().decode(TriggerState.Entry.self, from: Data(json.utf8))
        }
        let plain = TriggerState.Entry(lastRunAt: at, lastOutcome: .ran(.start), lastOutcomeAt: at)
        #expect(try !encoded(plain).contains("catchUp"))
        #expect(try decode(encoded(plain)) == plain)

        let caughtUp = TriggerState.Entry(lastRunAt: at, lastOutcome: .ran(.start), lastOutcomeAt: at, isCatchUp: true)
        #expect(try encoded(caughtUp).contains(#""catchUp":true"#))
        #expect(try decode(encoded(caughtUp)) == caughtUp)

        // Anything but true, or without an outcome to describe: no trace.
        #expect(try !decode(#"{"lastOutcome":{"ran":"start"},"catchUp":"yes"}"#).isCatchUp)
        #expect(try !decode(#"{"lastOutcome":{"ran":"start"},"catchUp":1}"#).isCatchUp)
        #expect(try !decode(#"{"catchUp":true}"#).isCatchUp)
        #expect(try !encoded(TriggerState.Entry(isCatchUp: true)).contains("catchUp"))
        // A whole state file keeps it per trigger.
        let id = UUID()
        let state = TriggerState(entries: [id: caughtUp])
        let read = try JSONDecoder().decode(TriggerState.self, from: JSONEncoder().encode(state))
        #expect(read.entry(for: id).isCatchUp)
    }

    @Test func anyNewOutcomeClearsTheTrace() {
        var entry = TriggerState.Entry(lastOutcome: .ran(.start), isCatchUp: true)
        entry.lastOutcome = .skipped(.paused)
        #expect(!entry.isCatchUp)
        var state = TriggerState()
        let id = UUID()
        state.recordRun(.start, for: id, at: Date(), isCatchUp: true)
        #expect(state.entry(for: id).isCatchUp)
        state.record(.skipped(.cooldown), for: id, at: Date())
        #expect(!state.entry(for: id).isCatchUp)
    }
}
