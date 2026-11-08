import Foundation
import Testing
@testable import DockGroupsCore

/// Per-trigger delays (`GroupTrigger.delaySeconds`): how they're saved and read, what the editor
/// takes, and how the coordinator waits — with a fake sleeper and clock, so nothing really waits.
@Suite("Triggers: delays")
@MainActor
struct TriggerDelayTests {
    private let work = TriggerRig.work
    private let design = TriggerRig.design
    private static let group = UUID(uuidString: "0C0D1E00-0000-4000-8000-0000000000A0")!
    private static let id = UUID(uuidString: "7A1660E0-0000-4000-8000-0000000000A1")!

    // MARK: - Helpers

    private func delayed(_ trigger: GroupTrigger, _ seconds: Int) -> GroupTrigger {
        var trigger = trigger
        trigger.delaySeconds = seconds
        return trigger
    }

    /// Lets the settle (2 s) end — not the delays — and waits until the firing waits for its delay,
    /// shows its notice, or nothing is left.
    private func accept(_ rig: TriggerRig) async {
        let settleSeconds = Int(TriggerCoordinator.settleInterval.components.seconds)
        var tries = 0
        while rig.coordinator.delayedUntil.isEmpty, !rig.presenter.isShowing, !rig.coordinator.isIdle, tries < 1_000 {
            rig.sleeper.wake(upTo: settleSeconds)
            await Task.yield()
            tries += 1
        }
    }

    /// Moves the clock on by `seconds` and ends the sleeps that long, then waits until nothing is left.
    private func pass(_ seconds: Int, _ rig: TriggerRig) async {
        rig.clock.advance(TimeInterval(seconds))
        var tries = 0
        while !rig.coordinator.isIdle, tries < 1_000 {
            rig.sleeper.wake(upTo: seconds)
            await Task.yield()
            tries += 1
        }
    }

    private func encoded(_ trigger: GroupTrigger) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(trigger), as: UTF8.self)
    }

    private func decode(_ json: String) throws -> GroupTrigger {
        try JSONDecoder().decode(GroupTrigger.self, from: Data(json.utf8))
    }

    private func savedJSON(delay: String) -> String {
        #"{"id":"7A1660E0-0000-4000-8000-0000000000A1","groupID":"0C0D1E00-0000-4000-8000-0000000000A0","enabled":true,"event":{"kind":"login"},"action":"start","runMode":"notice","delaySeconds":"# + delay + "}"
    }

    // MARK: - Saving and reading

    @Test func noDelayIsntWrittenAndAMissingOneIsNone() throws {
        let trigger = GroupTrigger(id: Self.id, groupID: Self.group, event: .login, action: .start)
        #expect(trigger.delaySeconds == 0)
        let text = try encoded(trigger)
        #expect(!text.contains("delaySeconds"))
        let read = try decode(text)
        #expect(read == trigger)
        #expect(read.delaySeconds == 0 && read.canRun)
    }

    @Test func aDelayIsWrittenAndReadBack() throws {
        let trigger = GroupTrigger(id: Self.id, groupID: Self.group, event: .login, action: .start, delaySeconds: 90)
        let text = try encoded(trigger)
        #expect(text.contains(#""delaySeconds":90"#))
        let read = try decode(text)
        #expect(read == trigger)
        #expect(read.delaySeconds == 90 && read.canRun)
        let longest = GroupTrigger(groupID: Self.group, event: .login, action: .start, delaySeconds: 3600)
        #expect(try decode(encoded(longest)).canRun)
    }

    /// Decision: a delay this version can't wait is never clamped or read as 0 (that would run the
    /// action sooner than the file says). The trigger is kept, written back as it was, and can't
    /// run until the editor gives it a delay it can wait.
    @Test(arguments: ["-1", "3601", "86400", "2.5", "\"30\"", "null", "true", "[]"])
    func aDelayOutOfRangeOrUnreadableIsKeptAndDoesntRun(raw: String) throws {
        let read = try decode(savedJSON(delay: raw))
        #expect(read.isEnabled)
        #expect(!read.hasValidDelay)
        #expect(!read.isRunnable && !read.canRun)
        #expect(read.problem != nil)
        let rewritten = try JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: Data(savedJSON(delay: raw).utf8)) as? [String: Any]
        #expect((rewritten?["delaySeconds"] as? NSObject) == (original?["delaySeconds"] as? NSObject))
        #expect(rewritten?.keys.contains("delaySeconds") == true)
        // Setting a delay again makes it runnable.
        var fixed = read
        fixed.delaySeconds = 5
        #expect(fixed.canRun)
        #expect(try encoded(fixed).contains(#""delaySeconds":5"#))
    }

    @Test func aWholeNumberWrittenAsADecimalIsThatNumber() throws {
        let read = try decode(savedJSON(delay: "30.0"))
        #expect(read.delaySeconds == 30 && read.canRun)
    }

    @Test func aDelayedTriggerSurvivesTheStore() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "triggers.json")
        let triggers = [
            GroupTrigger(groupID: Self.group, event: .login, action: .start, delaySeconds: 45),
            GroupTrigger(groupID: Self.group, event: .appOpens, action: .openAll),
        ]
        try JSONFileTriggerPersistence(fileURL: url).saveTriggers(triggers)
        let reread = try JSONFileTriggerPersistence(fileURL: url).loadTriggers()
        #expect(reread == triggers)
        #expect(reread.map(\.delaySeconds) == [45, 0])
    }

    // MARK: - The editor

    @Test func theEditorTakesADelayKeepsItAndRejectsOthers() throws {
        let calendar = TriggerTime.calendar()
        var draft = TriggerDraft(calendar: calendar)
        draft.setKind(.login)
        #expect(draft.delayText == "0" && draft.delaySeconds == 0 && draft.isValid)
        for text in ["-1", "3601", "1e3", "30s", "", " ", "٣٠", "+5", "99999"] {
            draft.delayText = text
            #expect(draft.delaySeconds == nil, "\(text)")
            #expect(!draft.isValid && !draft.canBeSaved(replacing: nil), "\(text)")
        }
        for (text, seconds) in [("0", 0), ("1", 1), (" 120 ", 120), ("3600", 3600), ("0030", 30)] {
            draft.delayText = text
            #expect(draft.delaySeconds == seconds, "\(text)")
            #expect(draft.isValid, "\(text)")
        }
        draft.delayText = "120"
        let trigger = draft.trigger(groupID: Self.group)
        #expect(trigger.delaySeconds == 120 && trigger.canRun)

        // Saved, read again and opened in the editor: the delay is as it was saved.
        let store = TriggerStore(persistence: MemoryTriggerPersistence(), saveDelay: .zero)
        #expect(store.add(trigger).message == nil)
        store.flushPendingSave()
        let saved = try #require(store.trigger(withID: trigger.id))
        let reopened = try #require(TriggerDraft(editing: saved, calendar: calendar))
        #expect(reopened.delayText == "120" && reopened.delaySeconds == 120)
        // Changing something else keeps it; clearing it to 0 removes it.
        var edited = reopened
        edited.oncePerDay = true
        #expect(edited.trigger(groupID: Self.group, replacing: saved).delaySeconds == 120)
        edited.delayText = "0"
        #expect(!(try encoded(edited.trigger(groupID: Self.group, replacing: saved))).contains("delaySeconds"))
    }

    @Test func theEditorDoesntTakeAnUnreadableDelayAsNone() throws {
        let read = try decode(savedJSON(delay: "\"soon\""))
        let draft = try #require(TriggerDraft(editing: read, calendar: TriggerTime.calendar()))
        #expect(draft.delayText.isEmpty && draft.delaySeconds == nil && !draft.isValid)
        let outOfRange = try #require(TriggerDraft(editing: try decode(savedJSON(delay: "5000")), calendar: TriggerTime.calendar()))
        #expect(outOfRange.delayText == "5000" && !outOfRange.isValid)
        // Never saved by the editor, but a trigger made from it anyway can't run.
        #expect(!draft.trigger(groupID: Self.group).canRun)
    }

    @Test func theRowSaysTheDelay() {
        #expect(TriggerDescriptions.delay(30) == "After 30 s")
        #expect(TriggerSkipReason.cancelledBeforeRun.explanation == "it was cancelled before it ran")
        var entry = TriggerState.Entry()
        entry.lastOutcome = .skipped(.cancelledBeforeRun)
        entry.lastOutcomeAt = TriggerTime.date(2026, 10, 28, 9, 0)
        let line = TriggerDescriptions.lastRun(entry, groupName: "Work", now: TriggerTime.date(2026, 10, 28, 9, 5), calendar: TriggerTime.calendar(), locale: Locale(identifier: "en_US_POSIX"))
        #expect(line.hasPrefix("Skipped today at"))
        #expect(line.hasSuffix(": it was cancelled before it ran."))
    }

    @Test func theNewSkipReasonRoundTripsInTheStateFile() throws {
        let id = UUID()
        var state = TriggerState()
        state.record(.skipped(.cancelledBeforeRun), for: id, at: TriggerTime.date(2026, 10, 28, 9, 0))
        let read = try JSONDecoder().decode(TriggerState.self, from: JSONEncoder().encode(state))
        #expect(read.entry(for: id).lastOutcome == .skipped(.cancelledBeforeRun))
    }

    // MARK: - Waiting

    @Test func withoutADelayNothingWaits() async {
        let trigger = GroupTrigger.on(.appOpens, group: work, action: .openAll)
        let rig = TriggerRig([trigger])
        await rig.send(.launched(.normal))
        #expect(rig.handler.calls == ["openAll:Work"])
        #expect(rig.sleeper.requested == [2])
        #expect(rig.coordinator.delayedUntil.isEmpty)
    }

    @Test func theActionRunsWhenTheDelayIsOver() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        var changes = 0
        rig.coordinator.onDelayedFiringsChange = { changes += 1 }
        let accepted = rig.clock.now
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.delayedUntil[trigger.id] == accepted.addingTimeInterval(30))
        #expect(!rig.coordinator.isIdle)
        #expect(changes == 1)
        await pass(30, rig)
        #expect(rig.sleeper.requested == [2, 30])
        #expect(rig.handler.calls == ["openAll:Work"])
        #expect(rig.outcome(trigger) == .ran(.openAll))
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(changes == 2)
    }

    @Test func aWaitingTriggerDoesntHoldOthersUp() async {
        let slow = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 600)
        let quick = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: design, action: .showPopup)
        let rig = TriggerRig([slow, quick])
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[slow.id] != nil)
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await settle { rig.sleeper.sleepingCount > 1 }
        rig.sleeper.wake(upTo: 2)
        await settle { rig.handler.calls.count == 1 }
        #expect(rig.handler.calls == ["popup:Design"])
        #expect(rig.coordinator.delayedUntil[slow.id] != nil)
        await pass(600, rig)
        #expect(rig.handler.calls == ["popup:Design", "openAll:Work"])
    }

    @Test func theNoticeComesFirstThenTheDelay() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .start, runMode: .notice), 20)
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        #expect(rig.presenter.isShowing)
        #expect(rig.coordinator.delayedUntil.isEmpty)
        rig.presenter.release(.run)
        await settle { !rig.coordinator.delayedUntil.isEmpty }
        #expect(rig.handler.calls.isEmpty)
        await pass(20, rig)
        #expect(rig.handler.calls == ["start:Work:automation"])
        #expect(rig.presenter.shown.count == 1)
        #expect(rig.outcome(trigger) == .ran(.start))
    }

    @Test func notNowMeansNoDelayAndNothingRuns() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .start, runMode: .askFirst), 20)
        let rig = TriggerRig([trigger])
        rig.presenter.answers = [.notNow]
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        await settle { rig.coordinator.isIdle }
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.notNow))
    }

    @Test func aChangedRuleCancelsTheWait() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        let previous = rig.rules
        rig.rules[0].oncePerDay = true
        rig.coordinator.rulesChanged(previous: previous)
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aChangeOnlyTheDueCheckSeesStillCancels() async {
        // The rule changes without `rulesChanged` being called: the check when the delay is over
        // sees it.
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        rig.rules[0].delaySeconds = 31
        await pass(31, rig)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
    }

    @Test func aTurnedOffOrDeletedRuleCancelsTheWait() async {
        let off = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let deleted = delayed(GroupTrigger.on(.appOpens, group: design, action: .showPopup), 30)
        let rig = TriggerRig([off, deleted])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        await settle { rig.coordinator.delayedUntil.count == 2 }
        let previous = rig.rules
        rig.rules = [delayed(off, 30)]
        rig.rules[0].isEnabled = false
        rig.coordinator.rulesChanged(previous: previous)
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(off) == .skipped(.cancelledBeforeRun))
        // A deleted rule leaves no entry behind.
        #expect(rig.coordinator.state.entries[deleted.id] == nil)
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func anArchivedGroupCancelsTheWait() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        rig.active = [design.id]
        rig.coordinator.revalidateDelayedFirings()
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.groupMissing))
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func pausingCancelsTheWait() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        rig.coordinator.pause(.oneHour)
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.paused))
        // Resuming doesn't bring it back.
        rig.coordinator.resume()
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func theBudgetUsedUpMeanwhileCancelsIt() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let other = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: design, action: .showPopup)
        // Eleven runs in the last hour: one more is the budget's last.
        let now = TriggerTime.date(2026, 10, 28, 8, 0)
        let runs = (1..<TriggerBudget.maximumPerHour).map { now.addingTimeInterval(TimeInterval(-60 * $0)) }
        let rig = TriggerRig([trigger, other], state: TriggerState(recentRuns: runs))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        // The other trigger uses the budget up while this one waits.
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await settle { rig.sleeper.sleepingCount > 1 }
        rig.sleeper.wake(upTo: 2)
        await settle { rig.handler.calls.count == 1 }
        await pass(30, rig)
        #expect(rig.handler.calls == ["popup:Design"])
        #expect(rig.outcome(trigger) == .skipped(.budget))
        #expect(rig.coordinator.isPaused)
    }

    @Test func theScreensSleepingOrTheSessionChangingCancelsIt() async {
        for signal in [TriggerSignal.screens(asleep: true), .session(active: false)] {
            let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
            let rig = TriggerRig([trigger])
            rig.coordinator.receive(.launched(.normal))
            await accept(rig)
            rig.coordinator.receive(signal)
            #expect(rig.coordinator.delayedUntil.isEmpty, "\(signal)")
            #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun), "\(signal)")
            // Back again before the delay would have ended: it stays cancelled.
            rig.coordinator.receive(.screens(asleep: false))
            rig.coordinator.receive(.session(active: true))
            await pass(30, rig)
            #expect(rig.handler.calls.isEmpty, "\(signal)")
        }
    }

    @Test func theScreenLockChangingCancelsAnUnlockTrigger() async {
        let trigger = delayed(GroupTrigger.on(.screenUnlocks, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        rig.coordinator.receive(.screenLock(locked: true))
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aLockTriggersFinishWaitsThroughTheDisplaysSleeping() async {
        let trigger = delayed(GroupTrigger.on(.screenLocks, group: work, action: .finish), 30)
        let rig = TriggerRig([trigger])
        rig.handler.userStarted(work.id)
        rig.coordinator.receive(.screenLock(locked: false))
        rig.coordinator.receive(.screenLock(locked: true))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        rig.coordinator.receive(.screens(asleep: true))
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        await pass(30, rig)
        #expect(rig.handler.calls == ["finish:Work:automation:true"])
    }

    @Test func aNewerFiringOfTheSameTriggerTakesItsPlace() async {
        let ethernet = TriggerEvent.condition(.ethernet, edge: .starts)
        let trigger = delayed(GroupTrigger.on(ethernet, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await accept(rig)
        let first = rig.coordinator.delayedUntil[trigger.id]
        #expect(first != nil)
        rig.clock.advance(10)
        // Unplugged and plugged in again: the newer connection takes the first one's place.
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        #expect(rig.coordinator.delayedUntil[trigger.id] == first)
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await accept(rig)
        let second = rig.coordinator.delayedUntil[trigger.id]
        #expect(second == first?.addingTimeInterval(10))
        await pass(30, rig)
        #expect(rig.handler.calls == ["openAll:Work"])
    }

    @Test func theLockChangingAgainCancelsAndTheNewUnlockWaitsAgain() async {
        let trigger = delayed(GroupTrigger.on(.screenUnlocks, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        await accept(rig)
        rig.clock.advance(10)
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        await pass(30, rig)
        #expect(rig.handler.calls == ["openAll:Work"])
    }

    @Test func aNewObservationGenerationCancelsAnApplicationTrigger() async {
        let trigger = delayed(GroupTrigger.on(.applicationPresence(bundleIdentifier: "com.example.app", edge: .starts), group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        // The tracker restarts (a new generation): what the old one saw no longer counts.
        #expect(rig.coordinator.beginApplicationObservations(generation: 99))
        #expect(rig.coordinator.delayedUntil.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func anUncertainObservationCancelsAnApplicationTrigger() async {
        let trigger = delayed(GroupTrigger.on(.applicationPresence(bundleIdentifier: "com.example.app", edge: .starts), group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await accept(rig)
        rig.coordinator.observeApplications(generation: rig.presenceGeneration, sequence: 3, counts: [:])
        #expect(rig.coordinator.delayedUntil.isEmpty)
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func anApplicationTriggerWhoseCodeIsNoLongerConfirmedIsCancelled() async {
        let trigger = delayed(GroupTrigger.on(.applicationPresence(bundleIdentifier: "com.example.app", edge: .starts), group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        rig.verifier.verdict = .unavailable
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
    }

    @Test func anApplicationTriggerNeedingReapprovalIsCancelled() async {
        let trigger = delayed(GroupTrigger.on(.applicationPresence(bundleIdentifier: "com.example.app", edge: .starts), group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await accept(rig)
        let previous = rig.rules
        rig.rules[0].applicationIdentity = rig.rules[0].applicationIdentity?.requiringReapproval()
        #expect(rig.rules[0] != previous[0])
        rig.coordinator.rulesChanged(previous: previous)
        #expect(rig.coordinator.delayedUntil.isEmpty)
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func theEchoWindowAtTheEndCancelsAChange() async {
        let ethernet = TriggerEvent.condition(.ethernet, edge: .starts)
        let trigger = delayed(GroupTrigger.on(ethernet, group: work, action: .openAll), 30)
        let quick = GroupTrigger.on(.appOpens, group: design, action: .showPopup)
        let rig = TriggerRig([trigger, quick])
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        // Another trigger runs 20 s later; the delay ends 10 s after it, inside its echo window.
        rig.clock.advance(20)
        rig.coordinator.receive(.launched(.normal))
        await settle { rig.sleeper.sleepingCount > 1 }
        rig.sleeper.wake(upTo: 2)
        await settle { rig.handler.calls.count == 1 }
        #expect(rig.handler.calls == ["popup:Design"])
        rig.clock.advance(10)
        rig.sleeper.wake(upTo: 30)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls == ["popup:Design"])
        #expect(rig.outcome(trigger) == .skipped(.rightAfterAutomaticAction))
    }

    @Test func aFinishWhenItEndsWaitsTooAndAStartsEndCancelsItsStart() async {
        let display = TriggerEvent.condition(.display(.anyExternal), edge: .starts)
        let trigger = delayed(GroupTrigger.on(display, group: work, action: .start, finishesWhenEventEnds: true), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.displays([]))
        rig.coordinator.receive(.displays([.monitor("LG")]))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        // Disconnected before the Start ran: the Start is cancelled; the Finish has nothing to finish.
        rig.clock.advance(5)
        rig.coordinator.receive(.displays([]))
        #expect(rig.outcome(trigger) == .skipped(.cancelledBeforeRun))
        await accept(rig)
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aGroupGoneWhenTheDelayEndsRunsNothing() async {
        let trigger = delayed(GroupTrigger.on(.appOpens, group: work, action: .openAll), 30)
        let rig = TriggerRig([trigger])
        rig.coordinator.receive(.launched(.normal))
        await accept(rig)
        // Gone without anyone telling the coordinator: the check when the delay ends sees it.
        rig.active = [design.id]
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.groupMissing))
    }

    @Test func aFinishWhoseGroupIsntCurrentAnyMoreDoesntRun() async {
        let trigger = delayed(GroupTrigger.on(.condition(.ethernet, edge: .ends), group: work, action: .finish), 30)
        let rig = TriggerRig([trigger])
        rig.handler.userStarted(work.id)
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: true)))
        rig.coordinator.receive(.network(NetworkReading(usesEthernet: false)))
        await accept(rig)
        #expect(rig.coordinator.delayedUntil[trigger.id] != nil)
        rig.handler.userStarted(design.id)
        await pass(30, rig)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.notCurrentGroup))
    }
}
