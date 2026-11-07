import Darwin
import Foundation
import os
import Testing
@testable import DockGroupsCore

// The approval's watch wake-up and the process-wide watch bound
// (docs/design/app-presence-watch-upgrade.md, "Implementation status (2026-11-06, approval)").

// MARK: - Wake-ups during the approval

@Suite("Application identity: the approval's watch wake-up", .timeLimit(.minutes(1)))
@MainActor
struct ApplicationIdentityApprovalWakeUpTests {
    /// A watch event while the reading is held ends the approval at once: the Security answer is
    /// never waited for (the reading is still blocked when the approval answers) and nothing is
    /// saved, also after the reading returns.
    private func expectEventEndsTheApprovalAtOnce(_ event: ExperimentalProcessEventWatchPollResult) async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        let watch = rig.watches.first
        #expect(watch?.isSignalling == true)
        watch?.event = event
        watch?.signal()
        // The event closed the watch in the same main-actor turn.
        #expect(watch?.isClosed == true)
        #expect(await approval.value == .failed(.appChanged), "\(event)")
        // Answered while the reading is still blocked.
        #expect(rig.reads.startedCount == 1)
        #expect(rig.nothingLeftOpen)
        #expect(!rig.approver.isApproving)
        rig.reads.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func anExecWakeUpCancelsTheApprovalWithoutWaitingForSecurity() async {
        await expectEventEndsTheApprovalAtOnce(.exec)
    }

    @Test func anExitWakeUpCancelsTheApprovalWithoutWaitingForSecurity() async {
        await expectEventEndsTheApprovalAtOnce(.exit)
    }

    @Test func anExecAndExitOrAnErrorWakeUpCancelsTheApprovalToo() async {
        await expectEventEndsTheApprovalAtOnce(.execAndExit)
        await expectEventEndsTheApprovalAtOnce(.unknown)
    }

    @Test func aWakeUpOfOneOfSeveralInstancesCancelsTheWholeApproval() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.instances = [42, 43, 44]
        for pid: Int32 in [42, 43, 44] { rig.reads[pid] = rig.identity() }
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 3 })
        #expect(rig.watches.count == 3 && rig.budget.openCount == 3)
        rig.watches[1].event = .exec
        rig.watches[1].signal()
        #expect(await approval.value == .failed(.appChanged))
        #expect(rig.nothingLeftOpen)
        rig.reads.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }

    @Test func aSpuriousWakeUpChangesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 1 })
        rig.watches.first?.signal()
        rig.watches.first?.signal()
        #expect(rig.watches.first?.isClosed == false)
        rig.reads.gate.open()
        #expect(await approval.value == .approved)
        #expect(rig.stored(trigger)?.applicationIdentity == .authorized(ApprovalRig.binding()))
        #expect(rig.nothingLeftOpen)
    }

    @Test func aWakeUpThatCantBeStartedApprovesNothingAndReadsNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        rig.reads[43] = rig.identity()
        rig.failsToSignal = [42]
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.checkFailed))
        // With several instances: the ones already registered are closed too.
        rig.instances = [42, 43]
        rig.failsToSignal = [43]
        #expect(await rig.approver.approve(triggerID: trigger.id) == .failed(.checkFailed))
        #expect(rig.reads.startedCount == 0)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(!rig.watches.isEmpty && rig.nothingLeftOpen)
        #expect(!rig.approver.isApproving)
    }

    @Test func anEventDuringTheAdHocConfirmationIsSeenAtOnceAndApprovesNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger])
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity(ApprovalRig.newHash, .adHoc)
        var closedWhileAsking = false
        let outcome = await rig.approver.approve(triggerID: trigger.id, confirmAdHoc: {
            let watch = rig.watches.first
            watch?.event = .exit
            watch?.signal()
            closedWhileAsking = watch?.isClosed == true
            return true
        })
        #expect(outcome == .failed(.appChanged))
        #expect(closedWhileAsking)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.nothingLeftOpen)
    }

    @Test func cancellingClosesEveryWatchAndLateWakeUpsChangeNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.instances = [42, 43]
        rig.reads[42] = rig.identity()
        rig.reads[43] = rig.identity()
        let approval = rig.startApproval(of: trigger)
        #expect(await eventually { rig.reads.startedCount == 2 })
        #expect(rig.budget.openCount == 2)
        approval.cancel()
        #expect(await approval.value == .failed(.cancelled))
        // Answered while the readings are still blocked; nothing is left open.
        #expect(rig.nothingLeftOpen)
        #expect(!rig.approver.isApproving)
        // A wake-up already on its way when the watch was closed reaches nothing.
        for watch in rig.watches {
            watch.event = .exec
            watch.signal(late: true)
        }
        rig.reads.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
        #expect(rig.nothingLeftOpen)
        // The next approval starts from nothing.
        rig.instances = [42]
        #expect(await rig.approver.approve(triggerID: trigger.id) == .approved)
        #expect(rig.nothingLeftOpen)
    }

    @Test func aCallerCancelledBeforehandReadsNothing() async {
        let trigger = ApprovalRig.trigger()
        let rig = ApprovalRig([trigger], holding: true)
        defer { rig.tearDown() }
        rig.reads[42] = rig.identity()
        let approver = rig.approver!
        let approval = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await approver.approve(triggerID: trigger.id)
        }
        #expect(await approval.value == .failed(.cancelled))
        #expect(rig.reads.startedCount == 0)
        #expect(rig.nothingLeftOpen)
        #expect(rig.stored(trigger) == trigger && rig.persistence.saveCount == 0)
    }
}

// MARK: - Real watches

@Suite("Application identity: the approval's wake-up with real processes", .serialized)
@MainActor
struct ApplicationIdentityApprovalRealWakeUpTests {
    /// An approver over real watches on `pid` whose reading is held until `reads.gate` opens.
    private func makeApprover(store: TriggerStore, pid: Int32, reads: FakeIdentityReads, closes: DescriptorCloses, budget: ApplicationProcessWatchBudget, watch: @escaping @MainActor (ExperimentalProcessEventWatch) -> Void) -> TriggerApplicationApprover {
        TriggerApplicationApprover(
            store: store,
            instances: { _ in [pid] },
            makeWatch: { pid in
                let made = ExperimentalProcessEventWatch(pid: pid, closeDescriptor: closes.closer)
                if let made { watch(made) }
                return made
            },
            budget: budget,
            read: { pid, identifier in reads.read(pid, identifier) }
        )
    }

    @Test func aRealExecEndsTheApprovalThroughItsWakeUp() async throws {
        try await withChildProcesses { children in
            let (shell, input) = try await startShell(children, then: "exec /bin/sleep 30")
            defer { try? input.close() }
            let trigger = ApprovalRig.trigger()
            let store = TriggerStore(persistence: MemoryTriggerPersistence([trigger]), saveDelay: .zero)
            let reads = FakeIdentityReads(holding: true)
            defer { reads.gate.open() }
            reads[shell.processIdentifier] = .identity(ApplicationRunningIdentity(codeHash: ApprovalRig.newHash, signature: .developerID))
            let closes = DescriptorCloses()
            let budget = ApplicationProcessWatchBudget(limit: 4)
            weak var registered: ExperimentalProcessEventWatch?
            let approver = makeApprover(store: store, pid: shell.processIdentifier, reads: reads, closes: closes, budget: budget) { registered = $0 }
            let approval = Task { @MainActor in await approver.approve(triggerID: trigger.id) }
            #expect(await eventually { reads.startedCount == 1 })
            let source = try #require(registered?.signalSource)
            try input.write(contentsOf: Data("\n".utf8))
            // Only the wake-up can end it: the reading stays blocked (generous bound for CI).
            #expect(await eventually(within: .seconds(60)) { !approver.isApproving })
            #expect(await approval.value == .failed(.appChanged))
            #expect(source.isCancelled)
            #expect(await eventually { closes.all.count == 1 })
            #expect(closes.all.first?.result == 0)
            #expect(budget.openCount == 0)
            #expect(store.trigger(withID: trigger.id) == trigger)
        }
    }

    @Test func aRealExitEndsTheApprovalThroughItsWakeUp() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try children.adopt(child).run()
            let trigger = ApprovalRig.trigger()
            let store = TriggerStore(persistence: MemoryTriggerPersistence([trigger]), saveDelay: .zero)
            let reads = FakeIdentityReads(holding: true)
            defer { reads.gate.open() }
            reads[child.processIdentifier] = .identity(ApplicationRunningIdentity(codeHash: ApprovalRig.newHash, signature: .developerID))
            let closes = DescriptorCloses()
            let budget = ApplicationProcessWatchBudget(limit: 4)
            let approver = makeApprover(store: store, pid: child.processIdentifier, reads: reads, closes: closes, budget: budget) { _ in }
            let approval = Task { @MainActor in await approver.approve(triggerID: trigger.id) }
            #expect(await eventually { reads.startedCount == 1 })
            child.terminate()
            #expect(await eventually(within: .seconds(60)) { !approver.isApproving })
            #expect(await approval.value == .failed(.appChanged))
            #expect(await eventually { closes.all.count == 1 })
            #expect(closes.all.first?.result == 0)
            #expect(budget.openCount == 0)
            #expect(store.trigger(withID: trigger.id) == trigger)
        }
    }

    @Test func cancellingCancelsTheRealWakeUpAndClosesTheDescriptorOnce() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try children.adopt(child).run()
            let trigger = ApprovalRig.trigger()
            let store = TriggerStore(persistence: MemoryTriggerPersistence([trigger]), saveDelay: .zero)
            let reads = FakeIdentityReads(holding: true)
            defer { reads.gate.open() }
            reads[child.processIdentifier] = .identity(ApplicationRunningIdentity(codeHash: ApprovalRig.newHash, signature: .developerID))
            let closes = DescriptorCloses()
            let budget = ApplicationProcessWatchBudget(limit: 4)
            weak var registered: ExperimentalProcessEventWatch?
            let approver = makeApprover(store: store, pid: child.processIdentifier, reads: reads, closes: closes, budget: budget) { registered = $0 }
            let approval = Task { @MainActor in await approver.approve(triggerID: trigger.id) }
            #expect(await eventually { reads.startedCount == 1 })
            let source = try #require(registered?.signalSource)
            #expect(budget.openCount == 1 && closes.all.isEmpty)
            approval.cancel()
            #expect(await approval.value == .failed(.cancelled))
            #expect(source.isCancelled)
            #expect(await eventually { closes.all.count == 1 })
            #expect(closes.all.first?.result == 0)
            #expect(await eventually { registered == nil })
            #expect(budget.openCount == 0)
            // The child exits afterwards: nothing is left to deliver it to.
            child.terminate()
            try? await Task.sleep(for: .milliseconds(100))
            #expect(closes.all.count == 1)
            #expect(store.trigger(withID: trigger.id) == trigger)
        }
    }
}

// MARK: - The process-wide bound

@Suite("Application identity: process-wide watch bound")
@MainActor
struct ApplicationProcessWatchBudgetTests {
    @Test func theAppUsesOneSharedBoundOf64() {
        #expect(ApplicationProcessWatchBudget.processLimit == 64)
        #expect(ApplicationProcessWatchBudget.shared.limit == ApplicationProcessWatchBudget.processLimit)
        // The verifier the coordinator makes and the approver the controller makes share it.
        #expect(RunningApplicationIdentityVerifier().budget === ApplicationProcessWatchBudget.shared)
        let store = TriggerStore(persistence: MemoryTriggerPersistence([]), saveDelay: .zero)
        #expect(TriggerApplicationApprover(store: store).budget === ApplicationProcessWatchBudget.shared)
    }

    @Test func aFullBoundRegistersNothingAndFreesASlotOnceWhenClosedOrReleased() throws {
        let budget = ApplicationProcessWatchBudget(limit: 2)
        var made = 0
        let make: @MainActor (Int32) -> (any ApplicationProcessWatching)? = { _ in
            made += 1
            return FakeProcessWatch()
        }
        guard case .opened(let first) = budget.open(pid: 1, with: make) else { Issue.record("first"); return }
        var second: (any ApplicationProcessWatching)?
        if case .opened(let opened) = budget.open(pid: 2, with: make) { second = opened }
        #expect(second != nil)
        #expect(budget.openCount == 2 && budget.available == 0)
        // Full: nothing is registered, the open watches are untouched.
        guard case .atCapacity = budget.open(pid: 3, with: make) else { Issue.record("not at capacity"); return }
        #expect(made == 2)
        #expect(first.poll() == .idle && second?.poll() == .idle)
        // Closing frees the slot once, however often it is closed.
        first.close()
        first.close()
        #expect(budget.openCount == 1)
        // A registration that fails frees its slot again.
        guard case .unavailable = budget.open(pid: 4, with: { _ in nil }) else { Issue.record("not unavailable"); return }
        #expect(budget.openCount == 1)
        // Released without a close: freed too, and the watch it wrapped is closed.
        let inner = FakeProcessWatch()
        second = nil
        #expect(budget.openCount == 0)
        do {
            guard case .opened(let wrapped) = budget.open(pid: 5, with: { _ in inner }) else { Issue.record("wrap"); return }
            withExtendedLifetime(wrapped) {
                #expect(budget.openCount == 1)
            }
        }
        #expect(budget.openCount == 0)
        #expect(inner.isClosed)
    }

    @Test func aSlotStaysTakenUntilTheDescriptorIsReallyClosedAndIsFreedOnce() throws {
        let budget = ApplicationProcessWatchBudget(limit: 2)
        let deferred = FakeProcessWatch()
        deferred.defersDescriptorClose = true
        guard case .opened(let first) = budget.open(pid: 1, with: { _ in deferred }) else { Issue.record("first"); return }
        guard case .opened(let second) = budget.open(pid: 2, with: { _ in FakeProcessWatch() }) else { Issue.record("second"); return }
        #expect(budget.openCount == 2)
        // Closed, but its descriptor is still open: the slot stays taken, so the bound stays full.
        first.close()
        first.close()
        #expect(deferred.isClosed && !deferred.isDescriptorClosed)
        #expect(budget.openCount == 2)
        guard case .atCapacity = budget.open(pid: 3, with: { _ in FakeProcessWatch() }) else { Issue.record("not at capacity"); return }
        // The descriptor closes: the slot is free, once.
        deferred.closeDescriptor()
        #expect(budget.openCount == 1)
        // A close reported again (or a close again) frees nothing more: the other watch's slot stays.
        deferred.closeDescriptor()
        deferred.reportDescriptorClosed()
        first.close()
        #expect(budget.openCount == 1)
        #expect(second.poll() == .idle)
        second.close()
        #expect(budget.openCount == 0)
    }

    @Test func aWatchReleasedUnclosedHoldsItsSlotUntilItsDescriptorCloses() throws {
        let budget = ApplicationProcessWatchBudget(limit: 1)
        let inner = FakeProcessWatch()
        inner.defersDescriptorClose = true
        do {
            guard case .opened(let wrapped) = budget.open(pid: 1, with: { _ in inner }) else { Issue.record("wrap"); return }
            withExtendedLifetime(wrapped) { #expect(budget.openCount == 1) }
        }
        // Released: the inner watch is closed, its descriptor not yet.
        #expect(inner.isClosed && budget.openCount == 1)
        inner.closeDescriptor()
        #expect(budget.openCount == 0)
        inner.reportDescriptorClosed()
        #expect(budget.openCount == 0)
    }

    @Test func aCallersDescriptorClosedActionRunsAfterTheSlotIsFreed() throws {
        let budget = ApplicationProcessWatchBudget(limit: 1)
        let inner = FakeProcessWatch()
        inner.defersDescriptorClose = true
        guard case .opened(let wrapped) = budget.open(pid: 1, with: { _ in inner }) else { Issue.record("wrap"); return }
        let runs = OSAllocatedUnfairLock(initialState: [Int]())
        wrapped.whenDescriptorClosed { [budget] in
            // Runs once, with the slot already free.
            runs.withLock { $0.append(budget.openCount) }
        }
        wrapped.close()
        #expect(runs.withLock { $0 }.isEmpty)
        inner.closeDescriptor()
        inner.closeDescriptor()
        #expect(runs.withLock { $0 } == [0])
    }

    @Test func aRealWatchsSlotIsFreedWhenItsSourceClosesTheDescriptor() async throws {
        let budget = ApplicationProcessWatchBudget(limit: 1)
        let closes = DescriptorCloses()
        guard case .opened(let watch) = budget.open(pid: getpid(), with: { ExperimentalProcessEventWatch(pid: $0, closeDescriptor: closes.closer) }) else {
            Issue.record("no watch on this process")
            return
        }
        #expect(watch.startSignalling {})
        watch.close()
        // The source's cancel handler closes the descriptor on a later main-queue turn; until then
        // it is open and its slot taken.
        #expect(closes.all.isEmpty)
        #expect(budget.openCount == 1)
        #expect(await eventually { closes.all.count == 1 })
        #expect(closes.all.first?.result == 0)
        #expect(budget.openCount == 0)
        // Nothing more later: one close, one slot freed.
        try await Task.sleep(for: .milliseconds(50))
        #expect(closes.all.count == 1 && budget.openCount == 0)
        // Without a wake-up the descriptor closes inside `close()`, and the slot with it.
        guard case .opened(let plain) = budget.open(pid: getpid(), with: { ExperimentalProcessEventWatch(pid: $0, closeDescriptor: closes.closer) }) else {
            Issue.record("no second watch")
            return
        }
        #expect(budget.openCount == 1)
        plain.close()
        #expect(closes.all.count == 2 && budget.openCount == 0)
    }

    @Test func theVerifierAtTheBoundIsUnavailableAndKeepsItsOtherWatches() async {
        let budget = ApplicationProcessWatchBudget(limit: 2)
        let rig = VerifierRig([], coordinated: false, budget: budget)
        defer { rig.tearDown() }
        let first = VerifierRig.binding
        let second = ApplicationIdentityBinding.fixture("com.example.other")
        rig.instances = [42, 43]
        rig.comparisons[42] = .matching
        rig.comparisons[43] = .matching
        #expect(rig.verifier.verdict(for: first) == .pending)
        #expect(await eventually { rig.verifier.displayedVerdict(for: first) == .verified })
        #expect(budget.openCount == 2)
        let calls = rig.comparisons.callCount
        // The bound is full: the other binding registers nothing and checks nothing.
        #expect(rig.verifier.verdict(for: second) == .unavailable)
        #expect(rig.verifier.lastFailure == .atCapacity)
        #expect(rig.watches.count == 2)
        #expect(rig.comparisons.callCount == calls)
        // The watches already open keep working: still verified, still waking the verifier.
        #expect(rig.verifier.verdict(for: first) == .verified)
        #expect(rig.watches.allSatisfy { !$0.isClosed })
        rig.watches[0].event = .exec
        rig.watches[0].signal()
        #expect(rig.verifier.displayedVerdict(for: first) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        // Its failure closed its watches, which freed their slots.
        #expect(budget.openCount == 0)
    }

    @Test func theVerifierAndTheApproverShareOneBound() async throws {
        let budget = ApplicationProcessWatchBudget(limit: 2)
        let verifierRig = VerifierRig([], coordinated: false, budget: budget)
        defer { verifierRig.tearDown() }
        verifierRig.instances = [42]
        verifierRig.comparisons[42] = .matching
        _ = verifierRig.verifier.verdict(for: VerifierRig.binding)
        #expect(await eventually { verifierRig.verdict == .verified })
        #expect(budget.openCount == 1)

        let trigger = ApprovalRig.trigger()
        let approvalRig = ApprovalRig([trigger], budget: budget)
        defer { approvalRig.tearDown() }
        // Two instances don't fit beside the verifier's watch: nothing is registered or read.
        approvalRig.instances = [7, 8]
        approvalRig.reads[7] = approvalRig.identity()
        approvalRig.reads[8] = approvalRig.identity()
        #expect(await approvalRig.approver.approve(triggerID: trigger.id) == .failed(.checkFailed))
        #expect(approvalRig.watches.isEmpty && approvalRig.reads.startedCount == 0)
        #expect(approvalRig.persistence.saveCount == 0)
        // The verifier's watch is untouched.
        #expect(verifierRig.verifier.verdict(for: VerifierRig.binding) == .verified)
        #expect(verifierRig.verifier.watchCount == 1 && budget.openCount == 1)
        // One fits, and its slot is free again afterwards.
        approvalRig.instances = [7]
        #expect(await approvalRig.approver.approve(triggerID: trigger.id) == .approved)
        #expect(budget.openCount == 1)

        // The other way round: an approval holding the bound leaves the verifier no room.
        let held = ApprovalRig([ApprovalRig.trigger()], holding: true, budget: budget)
        defer { held.tearDown() }
        let heldTrigger = try #require(held.store.triggers.first)
        held.instances = [9]
        held.reads[9] = held.identity()
        let approval = held.startApproval(of: heldTrigger)
        #expect(await eventually { held.reads.startedCount == 1 })
        #expect(budget.openCount == 2)
        let other = ApplicationIdentityBinding.fixture("com.example.other")
        verifierRig.instances = [42]
        #expect(verifierRig.verifier.verdict(for: other) == .unavailable)
        #expect(verifierRig.verifier.lastFailure == .atCapacity)
        // Both owners' open watches keep working.
        #expect(verifierRig.verifier.verdict(for: VerifierRig.binding) == .verified)
        held.reads.gate.open()
        #expect(await approval.value == .approved)
        #expect(budget.openCount == 1)
    }
}

// MARK: - Descriptor exhaustion

/// The process runs out of file descriptors (`RLIMIT_NOFILE`): no watch can be registered, and
/// nothing is read as "verified". The limit is lowered in a child run of this very test (the
/// parent re-runs the test binary filtered to it with `DOCKGROUPS_NOFILE_CHILD` set), so no other
/// test ever sees a low limit. The child lowers the limit to the first free descriptor number,
/// which makes the next `kqueue()` fail with `EMFILE`, and restores it before it ends.
@Suite("Application identity: descriptor exhaustion", .serialized)
@MainActor
struct ApplicationIdentityDescriptorExhaustionTests {
    nonisolated private static let childMarker = "DOCKGROUPS_NOFILE_CHILD"
    nonisolated private static let testName = "exhaustedDescriptorsFailClosedInsteadOfVerifying"

    /// The command line of the test runner re-run for this test alone, or `nil` when the runner
    /// isn't SwiftPM's (`swiftpm-testing-helper … --filter …`).
    nonisolated static var childArguments: [String]? {
        var arguments = CommandLine.arguments
        guard let bundle = arguments.firstIndex(of: "--test-bundle-path"), bundle + 1 < arguments.count else { return nil }
        if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
            arguments[filter + 1] = Self.testName
        } else {
            // The helper ignores a filter placed before its own `--test-bundle-path` option.
            arguments.insert(contentsOf: ["--filter", Self.testName], at: bundle + 2)
        }
        return Array(arguments.dropFirst())
    }

    @Test(.enabled(if: ApplicationIdentityDescriptorExhaustionTests.childArguments != nil))
    func exhaustedDescriptorsFailClosedInsteadOfVerifying() async throws {
        if ProcessInfo.processInfo.environment[Self.childMarker] != nil {
            try await Self.runExhausted()
            return
        }
        let arguments = try #require(Self.childArguments)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging([Self.childMarker: "1"]) { $1 }
        child.standardInput = FileHandle.nullDevice
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let logURL = temporary.url.appending(path: "child.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        child.standardOutput = log
        child.standardError = log
        #expect(try await child.runToExit(timeout: .seconds(60)))
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(child.terminationStatus == 0, "\(text)")
        #expect(text.contains("Test run with 1 test") && text.contains("passed"), "\(text.prefix(2000))")
    }

    /// Runs in the child: lowers the limit, then checks every layer fails closed.
    private static func runExhausted() async throws {
        var original = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &original) == 0)
        // The first descriptor number not in use: any new descriptor would be numbered at or past it.
        var firstFree: Int32 = 0
        while fcntl(firstFree, F_GETFD) != -1 { firstFree += 1 }
        var lowered = original
        lowered.rlim_cur = rlim_t(firstFree)
        try #require(setrlimit(RLIMIT_NOFILE, &lowered) == 0)
        var restored = false
        func restore() {
            guard !restored else { return }
            restored = true
            var limit = original
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
        defer { restore() }

        let pid = getpid()
        // The watch itself: no descriptor, no watch.
        #expect(ExperimentalProcessEventWatch(pid: pid) == nil)

        // The bound: the failed registration frees its slot and reports "unavailable".
        let budget = ApplicationProcessWatchBudget(limit: 4)
        let opening = budget.open(pid: pid) { ExperimentalProcessEventWatch(pid: $0) }
        guard case .unavailable = opening else {
            Issue.record("expected .unavailable, got \(opening)")
            return
        }
        #expect(budget.openCount == 0)

        // The verifier: a running instance whose watch can't be registered is never `verified`.
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in [pid] },
            budget: budget,
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching })
        )
        let binding = ApplicationIdentityBinding.fixture("com.example.app")
        #expect(verifier.verdict(for: binding) == .unavailable)
        #expect([.watchUnavailable, .atCapacity].contains(verifier.lastFailure))
        #expect(verifier.watchCount == 0)
        #expect(verifier.verdict(for: binding) != .verified)
        #expect(budget.openCount == 0)

        // With the limit back, the same registration works: the failures above were the limit.
        restore()
        let watch = try #require(ExperimentalProcessEventWatch(pid: pid))
        watch.close()
    }
}
