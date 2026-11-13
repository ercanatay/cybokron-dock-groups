import Foundation
import Testing
@testable import DockGroupsCore

/// Drives a `TriggerRig`'s application observations the way `TriggerController` does: a generation
/// per start, snapshots in sequence, and on a sleep, wake or session change the same order of calls
/// (`handleWorkspaceSignal`): the signal first, then the stop and the verifier's reset, and on a wake
/// a fresh generation.
@MainActor
final class CatchUpDriver {
    let rig: TriggerRig
    private(set) var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    init(_ rig: TriggerRig) {
        self.rig = rig
    }

    @discardableResult
    func begin() -> Bool {
        generation += 1
        sequence = 0
        return rig.coordinator.beginApplicationObservations(generation: generation)
    }

    @discardableResult
    func observe(_ counts: [String: Int]) -> TriggerCoordinator.ApplicationObservationOutcome {
        sequence += 1
        return rig.coordinator.observeApplications(generation: generation, sequence: sequence, counts: counts)
    }

    /// A workspace signal, handled as `TriggerController.handleWorkspaceSignal` handles it.
    func signal(_ signal: TriggerSignal) {
        let couldAct = rig.coordinator.environment.canAct
        rig.coordinator.receive(signal)
        let canAct = rig.coordinator.environment.canAct
        guard couldAct != canAct else { return }
        if canAct {
            rig.coordinator.resetApplicationIdentityVerification()
            rig.coordinator.stopApplicationObservations()
            begin()
        } else {
            rig.coordinator.stopApplicationObservations()
            rig.coordinator.resetApplicationIdentityVerification()
        }
    }
}

/// "Run what was missed" for application triggers (`docs/design/app-presence-catch-up.md`): a net
/// change between the last trusted reading before a sleep, display sleep or session gap and the
/// first one after it runs once, through every gate, with a notice. Fake clock and sleeper: nothing
/// really sleeps or waits.
@Suite("Triggers: run what was missed")
@MainActor
struct TriggerCatchUpTests {
    private let work = TriggerRig.work
    private let design = TriggerRig.design
    private nonisolated static let key = "com.example.app"

    // MARK: - Helpers

    private func rule(
        _ edge: TriggerEdge = .starts,
        bundle: String = key,
        group: DockGroup = TriggerRig.work,
        action: TriggerAction = .start,
        runMode: TriggerRunMode? = .immediately,
        catchUp: Bool = true
    ) -> GroupTrigger {
        var trigger = GroupTrigger.on(.applicationPresence(bundleIdentifier: bundle, edge: edge), group: group, action: action, runMode: runMode)
        trigger.catchUp = catchUp
        return trigger
    }

    /// A rig whose observations started and read `before` (running or not), then went through a
    /// gap of `gap` seconds (`asleep`/`awake` signals) — the first reading after it not yet made.
    private func throughGap(
        _ rules: [GroupTrigger],
        before: [String: Int] = [key: 0],
        gap: TimeInterval = 600,
        asleep: TriggerSignal = .screens(asleep: true),
        awake: TriggerSignal = .screens(asleep: false),
        state: TriggerState = TriggerState()
    ) -> CatchUpDriver {
        let driver = CatchUpDriver(TriggerRig(rules, state: state))
        #expect(driver.begin())
        #expect(driver.observe(before) == .accepted(isUncertain: false))
        driver.signal(asleep)
        driver.rig.clock.advance(gap)
        driver.signal(awake)
        return driver
    }

    // MARK: - The net change

    @Test func anAppThatOpenedDuringSleepRunsItsTriggerOnceWithANotice() async {
        let opens = rule(.starts)
        let driver = throughGap([opens])
        #expect(driver.rig.coordinator.catchUpReadingCount == 1)
        driver.observe([Self.key: 1])
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["start:Work:automation"])
        #expect(driver.rig.outcome(opens) == .ran(.start))
        // Run Right Away was set: a catch-up still shows the notice (D6).
        #expect(driver.rig.presenter.shown.count == 1)
        #expect(driver.rig.presenter.shown.first?.runMode == .notice)
        #expect(driver.rig.presenter.shown.first?.isCatchUp == true)
        // Used up: later readings are compared with each other only, as observed edges.
        driver.rig.clock.advance(120)
        driver.observe([Self.key: 0])
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.count == 2)
        #expect(driver.rig.presenter.shown.count == 1)
    }

    @Test func anAppThatQuitDuringSleepRunsItsClosesTrigger() async {
        let closes = rule(.ends, action: .openAll)
        let driver = throughGap([closes], before: [Self.key: 2])
        driver.observe([Self.key: 0])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Work"])
        #expect(driver.rig.outcome(closes) == .ran(.openAll))
    }

    @Test func eachRuleOnlyRunsForItsOwnEdge() async {
        let opens = rule(.starts, action: .openAll)
        let closes = rule(.ends, group: TriggerRig.design, action: .openAll)
        // Quit during the sleep: only the closes trigger.
        let quit = throughGap([opens, closes], before: [Self.key: 1])
        quit.observe([Self.key: 0])
        await quit.rig.settleDown()
        #expect(quit.rig.handler.calls == ["openAll:Design"])
        #expect(quit.rig.outcome(opens) == nil)
        // Opened during the sleep: only the opens trigger.
        let opened = throughGap([opens, closes], before: [Self.key: 0])
        opened.observe([Self.key: 3])
        await opened.rig.settleDown()
        #expect(opened.rig.handler.calls == ["openAll:Work"])
        #expect(opened.rig.outcome(closes) == nil)
    }

    @Test func noNetChangeRunsNothingEvenIfTheAppQuitAndOpenedAgain() async {
        // Running before and after (a quit and relaunch during the gap can't be seen), and not
        // running before and after (an open and quit during the gap can't be seen either).
        for count in [0, 1] {
            let driver = throughGap([rule(.starts), rule(.ends, group: TriggerRig.design)], before: [Self.key: count])
            driver.observe([Self.key: count])
            await driver.rig.settleDown()
            #expect(driver.rig.handler.calls.isEmpty)
            #expect(driver.rig.presenter.shown.isEmpty)
        }
        // Another number of instances is no change either.
        let more = throughGap([rule(.starts)], before: [Self.key: 1])
        more.observe([Self.key: 3])
        await more.rig.settleDown()
        #expect(more.rig.handler.calls.isEmpty)
    }

    @Test func withoutAGapTheFirstReadingIsOnlyABaseline() async {
        let opens = rule(.starts)
        let driver = CatchUpDriver(TriggerRig([opens]))
        #expect(driver.begin())
        driver.observe([Self.key: 0])
        // The source restarts while the Mac is awake (a rule change, a verdict change): no gap.
        driver.rig.coordinator.stopApplicationObservations()
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        #expect(driver.begin())
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
        #expect(driver.rig.outcome(opens) == nil)
    }

    @Test func theOptionIsOffByDefaultAndThenNothingIsKept() async {
        let opens = rule(.starts, catchUp: false)
        #expect(GroupTrigger(groupID: work.id, event: .applicationPresence(bundleIdentifier: Self.key, edge: .starts), action: .start).catchUp == false)
        let driver = throughGap([opens])
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
    }

    @Test func anUnknownReadingOnEitherSideIsNeverNotRunning() async {
        // Unknown before the gap (an uncertain snapshot after the trusted one): nothing is kept.
        let opens = rule(.starts)
        let before = CatchUpDriver(TriggerRig([opens]))
        #expect(before.begin())
        before.observe([Self.key: 0])
        before.observe([:])
        before.signal(.screens(asleep: true))
        #expect(before.rig.coordinator.catchUpReadingCount == 0)
        before.signal(.screens(asleep: false))
        before.observe([Self.key: 1])
        await before.rig.settleDown()
        #expect(before.rig.handler.calls.isEmpty)
        // Unknown after the gap: no comparison yet; the kept reading waits for a trusted one.
        let after = throughGap([opens])
        #expect(after.observe([:]) == .accepted(isUncertain: true))
        #expect(after.rig.coordinator.catchUpReadingCount == 1)
        after.rig.clock.advance(20)
        after.observe([Self.key: 1])
        await after.rig.settleDown()
        #expect(after.rig.handler.calls == ["start:Work:automation"])
    }

    // MARK: - Which gaps (D5)

    @Test func displaySleepAndAnotherUsersSessionAreGapsToo() async {
        let opens = rule(.starts, action: .openAll)
        let session = throughGap([opens], asleep: .session(active: false), awake: .session(active: true))
        session.observe([Self.key: 1])
        await session.rig.settleDown()
        #expect(session.rig.handler.calls == ["openAll:Work"])
        // Display sleep, then the Mac sleeping too (a repeated report), then waking: one gap.
        let driver = CatchUpDriver(TriggerRig([opens]))
        #expect(driver.begin())
        driver.observe([Self.key: 0])
        driver.signal(.screens(asleep: true))
        driver.signal(.screens(asleep: true))
        driver.rig.clock.advance(300)
        driver.signal(.screens(asleep: false))
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Work"])
    }

    @Test func wokeAndSleptAgainBeforeAReadingTheSameGapGoesOn() async {
        let opens = rule(.starts, action: .openAll)
        let driver = throughGap([opens], gap: 60)
        driver.rig.clock.advance(5)
        driver.signal(.screens(asleep: true))
        #expect(driver.rig.coordinator.catchUpReadingCount == 1)
        driver.rig.clock.advance(60)
        driver.signal(.screens(asleep: false))
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Work"])
    }

    // MARK: - Bounds (D2, D3)

    @Test func aGapOfExactlyThirtyMinutesStillCatchesUp() async {
        let opens = rule(.starts, action: .openAll)
        let driver = throughGap([opens], gap: TriggerCoordinator.catchUpLongestGap)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Work"])
        #expect(TriggerCoordinator.catchUpLongestGap == 30 * 60)
    }

    @Test func aLongerGapIsRecordedMissedAtItsEnd() async {
        let opens = rule(.starts, action: .openAll)
        let driver = throughGap([opens], gap: TriggerCoordinator.catchUpLongestGap + 1)
        let end = driver.rig.clock.now
        driver.rig.clock.advance(3)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
        #expect(driver.rig.outcome(opens) == .missed(.macAsleep))
        #expect(driver.rig.coordinator.state.entry(for: opens.id).lastOutcomeAt == end)
        // Another user's long session says so.
        let session = throughGap([opens], gap: 3600, asleep: .session(active: false), awake: .session(active: true))
        session.observe([Self.key: 1])
        await session.rig.settleDown()
        #expect(session.rig.outcome(opens) == .missed(.sessionInactive))
        // A long gap without a change records nothing.
        let unchanged = throughGap([opens], gap: 3600)
        unchanged.observe([Self.key: 0])
        #expect(unchanged.rig.outcome(opens) == nil)
    }

    @Test func atMostThreeCatchUpsPerWakeTheRestAreMissed() async {
        let bundles = ["com.example.a", "com.example.b", "com.example.c", "com.example.d"]
        let rules = bundles.enumerated().map { index, bundle in
            rule(.starts, bundle: bundle, group: index.isMultiple(of: 2) ? TriggerRig.work : TriggerRig.design, action: .showPopup)
        }
        let closed = Dictionary(uniqueKeysWithValues: bundles.map { ($0, 0) })
        let driver = throughGap(rules, before: closed)
        driver.observe(Dictionary(uniqueKeysWithValues: bundles.map { ($0, 1) }))
        await driver.rig.settleDown()
        #expect(TriggerCoordinator.catchUpLimitPerWake == 3)
        #expect(driver.rig.outcome(rules[3]) == .missed(.macAsleep))
        // The first three entered the settle: the reducer kept one popup, the others say why.
        #expect(driver.rig.handler.calls.count == 1)
        for trigger in rules.prefix(3) {
            #expect(driver.rig.outcome(trigger) != .missed(.macAsleep))
            #expect(driver.rig.outcome(trigger) != nil)
        }
    }

    @Test func theKeptReadingWaitsSixtySecondsForATrustedReading() async {
        let opens = rule(.starts, action: .openAll)
        // Within the wait: compared.
        let inTime = throughGap([opens])
        inTime.rig.clock.advance(TriggerCoordinator.catchUpReadingWait)
        inTime.observe([Self.key: 1])
        await inTime.rig.settleDown()
        #expect(inTime.rig.handler.calls == ["openAll:Work"])
        #expect(TriggerCoordinator.catchUpReadingWait == 60)
        // Past it: dropped, the reading is only a baseline.
        let late = throughGap([opens])
        late.observe([:])
        late.rig.clock.advance(TriggerCoordinator.catchUpReadingWait + 1)
        late.observe([Self.key: 1])
        #expect(late.rig.coordinator.catchUpReadingCount == 0)
        await late.rig.settleDown()
        #expect(late.rig.handler.calls.isEmpty)
        #expect(late.rig.outcome(opens) == nil)
        // A sleep after the wait ran out starts no gap from the stale readings.
        let stale = throughGap([opens])
        stale.rig.clock.advance(TriggerCoordinator.catchUpReadingWait + 1)
        stale.signal(.screens(asleep: true))
        #expect(stale.rig.coordinator.catchUpReadingCount == 0)
    }

    // MARK: - Visibility (D6)

    @Test func runRightAwayShowsTheNoticeAskFirstAsksAndShowThePopupIsItsOwnNotice() async {
        let askFirst = throughGap([rule(.starts, action: .openAll, runMode: .askFirst)])
        askFirst.observe([Self.key: 1])
        await askFirst.rig.settleDown()
        #expect(askFirst.rig.presenter.shown.map(\.runMode) == [.askFirst])
        #expect(askFirst.rig.handler.calls == ["openAll:Work"])

        let notNow = throughGap([rule(.starts, action: .openAll)])
        notNow.rig.presenter.answers = [.notNow]
        notNow.observe([Self.key: 1])
        await notNow.rig.settleDown()
        #expect(notNow.rig.presenter.shown.map(\.runMode) == [.notice])
        #expect(notNow.rig.handler.calls.isEmpty)

        let popup = throughGap([rule(.starts, action: .showPopup)])
        popup.observe([Self.key: 1])
        await popup.rig.settleDown()
        #expect(popup.rig.presenter.shown.isEmpty)
        #expect(popup.rig.handler.calls == ["popup:Work"])
    }

    @Test func anObservedEdgeWithRunRightAwayStillRunsWithoutANotice() async {
        let opens = rule(.starts, action: .openAll)
        let driver = CatchUpDriver(TriggerRig([opens]))
        #expect(driver.begin())
        driver.observe([Self.key: 0])
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Work"])
        #expect(driver.rig.presenter.shown.isEmpty)
    }

    // MARK: - Identity (D8) and lock triggers (D9)

    @Test func anUnverifiedRuleNeverCatchesUp() async {
        var popup = rule(.starts, action: .showPopup)
        popup.applicationIdentity = .unverified
        #expect(popup.canRun)
        let driver = throughGap([popup])
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
    }

    @Test func aReadingIsTrustedOnlyOnceTheCodeIsVerified() async {
        let opens = rule(.starts, action: .openAll)
        let driver = CatchUpDriver(TriggerRig([opens]))
        driver.rig.verifier.verdict = .pending
        #expect(driver.begin())
        driver.observe([Self.key: 0])
        // Still being checked when the Mac sleeps: nothing is kept.
        driver.signal(.screens(asleep: true))
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        // Read while pending, verified before the sleep: kept.
        let verifiedLater = CatchUpDriver(TriggerRig([opens]))
        verifiedLater.rig.verifier.verdict = .pending
        #expect(verifiedLater.begin())
        verifiedLater.observe([Self.key: 0])
        verifiedLater.rig.verifier.verdict = .verified
        verifiedLater.signal(.screens(asleep: true))
        #expect(verifiedLater.rig.coordinator.catchUpReadingCount == 1)
    }

    @Test func afterTheGapAPendingCheckMakesTheCatchUpWaitAndAFailedOneSkipsIt() async {
        let opens = rule(.starts, action: .openAll)
        // Being checked, then verified: it runs.
        let confirmed = throughGap([opens])
        confirmed.rig.verifier.verdict = .pending
        confirmed.observe([Self.key: 1])
        let settleSeconds = Int(TriggerCoordinator.settleInterval.components.seconds)
        await settle { confirmed.rig.sleeper.sleepingCount > 0 }
        confirmed.rig.sleeper.wake(upTo: settleSeconds)
        await settle { confirmed.rig.sleeper.sleepingCount > 0 }
        confirmed.rig.verifier.verdict = .verified
        await confirmed.rig.settleDown()
        #expect(confirmed.rig.handler.calls == ["openAll:Work"])
        // Being checked, then the check fails: skipped and recorded, nothing ran.
        let failed = throughGap([opens])
        failed.rig.verifier.verdict = .pending
        failed.observe([Self.key: 1])
        await settle { failed.rig.sleeper.sleepingCount > 0 }
        failed.rig.sleeper.wake(upTo: settleSeconds)
        await settle { failed.rig.sleeper.sleepingCount > 0 }
        failed.rig.verifier.verdict = .unavailable
        await failed.rig.settleDown()
        #expect(failed.rig.handler.calls.isEmpty)
        #expect(failed.rig.outcome(opens) == .skipped(.applicationNotConfirmed))
    }

    @Test func lockAndUnlockTriggersNeverCatchUp() async {
        var lock = GroupTrigger.on(.screenLocks, group: work, action: .finish)
        lock.catchUp = true
        var unlock = GroupTrigger.on(.screenUnlocks, group: design, action: .openAll)
        unlock.catchUp = true
        #expect(!lock.catchesUp && !unlock.catchesUp && !lock.canCatchUp)
        let rig = TriggerRig([lock, unlock])
        rig.handler.userStarted(work.id)
        await rig.send(.screenLock(locked: false))
        await rig.send(.screens(asleep: true), .screenLock(locked: nil))
        rig.clock.advance(120)
        // Locked during the sleep: after the wake the lock reading is a baseline only.
        await rig.send(.screens(asleep: false), .screenLock(locked: true))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.catchUpReadingCount == 0)
    }

    // MARK: - Gates and invalidation

    @Test func aRuleChangedOrTurnedOffDuringTheGapReadsFromABaseline() async {
        let opens = rule(.starts, action: .openAll)
        let changed = throughGap([opens])
        let previous = changed.rig.rules
        changed.rig.rules[0].oncePerDay = true
        changed.rig.coordinator.rulesChanged(previous: previous)
        #expect(changed.rig.coordinator.catchUpReadingCount == 0)
        changed.begin()
        changed.observe([Self.key: 1])
        await changed.rig.settleDown()
        #expect(changed.rig.handler.calls.isEmpty)

        // Changed without being told (the comparison checks the rule too).
        let silent = throughGap([opens])
        silent.rig.rules[0].catchUp = false
        silent.observe([Self.key: 1])
        await silent.rig.settleDown()
        #expect(silent.rig.handler.calls.isEmpty)

        // Its group archived during the gap.
        let archived = throughGap([opens])
        archived.rig.active = [design.id]
        archived.begin()
        archived.observe([Self.key: 1])
        await archived.rig.settleDown()
        #expect(archived.rig.handler.calls.isEmpty)
    }

    @Test func thePolicyOptionChangingDropsTheKeptReadings() async {
        let opens = rule(.starts, action: .openAll)
        let driver = throughGap([opens])
        driver.rig.coordinator.cancelApplicationPresenceForPolicyChange()
        #expect(driver.rig.coordinator.catchUpReadingCount == 0)
        driver.begin()
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
    }

    @Test func pausedDuringTheGapIsSkippedAndNotRunAfterThePause() async {
        let opens = rule(.starts, action: .openAll)
        let driver = throughGap([opens])
        driver.rig.coordinator.pause(.oneHour)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
        #expect(driver.rig.outcome(opens) == .skipped(.paused))
        driver.rig.coordinator.resume()
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
    }

    @Test func theBudgetAndTheCooldownApply() async {
        let opens = rule(.starts, action: .openAll)
        let recent = TriggerTime.date(2026, 10, 28, 7, 30)
        let budget = throughGap([opens], state: TriggerState(recentRuns: Array(repeating: recent, count: TriggerBudget.maximumPerHour)))
        budget.observe([Self.key: 1])
        await budget.rig.settleDown()
        #expect(budget.rig.handler.calls.isEmpty)
        #expect(budget.rig.outcome(opens) == .skipped(.budget))

        // It ran right before a short sleep: the cooldown holds.
        let justRan = TriggerTime.date(2026, 10, 28, 7, 59, 40)
        let cooldown = throughGap([opens], gap: 10, state: TriggerState(entries: [opens.id: .init(lastRunAt: justRan)]))
        cooldown.observe([Self.key: 1])
        await cooldown.rig.settleDown()
        #expect(cooldown.rig.handler.calls.isEmpty)
        #expect(cooldown.rig.outcome(opens) == .skipped(.cooldown))
    }

    @Test func anAutomaticActionAfterTheWakeVoidsTheComparison() async {
        let opens = rule(.starts, action: .openAll)
        let wake = GroupTrigger.on(.screensWake, group: design, action: .openAll, runMode: .immediately)
        let driver = throughGap([opens, wake])
        // The wake trigger's Open All runs before the first reading after the wake.
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Design"])
        driver.rig.clock.advance(20)
        driver.observe([Self.key: 1])
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls == ["openAll:Design"])
        #expect(driver.rig.outcome(opens) == .skipped(.rightAfterAutomaticAction))
    }

    @Test func aDelayedCatchUpIsCancelledByTheNextSleep() async {
        var opens = rule(.starts, action: .openAll, runMode: .notice)
        opens.delaySeconds = 30
        let driver = throughGap([opens])
        driver.observe([Self.key: 1])
        let settleSeconds = Int(TriggerCoordinator.settleInterval.components.seconds)
        var tries = 0
        while driver.rig.coordinator.delayedUntil.isEmpty, tries < 1_000 {
            driver.rig.sleeper.wake(upTo: settleSeconds)
            await Task.yield()
            tries += 1
        }
        #expect(driver.rig.coordinator.delayedUntil[opens.id] != nil)
        driver.signal(.screens(asleep: true))
        await driver.rig.settleDown()
        #expect(driver.rig.handler.calls.isEmpty)
        #expect(driver.rig.outcome(opens) == .skipped(.cancelledBeforeRun))
    }

    // MARK: - Saving and reading (D1)

    private func encoded(_ trigger: GroupTrigger) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(trigger), as: UTF8.self)
    }

    private func decode(_ json: String) throws -> GroupTrigger {
        try JSONDecoder().decode(GroupTrigger.self, from: Data(json.utf8))
    }

    @Test func theOptionIsWrittenOnlyWhenOnAndReadLeniently() throws {
        let off = rule(.starts, catchUp: false)
        let offText = try encoded(off)
        #expect(!offText.contains("catchUp"))
        #expect(try decode(offText) == off)

        let on = rule(.starts)
        let onText = try encoded(on)
        #expect(onText.contains(#""catchUp":true"#))
        let read = try decode(onText)
        #expect(read == on && read.catchUp && read.catchesUp)

        // A file without it (every file before it existed) or with something else: off.
        let group = "0C0D1E00-0000-4000-8000-0000000000A0"
        let id = "7A1660E0-0000-4000-8000-0000000000A1"
        let base = #"{"id":"\#(id)","groupID":"\#(group)","enabled":true,"event":{"kind":"login"},"action":"start","runMode":"notice""#
        #expect(try decode(base + "}").catchUp == false)
        #expect(try decode(base + #","catchUp":"yes"}"#).catchUp == false)
        #expect(try decode(base + #","catchUp":1}"#).catchUp == false)
        // Kept as read on another event (written back), but it doesn't act there.
        let login = try decode(base + #","catchUp":true}"#)
        #expect(login.catchUp && !login.catchesUp && login.canRun)
        #expect(try encoded(login).contains(#""catchUp":true"#))
    }

    @Test func theEditorDraftKeepsTheOptionForApplicationTriggersOnly() throws {
        let calendar = TriggerTime.calendar()
        let on = rule(.starts)
        var draft = try #require(TriggerDraft(editing: on, calendar: calendar))
        #expect(draft.catchUp && draft.canCatchUp)
        #expect(draft.trigger(groupID: work.id, replacing: on).catchUp)
        draft.setKind(.login)
        #expect(!draft.canCatchUp)
        #expect(!draft.trigger(groupID: work.id, replacing: on).catchUp)
        #expect(TriggerDraft(calendar: calendar).catchUp == false)
    }
}
