import Darwin
import Foundation
import Testing
@testable import DockGroupsCore

// MARK: - The kernel reading

@Suite("Process incarnation: kernel start time")
struct ProcessIncarnationTests {
    /// The executable a PID runs now, or `nil`.
    private func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    @Test func readsThisProcessTheSameEveryTime() throws {
        let first = try #require(ProcessIncarnation.read(pid: getpid()))
        #expect(first.pid == getpid())
        #expect(first.startMicroseconds < 1_000_000)
        #expect(first.startSeconds > 0)
        #expect(Double(first.startSeconds) <= Date().timeIntervalSince1970)
        #expect(ProcessIncarnation.read(pid: getpid()) == first)
    }

    @Test func invalidOrMissingProcessesAreUnreadable() {
        #expect(ProcessIncarnation.read(pid: 0) == nil)
        #expect(ProcessIncarnation.read(pid: -1) == nil)
        #expect(ProcessIncarnation.read(pid: Int32.max) == nil)
        // Another user's process (launchd) isn't readable as the logged-in user.
        if getuid() != 0 {
            #expect(ProcessIncarnation.read(pid: 1) == nil)
        }
    }

    @Test func aReapedChildIsUnreadable() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        let pid = child.processIdentifier
        await child.waitForExit()
        #expect(ProcessIncarnation.read(pid: pid) == nil)
    }

    /// The start time names the fork incarnation, not the image: an exec keeps it (which is why
    /// exec stays the watch's job).
    @Test func execKeepsTheStartTime() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "/bin/sleep 1; exec /bin/sleep 30"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try children.adopt(child).run()
            let pid = child.processIdentifier
            let before = try #require(ProcessIncarnation.read(pid: pid))
            #expect(before.pid == pid)
            #expect(path(of: pid) != "/bin/sleep")
            let execed = await eventuallyAsync { path(of: pid) == "/bin/sleep" }
            #expect(execed)
            let after = try #require(ProcessIncarnation.read(pid: pid))
            #expect(after == before)
        }
    }

    /// The verifier with the real reader and a real watch on a real child: the bracket holds for
    /// a process that doesn't change, so the normal path still verifies.
    @Test @MainActor func theRealReaderKeepsAnUnchangedChildVerified() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try children.adopt(child).run()
            let pid = child.processIdentifier
            let verifier = RunningApplicationIdentityVerifier(
                instances: { _ in [pid] },
                check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching })
            )
            defer { verifier.retainOnly([]) }
            let binding = VerifierRig.binding
            #expect(verifier.verdict(for: binding) == .pending)
            #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
            #expect(verifier.verdict(for: binding) == .verified)
            #expect(verifier.verdict(for: binding) == .verified)
            #expect(verifier.watchCount == 1)
        }
    }

    private func eventuallyAsync(within timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

// MARK: - The bracket around a check

@Suite("Application identity: start-time bracket")
@MainActor
struct ApplicationIdentityStartTimeBracketTests {
    private let binding = VerifierRig.binding
    private let listed = FakeIncarnations.of(42)
    /// The same PID, a later incarnation: the PID was reused.
    private let reused = FakeIncarnations.of(42, start: 1_793_000_100)

    @Test func theNormalPathReadsTheStartTimeAtEveryBracketPoint() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        // Listed, then after the watch was registered.
        #expect(rig.incarnations.reads(of: 42) == 2)
        #expect(await eventually { rig.verdict == .verified })
        // Right before and after the Security call, and when the check finished.
        #expect(rig.incarnations.reads(of: 42) == 5)
        #expect(rig.verifier.verdict(for: binding) == .verified)
        // And at every later question.
        #expect(rig.incarnations.reads(of: 42) == 6)
    }

    @Test func aChangeAtRegistrationIsUnavailableWithoutACheck() {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.incarnations.script(42, [listed, reused])
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(rig.comparisons.callCount == 0)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
    }

    /// Listed as one process, checked as another (different code): never saved as a code change.
    @Test func aChangeBetweenListingAndTheSecurityCallSavesNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .different
        rig.incarnations.script(42, [listed, listed, reused])
        rig.observe(1)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(rig.verifier.lastFailure == .processChanged)
        // The bracket failed before Security was asked.
        #expect(rig.comparisons.callCount == 0)
        #expect(rig.store.triggers.first?.applicationIdentityStatus == .authorized)
        #expect(rig.persistence.saved.first?.applicationIdentityStatus != .needsReapproval)
        #expect(await eventually { rig.coordinator.isIdle || rig.sleeper.sleepingCount > 0 })
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aChangeDuringTheSecurityCallIsUnavailableNeverCodeChanged() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .different
        rig.incarnations.script(42, [listed, listed, listed, reused])
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(rig.comparisons.callCount == 1)
        #expect(rig.verifier.watchCount == 0)
    }

    @Test func aChangeBeforeTheCheckFinishedIsUnavailable() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.incarnations.script(42, [listed, listed, listed, listed, reused])
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(rig.comparisons.callCount == 1)
    }

    @Test func aChangeAfterVerificationIsUnavailable() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        // The watch saw nothing (a missed exit), but the PID now names a later process.
        rig.incarnations.script(42, [reused])
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func aReusedPIDBeforeTheActionIsRecordedAndRunsNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        rig.incarnations.script(42, [reused])
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
    }

    @Test func anUnreadableStartTimeIsUnavailable() async {
        // At listing: no watch, no check.
        let atListing = VerifierRig([], coordinated: false)
        defer { atListing.tearDown() }
        atListing.instances = [42]
        atListing.comparisons[42] = .matching
        atListing.incarnations.script(42, [nil])
        #expect(atListing.verifier.verdict(for: binding) == .unavailable)
        #expect(atListing.verifier.lastFailure == .processUnreadable)
        #expect(atListing.watches.isEmpty)
        #expect(atListing.comparisons.callCount == 0)
        // After registration.
        let atRegistration = VerifierRig([], coordinated: false)
        defer { atRegistration.tearDown() }
        atRegistration.instances = [42]
        atRegistration.incarnations.script(42, [listed, nil])
        #expect(atRegistration.verifier.verdict(for: binding) == .unavailable)
        #expect(atRegistration.verifier.lastFailure == .processUnreadable)
        #expect(atRegistration.allWatchesClosed)
        // Around the Security call.
        let aroundSecurity = VerifierRig([], coordinated: false)
        defer { aroundSecurity.tearDown() }
        aroundSecurity.instances = [42]
        aroundSecurity.comparisons[42] = .matching
        aroundSecurity.incarnations.script(42, [listed, listed, nil])
        _ = aroundSecurity.verifier.verdict(for: binding)
        #expect(await eventually { aroundSecurity.verdict == .unavailable })
        #expect(aroundSecurity.verifier.lastFailure == .processUnreadable)
        #expect(aroundSecurity.comparisons.callCount == 0)
        // At a later question.
        let later = VerifierRig([], coordinated: false)
        defer { later.tearDown() }
        later.instances = [42]
        later.comparisons[42] = .matching
        _ = later.verifier.verdict(for: binding)
        #expect(await eventually { later.verdict == .verified })
        later.incarnations.script(42, [nil])
        #expect(later.verifier.verdict(for: binding) == .unavailable)
        #expect(later.verifier.lastFailure == .processUnreadable)
    }

    @Test func aBracketForAnotherPIDIsInvalidInput() async {
        let comparisons = FakeComparisons()
        comparisons[42] = .matching
        let check = ApplicationRunningCodeCheck(compare: { pid, _, _ in comparisons.compare(pid) })
        let result = await check.check(pid: 42, identifier: VerifierRig.bundle, codeHash: ApplicationIdentityBinding.fixtureHash, incarnation: FakeIncarnations.of(43), readIncarnation: { FakeIncarnations.of($0) })
        #expect(result == .unavailable(.invalidInput))
        #expect(comparisons.callCount == 0)
    }
}

// MARK: - Reset after sleep or a session change

@Suite("Application identity: reset when the Mac can act again")
@MainActor
struct ApplicationIdentityResetTests {
    private let binding = VerifierRig.binding

    @Test func aResetForgetsEverythingAndTheNextQuestionChecksAgain() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        #expect(changes == 1)
        rig.verifier.reset()
        #expect(rig.verdict == nil)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
        #expect(changes == 1)
        // Watched and checked again: pending until confirmed.
        #expect(rig.verifier.verdict(for: binding) == .pending)
        #expect(rig.watches.count == 2)
        #expect(await eventually { rig.verdict == .verified })
        #expect(rig.comparisons.callCount == 2)
    }

    @Test func aCheckRunningAcrossAResetChangesNothing() async {
        let rig = VerifierRig([], blocksSecurity: true, coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        rig.verifier.reset()
        // The Security call returns after the reset: its answer is ignored.
        rig.blocker.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.verdict == nil)
        #expect(changes == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func aFailedBindingsRetryIsCancelledByAReset() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .unknown
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .unavailable })
        rig.verifier.reset()
        rig.comparisons[42] = .matching
        rig.retryGate.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.verdict == nil)
        #expect(rig.comparisons.callCount == 1)
    }

    /// The coordinator's reset (what the app calls on wake): the settling firing is dropped, nothing
    /// runs, the next generation's first snapshot is a baseline, and once the fresh check confirms
    /// the code a new opening runs again.
    @Test func aResetDropsFiringsAndOnlyAFreshCheckLetsARuleRunAgain() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        // The firing is settling when the Mac sleeps and wakes.
        #expect(await eventually { rig.sleeper.sleepingCount > 0 })
        rig.coordinator.stopApplicationObservations()
        rig.coordinator.resetApplicationIdentityVerification()
        #expect(rig.verdict == nil)
        #expect(rig.verifier.watchCount == 0)
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        // Observations start again: the fresh check is pending, nothing may act yet.
        rig.coordinator.resetApplicationIdentityVerification()
        #expect(rig.begin())
        #expect(rig.verdict == .pending)
        // The instance still runs: the first snapshot is a baseline, not an opening.
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.sleeper.sleepingCount == 0)
        #expect(rig.coordinator.isIdle)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.comparisons.callCount == 2)
        // Back to normal: a new opening after the baseline runs.
        rig.instances = []
        rig.observe(0)
        rig.instances = [42]
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["openAll"])
    }
}
