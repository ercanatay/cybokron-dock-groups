import Foundation
import Testing
@testable import DockGroupsCore

/// The screen lock and unlock triggers (TS-11, `docs/design/app-presence-session-lock-trigger.md`):
/// only a change between two known lock readings fires; unknown readings and the first known one
/// after them are a baseline; a lock or unlock firing runs only while the lock is still what it was.
@Suite("Triggers: the screen locking and unlocking")
struct TriggerScreenLockEvaluatorTests {
    private static let work = DockGroup.of("Work", ["com.apple.mail"])
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private let calendar = TriggerTime.calendar()
    private let active: Set<DockGroup.ID> = [work.id, design.id]
    private let lock = GroupTrigger.on(.screenLocks, group: work, action: .finish)
    private let unlock = GroupTrigger.on(.screenUnlocks, group: design, action: .openAll)

    private func at(_ minute: Int) -> Date { TriggerTime.date(2026, 10, 28, 9, minute) }

    /// Sends `signals` in turn from a fresh baseline; the firings of each.
    private func run(_ signals: [TriggerSignal], rules: [GroupTrigger]? = nil, active: Set<DockGroup.ID>? = nil) -> (firings: [[TriggerFiring]], environment: TriggerEnvironment) {
        let rules = rules ?? [lock, unlock]
        var state = TriggerEvaluator.baseline(rules: rules, state: TriggerState(), now: at(0), calendar: calendar)
        var environment = TriggerEnvironment()
        var firings: [[TriggerFiring]] = []
        for (minute, signal) in signals.enumerated() {
            // A minute apart: the cooldown doesn't get in the way.
            let result = TriggerEvaluator.evaluate(signal, rules: rules, state: state, environment: environment, activeGroups: active ?? self.active, now: at(minute * 2), calendar: calendar)
            state = result.state
            environment = result.environment
            firings.append(result.firings)
        }
        return (firings, environment)
    }

    @Test func theEventsAllowWhatTheScreensEventsAllow() {
        #expect(TriggerEvent.screenLocks.allowedActions == [.finish])
        #expect(TriggerEvent.screenUnlocks.allowedActions == [.showPopup, .openAll, .start])
        #expect(TriggerEvent.screenLocks.isValid && TriggerEvent.screenUnlocks.isValid)
        #expect(!TriggerEvent.screenLocks.isEdge && !TriggerEvent.screenUnlocks.isEdge)
        #expect(TriggerEvent.screenLocks.kindName == "screenLocks")
        #expect(TriggerEvent.screenUnlocks.kindName == "screenUnlocks")
        #expect(!GroupTrigger(groupID: Self.work.id, event: .screenLocks, action: .start).isRunnable)
    }

    @Test func onlyAChangeBetweenKnownReadingsFires() {
        let result = run([
            .screenLock(locked: false),  // baseline
            .screenLock(locked: true),   // locks
            .screenLock(locked: true),   // told twice: nothing
            .screenLock(locked: false),  // unlocks
            .screenLock(locked: false),  // told twice: nothing
        ])
        #expect(result.firings.map { $0.map(\.triggerID) } == [[], [lock.id], [], [unlock.id], []])
        #expect(result.firings[1].first?.action == .finish)
        #expect(result.firings[3].first?.action == .openAll)
        #expect(result.environment.screenLocked == false)
    }

    @Test func theFirstReadingAfterUnknownIsABaseline() {
        // Launch (unknown), then the screen locks: no baseline yet, so nothing.
        #expect(run([.screenLock(locked: true)]).firings == [[]])
        // An unlock told without any reading before: nothing.
        #expect(run([.screenLock(locked: false)]).firings == [[]])
        // Locked, unknown (the Mac going to sleep), unlocked: the gap breaks the change.
        let gap = run([.screenLock(locked: false), .screenLock(locked: true), .screenLock(locked: nil), .screenLock(locked: false)])
        #expect(gap.firings.map(\.count) == [0, 1, 0, 0])
        #expect(gap.environment.screenLocked == false)
    }

    @Test func anInactiveSessionMakesTheLockUnknown() {
        let result = run([.screenLock(locked: true), .session(active: false), .session(active: true), .screenLock(locked: false)])
        // Another user's session: its lock screen isn't this session's unlock.
        #expect(result.firings.allSatisfy { $0.isEmpty })
        #expect(result.environment.screenLocked == false)
        let revisions = run([.screenLock(locked: true), .session(active: false)]).environment
        #expect(revisions.screenLocked == nil)
        #expect(revisions.screenLockRevision == 2)
    }

    @Test func screensSleepingDoesntForgetTheLock() {
        // The displays sleep, then the screen locks (as `pmset displaysleepnow` did on macOS 27.2),
        // then they wake and the user unlocks.
        let result = run([.screenLock(locked: false), .screens(asleep: true), .screenLock(locked: true), .screens(asleep: false), .screenLock(locked: false)])
        #expect(result.firings.map { $0.map(\.triggerID) } == [[], [], [lock.id], [], [unlock.id]])
    }

    @Test func firingsCarryTheLockRevisionTheyCameWith() throws {
        let result = run([.screenLock(locked: false), .screenLock(locked: true), .screenLock(locked: true)])
        let firing = try #require(result.firings[1].first)
        #expect(firing.screenLockRevision == 2)
        // A repeated reading doesn't start a new revision.
        #expect(result.environment.screenLockRevision == 2)
        // Other events' firings carry none.
        let login = GroupTrigger.on(.appOpens, group: Self.work, action: .openAll)
        let opened = run([.launched(.normal)], rules: [login])
        #expect(opened.firings[0].first?.screenLockRevision == nil)
    }

    @Test func offOrArchivedTriggersKeepUpSilently() {
        var off = lock
        off.isEnabled = false
        #expect(run([.screenLock(locked: false), .screenLock(locked: true)], rules: [off]).firings.allSatisfy { $0.isEmpty })
        #expect(run([.screenLock(locked: false), .screenLock(locked: true)], rules: [lock], active: [Self.design.id]).firings.allSatisfy { $0.isEmpty })
    }

    @Test func theCooldownAndThePauseApply() {
        let rules = [unlock]
        var state = TriggerEvaluator.baseline(rules: rules, state: TriggerState(), now: at(0), calendar: calendar)
        state.recordRun(.openAll, for: unlock.id, at: at(0))
        var environment = TriggerEnvironment()
        for signal in [TriggerSignal.screenLock(locked: true)] {
            environment = TriggerEvaluator.evaluate(signal, rules: rules, state: state, environment: environment, activeGroups: active, now: at(0), calendar: calendar).environment
        }
        let soon = TriggerEvaluator.evaluate(.screenLock(locked: false), rules: rules, state: state, environment: environment, activeGroups: active, now: at(0).addingTimeInterval(30), calendar: calendar)
        #expect(soon.firings.isEmpty)
        #expect(soon.state.entry(for: unlock.id).lastOutcome == .skipped(.cooldown))

        var paused = TriggerState()
        paused.pause(until: at(30), reason: .user)
        paused = TriggerEvaluator.baseline(rules: rules, state: paused, now: at(0), calendar: calendar)
        let whilePaused = TriggerEvaluator.evaluate(.screenLock(locked: false), rules: rules, state: paused, environment: environment, activeGroups: active, now: at(5), calendar: calendar)
        #expect(whilePaused.firings.isEmpty)
        #expect(whilePaused.state.entry(for: unlock.id).lastOutcome == .skipped(.paused))
    }

    @Test func otherTriggersIgnoreTheLock() {
        let nine = GroupTrigger.at(9, 0, group: Self.work)
        let plugged = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: Self.work, action: .openAll)
        let wake = GroupTrigger.on(.screensWake, group: Self.design, action: .showPopup)
        let result = run([.screenLock(locked: false), .screenLock(locked: true), .screenLock(locked: false)], rules: [nine, plugged, wake])
        #expect(result.firings.allSatisfy { $0.isEmpty })
    }

    @Test func onlyLockTriggersNeedTheLockSource() {
        #expect(TriggerSourceNeeds.of(rules: [lock], activeGroups: active) == .screenLock)
        #expect(TriggerSourceNeeds.of(rules: [unlock], activeGroups: active) == .screenLock)
        var off = unlock
        off.isEnabled = false
        #expect(TriggerSourceNeeds.of(rules: [off], activeGroups: active).isEmpty)
        #expect(TriggerSourceNeeds.of(rules: [lock], activeGroups: [Self.design.id]).isEmpty)
        #expect(TriggerSourceNeeds.of(rules: [GroupTrigger.on(.screensSleep, group: Self.work, action: .finish)], activeGroups: active).isEmpty)
    }
}

@Suite("Triggers: carrying out lock and unlock firings")
@MainActor
struct TriggerScreenLockCoordinatorTests {
    private let work = TriggerRig.work
    private let design = TriggerRig.design

    @Test func anUnlockRunsItsAction() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .start)
        let rig = TriggerRig([unlock])
        await rig.send(.screenLock(locked: false), .screenLock(locked: true), .screenLock(locked: false))
        #expect(rig.handler.calls == ["start:Work:automation"])
        #expect(rig.outcome(unlock) == .ran(.start))
    }

    @Test func anUnlockWithANoticeShowsIt() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll, runMode: .notice)
        let rig = TriggerRig([unlock])
        // The first reading is the baseline: nothing.
        await rig.send(.screenLock(locked: true))
        #expect(rig.presenter.shown.isEmpty)
        await rig.send(.screenLock(locked: false))
        #expect(rig.presenter.shown.map(\.triggerID) == [unlock.id])
        #expect(rig.handler.calls == ["openAll:Work"])
    }

    /// Nobody can answer a notice on the lock screen: a lock trigger finishes (hides) right away,
    /// even with the displays asleep and no notice panel.
    @Test func aLockFinishesRightAwayWithoutANotice() async {
        let lock = GroupTrigger.on(.screenLocks, group: design, action: .finish, runMode: .notice)
        let rig = TriggerRig([lock], presenter: false)
        rig.handler.userStarted(TriggerRig.design.id)
        await rig.send(.screenLock(locked: false), .screens(asleep: true), .screenLock(locked: true))
        #expect(rig.handler.calls == ["finish:Design:automation:true"])
    }

    @Test func aQuickLockAndUnlockRunsOnlyTheUnlock() async {
        let lock = GroupTrigger.on(.screenLocks, group: design, action: .finish)
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([lock, unlock])
        rig.handler.userStarted(TriggerRig.design.id)
        // Both come within the settle: the lock is over before its finish could run.
        await rig.send(.screenLock(locked: false), .screenLock(locked: true), .screenLock(locked: false))
        #expect(rig.handler.calls == ["openAll:Work"])
        #expect(rig.outcome(lock) == nil)
    }

    @Test func anUnlockFollowedByALockRunsOnlyTheLock() async {
        let lock = GroupTrigger.on(.screenLocks, group: design, action: .finish)
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([lock, unlock])
        rig.handler.userStarted(TriggerRig.design.id)
        await rig.send(.screenLock(locked: true), .screenLock(locked: false), .screenLock(locked: true))
        #expect(rig.handler.calls == ["finish:Design:automation:true"])
        #expect(rig.outcome(unlock) == nil)
    }

    @Test func aQueuedUnlockIsDroppedWhenTheLockChanges() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([unlock], handler: false)
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        // Locked again before the app could carry it out.
        rig.coordinator.receive(.screenLock(locked: true))
        #expect(rig.coordinator.waitingFirings.isEmpty)
        rig.coordinator.handler = rig.handler
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aStaleUnlockIsntRunWhenItsNoticeIsAnswered() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll, runMode: .notice)
        let rig = TriggerRig([unlock])
        rig.presenter.holds = true
        await rig.send(.screenLock(locked: true), .screenLock(locked: false))
        #expect(rig.presenter.isShowing)
        // The screen locks while the notice counts down: the notice goes, nothing runs.
        rig.coordinator.receive(.screenLock(locked: true))
        #expect(rig.presenter.dismissCount == 1)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(unlock) == nil)
    }

    @Test func anUnknownLockRunsNothing() async {
        let lock = GroupTrigger.on(.screenLocks, group: design, action: .finish)
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([lock, unlock])
        rig.handler.userStarted(TriggerRig.design.id)
        // No source (nothing told), a source that can't tell, a gap between two readings.
        await rig.send(.screenLock(locked: true))
        await rig.send(.screenLock(locked: nil), .screenLock(locked: false))
        await rig.send(.screenLock(locked: nil), .screenLock(locked: true), .screenLock(locked: nil))
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.environment.screenLocked == nil)
    }

    @Test func anotherSessionDropsAWaitingUnlock() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([unlock])
        // Unlocked while the displays are reported asleep: it waits for them to wake.
        rig.coordinator.receive(.screens(asleep: true))
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.sleeper.wakeAll()
        await settle { !rig.coordinator.waitingFirings.isEmpty }
        #expect(rig.coordinator.waitingFirings.map(\.triggerID) == [unlock.id])
        // Fast user switching away, then back and awake: the waiting unlock doesn't run.
        await rig.send(.session(active: false), .session(active: true), .screens(asleep: false))
        #expect(rig.coordinator.waitingFirings.isEmpty)
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func turningTheTriggerOffDropsItsFiring() async {
        let unlock = GroupTrigger.on(.screenUnlocks, group: work, action: .openAll)
        let rig = TriggerRig([unlock], handler: false)
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
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

    @Test func lockChangesLeaveOtherFiringsAlone() async {
        let opens = GroupTrigger.on(.appOpens, group: work, action: .openAll)
        let rig = TriggerRig([opens])
        rig.coordinator.receive(.launched(.normal))
        rig.coordinator.receive(.screenLock(locked: true))
        rig.coordinator.receive(.screenLock(locked: false))
        rig.coordinator.receive(.screenLock(locked: nil))
        await rig.settleDown()
        #expect(rig.handler.calls == ["openAll:Work"])
    }

    @Test func applicationTriggersStillRunAcrossLockChanges() async {
        let presence = GroupTrigger.on(.applicationPresence(bundleIdentifier: "com.example.Fixture", edge: .starts), group: work, action: .openAll)
        let rig = TriggerRig([presence])
        rig.deliverApplicationEdge(of: presence)
        rig.coordinator.receive(.screenLock(locked: false))
        rig.coordinator.receive(.screenLock(locked: true))
        await rig.settleDown()
        #expect(rig.handler.calls == ["openAll:Work"])
    }
}

@Suite("Triggers: saving lock and unlock triggers")
@MainActor
struct TriggerScreenLockCodingTests {
    private static let group = UUID(uuidString: "0C0D1E00-0000-4000-8000-000000000090")!
    private static let work = DockGroup.of("Work", ["com.apple.mail"])

    private func json(_ event: TriggerEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(event.json), as: UTF8.self)
    }

    private func event(_ text: String) throws -> TriggerEvent {
        TriggerEvent(json: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
    }

    @Test func theEventsAreSavedAsTheirKind() throws {
        #expect(try json(.screenLocks) == #"{"kind":"screenLocks"}"#)
        #expect(try json(.screenUnlocks) == #"{"kind":"screenUnlocks"}"#)
        #expect(try event(#"{"kind":"screenLocks"}"#) == .screenLocks)
        #expect(try event(#"{"kind":"screenUnlocks"}"#) == .screenUnlocks)
    }

    @Test func triggersRoundTrip() throws {
        for trigger in [
            GroupTrigger(groupID: Self.group, event: .screenLocks, action: .finish),
            GroupTrigger(groupID: Self.group, event: .screenUnlocks, action: .start, runMode: .askFirst, oncePerDay: true),
            GroupTrigger(groupID: Self.group, event: .screenUnlocks, action: .showPopup),
        ] {
            let restored = try JSONDecoder().decode(GroupTrigger.self, from: JSONEncoder().encode(trigger))
            #expect(restored == trigger)
            #expect(restored.canRun)
        }
    }

    /// A newer version's field inside the event, or a lock trigger with an action it doesn't allow,
    /// is kept as it was and never runs.
    @Test func whatThisVersionCantReadIsKeptAndDoesntRun() throws {
        let future = try event(#"{"kind":"screenUnlocks","delaySeconds":30}"#)
        #expect(future.isUnsupported)
        #expect(try json(future) == #"{"delaySeconds":30,"kind":"screenUnlocks"}"#)

        let text = #"{"id":"7A1660E0-0000-4000-8000-000000000012","groupID":"0C0D1E00-0000-4000-8000-000000000090","enabled":true,"event":{"kind":"screenLocks"},"action":"openAll","runMode":"notice"}"#
        let trigger = try JSONDecoder().decode(GroupTrigger.self, from: Data(text.utf8))
        #expect(trigger.event == .screenLocks)
        #expect(!trigger.canRun)
        #expect(trigger.problem != nil)
    }

    @Test func aFileWithLockTriggersAndANewerKindSurvivesTheStore() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "triggers.json")
        let newer: JSONValue = .object(["kind": .string("screenLockedFor"), "minutes": .integer(5)])
        let triggers = [
            GroupTrigger(groupID: Self.work.id, event: .screenLocks, action: .finish),
            GroupTrigger(groupID: Self.work.id, event: .screenUnlocks, action: .openAll),
            GroupTrigger(groupID: Self.work.id, event: .unsupported(newer), action: .start),
        ]
        try JSONFileTriggerPersistence(fileURL: url).saveTriggers(triggers)
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: url), saveDelay: .zero)
        #expect(store.triggers == triggers)
        var edited = store.triggers[1]
        edited.oncePerDay = true
        #expect(store.update(edited))
        store.flushPendingSave()
        let reread = try JSONFileTriggerPersistence(fileURL: url).loadTriggers()
        #expect(reread.map(\.event) == [.screenLocks, .screenUnlocks, .unsupported(newer)])
        #expect(reread[1].oncePerDay)
    }

    @Test func backupsCarryThemTurnedOff() throws {
        let lock = GroupTrigger(groupID: Self.work.id, event: .screenLocks, action: .finish)
        let unlock = GroupTrigger(groupID: Self.work.id, event: .screenUnlocks, action: .showPopup)
        let backup = SettingsBackup(appVersion: "0.13.3", exportedAt: Date(timeIntervalSince1970: 1_793_400_000), groups: [Self.work], archivedGroups: [], triggers: [lock, unlock], preferences: PopupPreferences())
        let restored = try SettingsBackup.decode(from: backup.encoded())
        #expect(restored.triggers.map(\.event) == [.screenLocks, .screenUnlocks])
        #expect(restored.triggers.allSatisfy { !$0.isEnabled })
    }

    @Test func theEditorOffersBothAndKeepsTheirActions() throws {
        let calendar = TriggerTime.calendar()
        var draft = TriggerDraft(calendar: calendar)
        #expect(TriggerDraft.When.offered.contains(.moment(.screenLocks)))
        #expect(TriggerDraft.When.offered.contains(.moment(.screenUnlocks)))

        draft.setKind(.screenLocks)
        #expect(draft.event == .screenLocks)
        #expect(draft.action == .finish)
        #expect(draft.allowedActions == [.finish])
        #expect(draft.isValid)
        let lock = draft.trigger(groupID: Self.group)
        #expect(lock.event == .screenLocks && lock.action == .finish && lock.isEnabled)
        #expect(TriggerDraft(editing: lock, calendar: calendar)?.kind == .screenLocks)

        draft.setKind(.screenUnlocks)
        #expect(draft.event == .screenUnlocks)
        #expect(draft.action == .start)
        draft.setAction(.showPopup)
        let unlock = draft.trigger(groupID: Self.group, replacing: lock)
        #expect(unlock.id == lock.id)
        #expect(unlock.event == .screenUnlocks && unlock.action == .showPopup && unlock.runMode == .immediately)
        let reopened = try #require(TriggerDraft(editing: unlock, calendar: calendar))
        #expect(reopened.kind == .screenUnlocks)
        #expect(reopened.trigger(groupID: Self.group, replacing: unlock) == unlock)
    }

    @Test func theRowsSayWhatTheyWaitFor() {
        let calendar = TriggerTime.calendar()
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(TriggerDescriptions.event(.screenLocks, appName: "App", calendar: calendar, locale: locale) == "When the screen locks")
        #expect(TriggerDescriptions.event(.screenUnlocks, appName: "App", calendar: calendar, locale: locale) == "When the screen unlocks")
    }
}
