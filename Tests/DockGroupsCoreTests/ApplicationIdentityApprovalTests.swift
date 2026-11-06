import Foundation
import os
import Testing
@testable import DockGroupsCore

// MARK: - Fakes

/// What the fake identity reading answers for each PID (`.unknown` when not set). Thread-safe: the
/// reading runs on another thread. With `holding`, every reading waits until `gate` opens.
final class FakeIdentityReads: Sendable {
    private let table = OSAllocatedUnfairLock<[Int32: ApplicationRunningIdentityReading]>(initialState: [:])
    private let started = OSAllocatedUnfairLock<Int>(initialState: 0)
    let gate = FakeGate()
    private let holds: Bool

    init(holding: Bool = false) {
        holds = holding
    }

    subscript(pid: Int32) -> ApplicationRunningIdentityReading {
        get { table.withLock { $0[pid] ?? .unknown } }
        set { table.withLock { $0[pid] = newValue } }
    }

    var startedCount: Int { started.withLock { $0 } }

    func read(_ pid: Int32, _ identifier: String) -> ApplicationRunningIdentityReading {
        started.withLock { $0 += 1 }
        if holds { gate.block() }
        return self[pid]
    }
}

/// An approver over fake instances, watches and readings, saving into a `TriggerStore` kept in
/// memory.
@MainActor
final class ApprovalRig {
    nonisolated static let bundle = "com.example.app"
    nonisolated static let work = DockGroup.of("Work", ["com.apple.mail"])
    nonisolated static let newHash = ApplicationCodeHash(hex: String(repeating: "ab", count: 20))!
    nonisolated static let otherHash = ApplicationCodeHash(hex: String(repeating: "cd", count: 20))!
    nonisolated static let approvedAt = Date(timeIntervalSince1970: 1_794_000_000)

    var instances: [Int32]? = [42]
    private(set) var listings = 0
    private(set) var watches: [FakeProcessWatch] = []
    var failsToWatch: Set<Int32> = []
    /// PIDs whose watch's wake-up can't be started.
    var failsToSignal: Set<Int32> = []
    /// What a newly registered watch reports at its first poll.
    var initialWatchEvent: ExperimentalProcessEventWatchPollResult = .idle
    let reads: FakeIdentityReads
    /// The approver's own watch bound, so other tests' watches don't count against it.
    let budget: ApplicationProcessWatchBudget
    let persistence: MemoryTriggerPersistence
    let store: TriggerStore
    var approver: TriggerApplicationApprover!

    init(_ triggers: [GroupTrigger], holding: Bool = false, timeout: Duration = .seconds(30), budget: ApplicationProcessWatchBudget = ApplicationProcessWatchBudget(limit: ApplicationProcessWatchBudget.processLimit)) {
        reads = FakeIdentityReads(holding: holding)
        self.budget = budget
        persistence = MemoryTriggerPersistence(triggers)
        store = TriggerStore(persistence: persistence, saveDelay: .zero)
        let reads = reads
        weak var box: ApprovalRig?
        approver = TriggerApplicationApprover(
            store: store,
            instances: { _ in box?.list() },
            makeWatch: { pid in box?.makeWatch(pid) },
            budget: budget,
            read: { pid, identifier in reads.read(pid, identifier) },
            timeout: timeout,
            clock: { ApprovalRig.approvedAt }
        )
        box = self
    }

    func tearDown() {
        reads.gate.open()
    }

    private func list() -> [Int32]? {
        listings += 1
        return instances
    }

    private func makeWatch(_ pid: Int32) -> (any ApplicationProcessWatching)? {
        guard !failsToWatch.contains(pid) else { return nil }
        let watch = FakeProcessWatch()
        watch.event = initialWatchEvent
        watch.signallingFails = failsToSignal.contains(pid)
        watches.append(watch)
        return watch
    }

    var allWatchesClosed: Bool { watches.allSatisfy(\.isClosed) }
    /// Every watch closed, none still signalling, and every slot of the bound free again.
    var nothingLeftOpen: Bool { allWatchesClosed && !watches.contains(where: \.isSignalling) && budget.openCount == 0 }

    func identity(_ hash: ApplicationCodeHash = newHash, _ signature: ApplicationIdentityBinding.SignatureKind = .developerID) -> ApplicationRunningIdentityReading {
        .identity(ApplicationRunningIdentity(codeHash: hash, signature: signature))
    }

    /// The binding an approval of `hash` saves.
    nonisolated static func binding(_ hash: ApplicationCodeHash = newHash, _ signature: ApplicationIdentityBinding.SignatureKind = .developerID) -> ApplicationIdentityBinding {
        ApplicationIdentityBinding(identifier: bundle, codeHash: hash, signature: signature, authorizedAt: approvedAt)!
    }

    /// An application trigger of `work`, turned off, with `identity`.
    nonisolated static func trigger(_ identity: ApplicationIdentityAuthorization = .unverified, action: TriggerAction = .showPopup, enabled: Bool = false) -> GroupTrigger {
        var trigger = GroupTrigger(groupID: work.id, event: .applicationPresence(bundleIdentifier: bundle, edge: .starts), action: action, isEnabled: enabled)
        trigger.applicationIdentity = identity
        return trigger
    }

    func stored(_ trigger: GroupTrigger) -> GroupTrigger? { store.trigger(withID: trigger.id) }

    /// Starts an approval in a task (so a test can act while the reading is held).
    func startApproval(of trigger: GroupTrigger) -> Task<TriggerApplicationApprovalOutcome, Never> {
        let approver = approver!
        return Task { @MainActor in await approver.approve(triggerID: trigger.id) }
    }
}

// MARK: - Approving

@Suite("Application identity: the user's approval")
@MainActor
struct ApplicationIdentityApprovalTests {
    @Test func aVerifiedRunningInstanceIsApprovedAndSaved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .approved)
        let saved = rig.stored(trigger)
        #expect(saved?.applicationIdentity == .authorized(ApprovalRig.binding()))
        #expect(saved?.applicationIdentityStatus == .authorized)
        // Written to the file at once, and not turned on.
        #expect(rig.persistence.saved.first?.applicationIdentity == .authorized(ApprovalRig.binding()))
        #expect(saved?.isEnabled == false)
        #expect(rig.watches.count == 1 && rig.allWatchesClosed)
        #expect(!rig.approver.isApproving)
    }

    // MARK: Ad-hoc signatures need a second confirmation

    @Test func anAdHocAppIsApprovedOnlyAfterTheSecondConfirmation() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity(ApprovalRig.newHash, .adHoc)
        var asked = 0
        #expect(await rig.approver.approve(triggerID: trigger.id, confirmAdHoc: { asked += 1; return true }) == .approved)
        #expect(asked == 1)
        #expect(rig.stored(trigger)?.applicationIdentity == .authorized(ApprovalRig.binding(ApprovalRig.newHash, .adHoc)))
        #expect(rig.persistence.saved.first?.applicationIdentity == .authorized(ApprovalRig.binding(ApprovalRig.newHash, .adHoc)))
        #expect(rig.allWatchesClosed)
    }

    @Test func decliningTheAdHocConfirmationSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity(ApprovalRig.newHash, .adHoc)
        #expect(await rig.approver.approve(triggerID: trigger.id, confirmAdHoc: { false }) == .declined)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        // Without a confirmation to ask, an ad-hoc app is never approved.
        #expect(await rig.approver.approve(triggerID: trigger.id) == .declined)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.allWatchesClosed && !rig.approver.isApproving)
    }

    @Test func otherSignaturesAreNeverAskedForASecondConfirmation() async {
        for signature in [ApplicationIdentityBinding.SignatureKind.apple, .appStore, .developerID] {
            let trigger = ApprovalRig.trigger()
            let rig = ApprovalRig([trigger])
            rig.reads[42] = rig.identity(ApprovalRig.newHash, signature)
            var asked = 0
            #expect(await rig.approver.approve(triggerID: trigger.id, confirmAdHoc: { asked += 1; return false }) == .approved)
            #expect(asked == 0)
            #expect(rig.stored(trigger)?.applicationIdentity == .authorized(ApprovalRig.binding(ApprovalRig.newHash, signature)))
            rig.tearDown()
        }
    }

    @Test func reapprovalOfAnAdHocAppAsksTheSameConfirmation() async {
        let old = ApplicationIdentityBinding.fixture(ApprovalRig.bundle)
        let waiting = ApprovalRig.trigger(.needsReapproval(old), action: .openAll)
        let rig = ApprovalRig([waiting])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity(ApprovalRig.newHash, .adHoc)
        #expect(await rig.approver.approve(triggerID: waiting.id, confirmAdHoc: { false }) == .declined)
        #expect(rig.stored(waiting) == waiting && rig.persistence.saveCount == 0)
        var asked = 0
        #expect(await rig.approver.approve(triggerID: waiting.id, confirmAdHoc: { asked += 1; return true }) == .approved)
        #expect(asked == 1)
        #expect(rig.stored(waiting)?.applicationIdentity == .authorized(ApprovalRig.binding(ApprovalRig.newHash, .adHoc)))
    }

    @Test func anAdHocAppThatChangesWhileTheUserDecidesIsNotApproved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity(ApprovalRig.newHash, .adHoc)
        let outcome = await rig.approver.approve(triggerID: trigger.id, confirmAdHoc: { rig.instances = [42, 43]; return true })
        #expect(outcome == .failed(.appChanged))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func aFailedReadingSavesNothing() async {
        let cases: [(ApplicationRunningIdentityReading, TriggerApplicationApprovalFailure)] = [
            (.unknown, .checkFailed),
            (.notApprovable, .unsupportedSignature),
            (.identifierMismatch, .identifierMismatch),
            (.changed, .appChanged),
        ]
        for (reading, failure) in cases {
            let trigger = ApprovalRig.trigger()
            let rig = ApprovalRig([trigger])
            rig.reads[42] = reading
            #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(failure))
            #expect(rig.stored(trigger) == trigger)
            #expect(rig.persistence.saveCount == 0)
            #expect(rig.allWatchesClosed)
            rig.tearDown()
        }
    }

    @Test func anAppThatDoesntRunIsNotApproved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.instances = []
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .notRunning)
        #expect(rig.reads.startedCount == 0)
        #expect(rig.watches.isEmpty)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        // The running apps can't be listed: a failure, not "not running".
        rig.instances = nil
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.checkFailed))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func reapprovalSavesTheNewCodeAndLeavesTheSwitchAlone() async {
        let old = ApplicationIdentityBinding.fixture(ApprovalRig.bundle)
        let waiting = ApprovalRig.trigger(.needsReapproval(old), action: .openAll)
        let rig = ApprovalRig([waiting])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: waiting.id) == .approved)
        let saved = rig.stored(waiting)
        #expect(saved?.applicationIdentity == .authorized(ApprovalRig.binding()))
        #expect(saved?.applicationIdentity?.binding?.codeHash != old.codeHash)
        #expect(saved?.isEnabled == false)
        #expect(saved?.action == .openAll)
        #expect(rig.persistence.saved.first?.applicationIdentity == .authorized(ApprovalRig.binding()))
    }

    @Test func aReapprovedTriggerTurnedOnStaysOn() async {
        // The switch is the user's: approving neither turns it on nor off.
        let waiting = ApprovalRig.trigger(.needsReapproval(.fixture(ApprovalRig.bundle)), enabled: true)
        let rig = ApprovalRig([waiting])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: waiting.id) == .approved)
        #expect(rig.stored(waiting)?.isEnabled == true)
        #expect(rig.stored(waiting)?.canRun == true)
    }

    @Test func afterReapprovalOnlyTheNewCodeIsConfirmed() async throws {
        let old = ApplicationIdentityBinding.fixture(ApprovalRig.bundle)
        let waiting = ApprovalRig.trigger(.needsReapproval(old))
        let rig = ApprovalRig([waiting])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: waiting.id) == .approved)
        let approved = try #require(rig.stored(waiting)?.applicationIdentity?.binding)
        // The verifier's own check: only the approved hash matches the running code.
        let newHash = ApprovalRig.newHash
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in [42] },
            makeWatch: { _ in FakeProcessWatch() },
            readIncarnation: { FakeIncarnations.of($0) },
            check: ApplicationRunningCodeCheck(compare: { _, expected, _ in expected == newHash ? .matching : .different })
        )
        defer { verifier.retainOnly([]) }
        _ = verifier.verdict(for: approved)
        _ = verifier.verdict(for: old)
        #expect(await eventually { verifier.displayedVerdict(for: approved) == .verified })
        #expect(await eventually { verifier.displayedVerdict(for: old) == .codeChanged })
    }

    @Test func approvalOpensEveryActionAndUnverifiedStaysShowPopupOnly() async throws {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        let verifier = FakeApplicationIdentityVerifier(.verified)
        #expect(ApplicationIdentityClearance.of(trigger, verifier: verifier) == .showPopupOnly)
        var draft = TriggerDraft(editing: trigger, calendar: TriggerTime.calendar())
        #expect(draft?.permitsAction(.openAll, replacing: trigger) == false)
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .approved)
        let approved = try #require(rig.stored(trigger))
        #expect(ApplicationIdentityClearance.of(approved, verifier: verifier) == .allActions)
        for action in [TriggerAction.start, .finish, .openAll, .showPopup] {
            #expect(draft?.permitsAction(action, replacing: approved) == true)
        }
        // Saving the editor's draft with another action keeps the approval.
        draft?.setAction(.openAll)
        let edited = draft?.trigger(groupID: ApprovalRig.work.id, replacing: approved)
        #expect(edited?.applicationIdentity == .authorized(ApprovalRig.binding()))
        // A still unverified trigger: Show Popup only, whatever the verifier says.
        let other = ApprovalRig.trigger()
        #expect(ApplicationIdentityClearance.of(other, verifier: verifier) == .showPopupOnly)
        #expect(!approved.canApproveApplication && other.canApproveApplication)
    }

    @Test func importsRestoresAndMergesNeverBringAnApprovalIn() async throws {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .approved)
        let approved = try #require(rig.stored(trigger))
        #expect(approved.applicationIdentityStatus == .authorized)

        // A backup made now carries no approval, and one read back carries none either.
        let groups = [ApprovalRig.work]
        let backup = SettingsBackup(appVersion: "0.11.0", exportedAt: ApprovalRig.approvedAt, groups: groups, archivedGroups: [], triggers: [approved], preferences: PopupPreferences())
        let read = try SettingsBackup.decode(from: backup.encoded())
        #expect(read.triggers.allSatisfy { $0.applicationIdentityStatus == .unverified && !$0.isEnabled })

        // Restoring a backup whose trigger (in memory) claims the approval.
        let groupsPersistence = MemoryGroupPersistence()
        try groupsPersistence.saveGroups(groups)
        let groupStore = GroupStore(persistence: groupsPersistence, saveDelay: .zero)
        let preferences = PreferencesStore(persistence: MemoryPreferencesPersistence(PopupPreferences()), saveDelay: .zero)
        let templates = TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero)
        let restoreStore = TriggerStore(persistence: MemoryTriggerPersistence(), saveDelay: .zero)
        try backup.restore(to: groupStore, preferences: preferences, templates: templates, triggers: restoreStore)
        #expect(!restoreStore.triggers.isEmpty)
        #expect(restoreStore.triggers.allSatisfy { $0.applicationIdentityStatus == .unverified && !$0.isEnabled })

        // Merging into a store without the group.
        let design = DockGroup.of("Design", ["com.figma.Desktop"])
        var mergeTrigger = approved
        mergeTrigger.groupID = design.id
        var incoming = SettingsBackup(appVersion: "0.11.0", exportedAt: ApprovalRig.approvedAt, groups: [ApprovalRig.work, design], archivedGroups: [], triggers: [], preferences: PopupPreferences())
        incoming.triggers = [mergeTrigger]
        let mergeStore = TriggerStore(persistence: MemoryTriggerPersistence(), saveDelay: .zero)
        let mergeGroups = MemoryGroupPersistence()
        try mergeGroups.saveGroups([ApprovalRig.work])
        _ = try incoming.merge(into: GroupStore(persistence: mergeGroups, saveDelay: .zero), templates: TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero), triggers: mergeStore)
        #expect(!mergeStore.triggers.isEmpty)
        #expect(mergeStore.triggers.allSatisfy { $0.applicationIdentityStatus == .unverified && !$0.isEnabled })
        // The approved trigger in the original store is untouched by all this.
        #expect(rig.stored(trigger)?.applicationIdentityStatus == .authorized)
    }

    @Test func anExecDuringTheReadingSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        rig.watches.first?.event = .exec
        rig.reads.gate.open()
        #expect(await approval.value == .failed(.appChanged))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func anAppThatQuitsDuringTheReadingSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        rig.watches.first?.event = .exit
        rig.instances = []
        rig.reads.gate.open()
        #expect(await approval.value == .failed(.appChanged))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func aNewInstanceDuringTheReadingSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        rig.reads[43] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        rig.instances = [42, 43]
        rig.reads.gate.open()
        #expect(await approval.value == .failed(.appChanged))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func aWatchThatCantBeRegisteredOrReportsAtOnceSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        rig.failsToWatch = [42]
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.checkFailed))
        rig.failsToWatch = []
        rig.initialWatchEvent = .exec
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.appChanged))
        #expect(rig.reads.startedCount == 0)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func aTimeOutSavesNothingEvenIfTheReadingLaterSucceeds() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true, timeout: .milliseconds(20))
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.timedOut))
        rig.reads.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func cancellingSavesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        approval.cancel()
        #expect(await approval.value == .failed(.cancelled))
        rig.reads.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(!rig.approver.isApproving)
    }

    @Test func aTriggerChangedDuringTheReadingIsNotApproved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        var edited = trigger
        edited.isEnabled = true
        #expect(rig.store.update(edited))
        rig.reads.gate.open()
        #expect(await approval.value == .failed(.triggerChanged))
        #expect(rig.stored(trigger)?.applicationIdentityStatus == .unverified)
        // A second approval while one runs is refused.
        let held = ApprovalRig([trigger], holding: true)
        defer { held.tearDown() }
        held.reads[42] = held.identity()
        let first = held.startApproval(of: trigger)
        #expect(await eventually { held.reads.startedCount == 1 })
        #expect(await held.approver.approve(triggerID: trigger.id) == .failed(.alreadyApproving))
        held.reads.gate.open()
        #expect(await first.value == .approved)
    }

    @Test func differentVersionsRunningAreNotApproved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.instances = [42, 43]
        rig.reads[42] = rig.identity()
        rig.reads[43] = rig.identity(ApprovalRig.otherHash)
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.differentVersionsRunning))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        // The same signature kind matters too: one exact identity for every instance.
        rig.reads[43] = rig.identity(ApprovalRig.newHash, .adHoc)
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.differentVersionsRunning))
        // The same code in both: approved.
        rig.reads[43] = rig.identity()
        #expect(await rig.approver.approve(triggerID: trigger.id) == .approved)
        #expect(rig.watches.count == 6 && rig.allWatchesClosed)
    }

    @Test func tooManyInstancesAreNotApproved() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.instances = Array(1...Int32(RunningApplicationIdentityVerifier.maximumInstancesPerApplication + 1))
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.tooManyInstances))
        #expect(rig.watches.isEmpty && rig.persistence.saveCount == 0)
    }

    @Test func onlyUnverifiedOrWaitingApplicationTriggersCanBeApproved() async {
        let authorized = ApprovalRig.trigger(.authorize(.fixture(ApprovalRig.bundle)))
        let invalid = ApprovalRig.trigger(.invalid(.string("x")))
        let login = GroupTrigger.on(.login, group: ApprovalRig.work)
        let rig = ApprovalRig([authorized, invalid, login])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        for trigger in [authorized, invalid, login] {
            #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.notApprovable))
            #expect(rig.stored(trigger) == trigger)
        }
        #expect(await rig.approver.approve(triggerID: UUID()) == .failed(.notApprovable))
        #expect(rig.listings == 0 && rig.persistence.saveCount == 0)
    }

    @Test func aWriteThatFailsApprovesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        rig.persistence.failsToSave = true
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.notSaved))
        #expect(rig.stored(trigger) == trigger)
        #expect(rig.persistence.saved.first?.applicationIdentityStatus == .unverified)
    }
}

// MARK: - The bounded call

@Suite("Application identity: bounded Security call")
struct BoundedSecurityCallTests {
    @Test func answersTheCallsResult() async {
        let value = await BoundedSecurityCall.run(timeout: .seconds(30), sleep: { try await Task.sleep(for: $0) }, timedOut: 1, cancelled: 2, misuse: 3) { 0 }
        #expect(value == 0)
    }

    @Test func aCancelledCallerGetsCancelledAtOnce() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BoundedSecurityCall.run(timeout: .seconds(30), sleep: { try await Task.sleep(for: $0) }, timedOut: 1, cancelled: 2, misuse: 3) { 0 }
        }
        #expect(await task.value == 2)
    }

    /// Calls that hang must not hold Swift concurrency's cooperative pool (one thread per core):
    /// with more hung calls than cores, they time out and other calls still answer.
    @Test(.timeLimit(.minutes(1))) func hungCallsDontStarveOtherTasks() async {
        let gate = FakeGate()
        defer { gate.open() }
        let hung = ProcessInfo.processInfo.activeProcessorCount + 2
        let timedOut = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<hung {
                group.addTask {
                    await BoundedSecurityCall.run(timeout: .milliseconds(200), sleep: { try await Task.sleep(for: $0) }, timedOut: 1, cancelled: 2, misuse: 3) {
                        gate.block()
                        return 0
                    }
                }
            }
            var answers: [Int] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        #expect(timedOut == Array(repeating: 1, count: hung))
        let value = await BoundedSecurityCall.run(timeout: .seconds(30), sleep: { try await Task.sleep(for: $0) }, timedOut: 1, cancelled: 2, misuse: 3) { 0 }
        #expect(value == 0)
    }
}
