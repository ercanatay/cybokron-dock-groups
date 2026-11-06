import Darwin
import Dispatch
import Foundation
import os
import Testing
@testable import DockGroupsCore

// Watch wake-up (docs/design/app-presence-watch-upgrade.md §4.1) and the exec-before-registration
// fixture (§4.2).

// MARK: - Helpers

/// Every descriptor a real watch closed, with what `close` returned (0: it was still open, so it
/// wasn't closed before). Thread-safe: a cancel handler closes on the main queue.
final class DescriptorCloses: Sendable {
    struct Close: Equatable, Sendable {
        let fd: Int32
        let result: Int32
    }

    private let closes = OSAllocatedUnfairLock<[Close]>(initialState: [])

    var all: [Close] { closes.withLock { $0 } }

    var closer: ExperimentalProcessEventWatch.CloseDescriptor {
        { [self] fd in
            let result = Darwin.close(fd)
            closes.withLock { $0.append(Close(fd: fd, result: result)) }
        }
    }
}

/// The PIDs a test's verifier lists.
@MainActor
final class ListedPIDs {
    var pids: [Int32]
    init(_ pids: [Int32]) { self.pids = pids }
}

/// A `/bin/bash` child (or `executable`, a shell) that prints `ready`, waits for a line on its
/// input, then runs `then`. Returned once it printed `ready`, so whatever the launch itself did is
/// over before a test registers anything.
private func startShell(_ children: ChildProcesses, executable: URL = URL(fileURLWithPath: "/bin/bash"), then script: String, arguments: [String] = []) async throws -> (Process, FileHandle) {
    let input = Pipe()
    let output = Pipe()
    let child = Process()
    child.executableURL = executable
    child.arguments = ["-c", "echo ready; read _; \(script)"] + arguments
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    try children.adopt(child).run()
    var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
    let first = try await lines.next()
    try #require(first == "ready")
    return (child, input.fileHandleForWriting)
}

/// The executable a PID runs now, or `nil`.
private func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

// MARK: - The real watch's wake-up

@Suite("Process watch: wake-up", .serialized)
@MainActor
struct ProcessWatchWakeUpTests {
    @Test func aStartedWakeUpIsCancelledBeforeItsDescriptorIsClosedOnce() async throws {
        let closes = DescriptorCloses()
        let watch = try #require(ExperimentalProcessEventWatch(pid: getpid(), closeDescriptor: closes.closer))
        #expect(watch.startSignalling {})
        // Once only.
        #expect(!watch.startSignalling {})
        let source = try #require(watch.signalSource)
        #expect(!source.isCancelled)
        watch.close()
        #expect(source.isCancelled)
        #expect(watch.signalSource == nil)
        #expect(watch.poll() == .unknown)
        // The cancel handler closes the descriptor, on the main queue after this turn.
        #expect(closes.all.isEmpty)
        #expect(await eventually { closes.all.count == 1 })
        #expect(closes.all.first?.result == 0)
        // Closing again, or starting again, closes nothing twice.
        watch.close()
        #expect(!watch.startSignalling {})
        try? await Task.sleep(for: .milliseconds(50))
        #expect(closes.all.count == 1)
    }

    @Test func withoutAWakeUpCloseClosesAtOnceAndOnce() throws {
        let closes = DescriptorCloses()
        let watch = try #require(ExperimentalProcessEventWatch(pid: getpid(), closeDescriptor: closes.closer))
        watch.close()
        #expect(closes.all.count == 1)
        #expect(closes.all.first?.result == 0)
        watch.close()
        #expect(closes.all.count == 1)
        // A latched watch can't start one.
        let latched = try #require(ExperimentalProcessEventWatch(pid: getpid(), closeDescriptor: closes.closer))
        #expect(latched.consumePollResult(count: -1, event: kevent()) == .unknown)
        #expect(!latched.startSignalling {})
        #expect(latched.signalSource == nil)
        latched.close()
        #expect(closes.all.count == 2)
        #expect(closes.all.last?.result == 0)
    }

    @Test func releasingAWatchCancelsItsWakeUpAndClosesItsDescriptorOnce() async throws {
        let closes = DescriptorCloses()
        var watch = ExperimentalProcessEventWatch(pid: getpid(), closeDescriptor: closes.closer)
        weak var released: ExperimentalProcessEventWatch?
        released = watch
        #expect(watch?.startSignalling {} == true)
        let source = try #require(watch?.signalSource)
        watch = nil
        #expect(released == nil)
        #expect(source.isCancelled)
        #expect(await eventually { closes.all.count == 1 })
        #expect(closes.all.first?.result == 0)
    }

    @Test func theWakeUpFiresOnARealExecAndExit() async throws {
        let closes = DescriptorCloses()
        try await withChildProcesses { children in
            // Exec.
            let (shell, input) = try await startShell(children, then: "exec /bin/sleep 30")
            defer { try? input.close() }
            let execWatch = try #require(ExperimentalProcessEventWatch(pid: shell.processIdentifier, closeDescriptor: closes.closer))
            var execSeen: [ExperimentalProcessEventWatchPollResult] = []
            let execStarted = execWatch.startSignalling { [weak execWatch] in
                guard let execWatch else { return }
                let result = execWatch.poll()
                execSeen.append(result)
                if result != .idle { execWatch.close() }
            }
            #expect(execStarted)
            #expect(execWatch.poll() == .idle)
            try input.write(contentsOf: Data("\n".utf8))
            #expect(await eventually(within: .seconds(60)) { execSeen == [.exec] })
            // Exit.
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["30"]
            try children.adopt(sleeper).run()
            let exitWatch = try #require(ExperimentalProcessEventWatch(pid: sleeper.processIdentifier, closeDescriptor: closes.closer))
            var exitSeen: [ExperimentalProcessEventWatchPollResult] = []
            let exitStarted = exitWatch.startSignalling { [weak exitWatch] in
                guard let exitWatch else { return }
                let result = exitWatch.poll()
                exitSeen.append(result)
                if result != .idle { exitWatch.close() }
            }
            #expect(exitStarted)
            #expect(exitWatch.poll() == .idle)
            sleeper.terminate()
            #expect(await eventually(within: .seconds(60)) { exitSeen == [.exit] })
            // Both closed by their handler, each descriptor once.
            #expect(await eventually { closes.all.count == 2 })
            // (The second watch may reuse the first one's number; each close found it open.)
            #expect(closes.all.allSatisfy { $0.result == 0 })
        }
    }
}

// MARK: - The verifier's wake-up, synthetic events

@Suite("Application identity: watch wake-up")
@MainActor
struct ApplicationIdentityWatchWakeUpTests {
    private let binding = VerifierRig.binding

    @Test func anExecWakeUpNarrowsAtOnceWithoutAQuestion() async throws {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        let watch = try #require(rig.latestWatch())
        #expect(watch.isSignalling)
        #expect(await eventually { rig.verdict == .verified })
        #expect(changes == 1)
        let listings = rig.instanceReads
        // A spurious wake-up changes nothing.
        watch.signal()
        #expect(rig.verdict == .verified)
        #expect(changes == 1)
        #expect(!watch.isClosed)
        // An exec: unavailable at once, the coordinator's handler called, no question asked.
        watch.event = .exec
        watch.signal()
        #expect(rig.verdict == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(changes == 2)
        #expect(watch.isClosed)
        #expect(!watch.isSignalling)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.verifier.watchSignalCount == 2)
        #expect(rig.instanceReads == listings)
        #expect(rig.comparisons.callCount == 1)
        // Retried like any failure: a new watch and a fresh check.
        rig.retryGate.open()
        #expect(await eventually { rig.verdict == .verified })
        #expect(rig.comparisons.callCount == 2)
        #expect(rig.latestWatch() !== watch)
        #expect(rig.latestWatch()?.isSignalling == true)
    }

    @Test func otherWatchReportsNarrowAtOnceToo() async throws {
        for event in [ExperimentalProcessEventWatchPollResult.execAndExit, .unknown] {
            let rig = VerifierRig([], coordinated: false)
            defer { rig.tearDown() }
            rig.instances = [42]
            rig.comparisons[42] = .matching
            _ = rig.verifier.verdict(for: binding)
            #expect(await eventually { rig.verdict == .verified })
            let watch = try #require(rig.latestWatch())
            watch.event = event
            watch.signal()
            #expect(rig.verdict == .unavailable)
            #expect(rig.verifier.lastFailure == .processChanged)
            #expect(watch.isClosed)
        }
    }

    /// An exit is no close: the verifier doesn't drop the instance; the workspace list decides.
    @Test func anExitWakeUpOfAVerifiedInstanceIsNotAClose() async throws {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        let watch = try #require(rig.latestWatch())
        watch.event = .exit
        watch.signal()
        // Its watch is closed (no descriptor outlives the process); no verdict changed.
        #expect(watch.isClosed)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.verdict == .verified)
        #expect(changes == 1)
        #expect(rig.verifier.lastFailure == nil)
        // Still listed: unknown, not "closed".
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)

        // Gone from the list: it left cleanly, as a verified instance may.
        let left = VerifierRig([], coordinated: false)
        defer { left.tearDown() }
        left.instances = [42]
        left.comparisons[42] = .matching
        _ = left.verifier.verdict(for: binding)
        #expect(await eventually { left.verdict == .verified })
        left.latestWatch()?.event = .exit
        left.latestWatch()?.signal()
        left.instances = []
        #expect(left.verifier.verdict(for: binding) == .verified)
        #expect(left.verifier.lastFailure == nil)
    }

    @Test func anExitWakeUpBeforeTheCheckFinishedIsUnavailable() async throws {
        let rig = VerifierRig([], blocksSecurity: true, coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        let watch = try #require(rig.latestWatch())
        watch.event = .exit
        watch.signal()
        #expect(rig.verdict == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(changes == 1)
        // The blocked check's late answer changes nothing.
        rig.blocker.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.verdict == .unavailable)
        #expect(changes == 1)
    }

    @Test func aWakeUpThatCantBeStartedIsUnavailableAndNothingIsChecked() async throws {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        let watch = FakeProcessWatch()
        watch.signallingFails = true
        rig.watchFor[42] = watch
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .watchUnavailable)
        #expect(rig.comparisons.callCount == 0)
        #expect(watch.isClosed)
        #expect(rig.verifier.watchCount == 0)
        // The retry registers a new watch; only with its wake-up started is anything checked.
        rig.retryGate.open()
        #expect(await eventually { rig.verdict == .verified })
        #expect(rig.comparisons.callCount == 1)
        #expect(rig.latestWatch()?.isSignalling == true)
    }

    @Test func aWakeUpThatCantBeStartedRunsNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        let watch = FakeProcessWatch()
        watch.signallingFails = true
        rig.watchFor[42] = watch
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(rig.verdict == .unavailable)
        #expect(await eventually { rig.coordinator.isIdle || rig.sleeper.sleepingCount > 0 })
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.comparisons.callCount == 0)
    }

    @Test func aLateWakeUpOfAReplacedWatchChangesNothing() async throws {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.comparisons[43] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        let replaced = try #require(rig.latestWatch())
        // Another instance: both are watched and checked again, the first watch is replaced.
        rig.instances = [42, 43]
        #expect(rig.verifier.verdict(for: binding) == .pending)
        #expect(replaced.isClosed)
        #expect(await eventually { rig.verdict == .verified })
        let signals = rig.verifier.watchSignalCount
        replaced.event = .exec
        replaced.signal(late: true)
        #expect(rig.verdict == .verified)
        #expect(rig.verifier.verdict(for: binding) == .verified)
        #expect(rig.verifier.watchCount == 2)
        #expect(rig.verifier.watchSignalCount == signals)
        // A wake-up after the binding was forgotten changes nothing either.
        let current = try #require(rig.latestWatch())
        rig.verifier.retainOnly([])
        current.event = .exec
        current.signal(late: true)
        #expect(rig.verdict == nil)
        #expect(rig.verifier.watchSignalCount == signals)
    }

    // MARK: With the coordinator

    @Test func anExecWakeUpDropsTheSettlingFiringAndNothingRuns() async throws {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(await eventually { rig.sleeper.sleepingCount > 0 })
        #expect(rig.outcome(trigger) == nil)
        let watch = try #require(rig.latestWatch())
        watch.event = .exec
        watch.signal()
        // At once, without a snapshot: dropped and recorded.
        #expect(rig.verdict == .unavailable)
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
        #expect(rig.coordinator.waitingFirings.isEmpty)
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        // The rule is no longer observed; the app is asked to restart its observations.
        #expect(await eventually { rig.restartRequests == 1 })
        #expect(!rig.begin())
    }

    @Test func anExecWakeUpDismissesTheNoticeAndNothingRuns() async throws {
        let trigger = VerifierRig.trigger(.start, runMode: .notice)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        rig.presenter.holds = true
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(await rig.endSettle())
        #expect(await eventually { rig.presenter.isShowing })
        let watch = try #require(rig.latestWatch())
        watch.event = .exec
        watch.signal()
        #expect(rig.presenter.dismissCount == 1)
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
        // Approval kept: an exec isn't a code change, only a fresh check can say that.
        #expect(rig.store.triggers.first?.applicationIdentityStatus == .authorized)
    }

    /// The wake-up is no evidence: after it, nothing runs until a fresh check confirmed the code
    /// again, and then only on a new edge.
    @Test func nothingRunsAfterAWakeUpUntilAFreshCheckConfirmsAgain() async throws {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["openAll"])
        #expect(rig.comparisons.callCount == 1)
        let watch = try #require(rig.latestWatch())
        watch.event = .exec
        watch.signal()
        #expect(rig.verdict == .unavailable)
        // Meanwhile the rule isn't observed at all, and nothing is checked.
        #expect(await eventually { rig.restartRequests == 1 })
        #expect(!rig.begin())
        #expect(rig.comparisons.callCount == 1)
        #expect(rig.handler.calls == ["openAll"])
        // The retry checks again (a new watch) before anything is observed again.
        rig.retryGate.open()
        #expect(await eventually { rig.verdict == .verified })
        #expect(rig.comparisons.callCount == 2)
        #expect(await eventually { rig.restartRequests == 2 })
        #expect(rig.begin())
        #expect(rig.handler.calls == ["openAll"])
        // A new edge, past the cooldown: the instance leaves, another one comes, is checked, and
        // only then runs.
        rig.clock.now = rig.clock.now.addingTimeInterval(TriggerEvaluator.cooldown + 1)
        rig.observe(1)
        rig.instances = []
        rig.observe(0)
        rig.instances = [43]
        rig.comparisons[43] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(rig.comparisons.callCount == 3)
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["openAll", "openAll"])
    }
}

// MARK: - The verifier's wake-up, real watches and processes

@Suite("Application identity: watch wake-up with real processes", .serialized)
@MainActor
struct ApplicationIdentityRealWakeUpTests {
    private let binding = VerifierRig.binding

    @Test func sweepResetAndReleaseCancelEveryWakeUpAndCloseEveryDescriptorOnce() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try children.adopt(child).run()
            let pid = child.processIdentifier
            for path in ["sweep", "reset", "release"] {
                let closes = DescriptorCloses()
                weak var watch: ExperimentalProcessEventWatch?
                var verifier: RunningApplicationIdentityVerifier? = RunningApplicationIdentityVerifier(
                    instances: { _ in [pid] },
                    makeWatch: { pid in
                        let made = ExperimentalProcessEventWatch(pid: pid, closeDescriptor: closes.closer)
                        watch = made
                        return made
                    },
                    check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching }),
                    retryInterval: .seconds(600)
                )
                #expect(verifier?.verdict(for: binding) == .pending, "\(path)")
                let source = try #require(watch?.signalSource, "\(path)")
                #expect(await eventually { verifier?.displayedVerdict(for: binding) == .verified }, "\(path)")
                #expect(closes.all.isEmpty, "\(path)")
                switch path {
                case "sweep": verifier?.retainOnly([])
                case "reset": verifier?.reset()
                default: verifier = nil
                }
                #expect(source.isCancelled, "\(path)")
                #expect(await eventually { closes.all.count == 1 }, "\(path)")
                #expect(closes.all.first?.result == 0, "\(path)")
                #expect(watch == nil, "\(path)")
                verifier = nil
                try? await Task.sleep(for: .milliseconds(50))
                #expect(closes.all.count == 1, "\(path)")
            }
        }
    }

    /// End to end: a real exec reaches the verifier through the read source; nothing asks it.
    @Test func aRealExecWakesTheVerifierWithoutAQuestion() async throws {
        try await withChildProcesses { children in
            let (shell, input) = try await startShell(children, then: "exec /bin/sleep 30")
            defer { try? input.close() }
            let pid = shell.processIdentifier
            let verifier = RunningApplicationIdentityVerifier(
                instances: { _ in [pid] },
                check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching }),
                retryInterval: .seconds(600)
            )
            defer { verifier.retainOnly([]) }
            var changes = 0
            verifier.setVerdictsChangedHandler { changes += 1 }
            #expect(verifier.verdict(for: binding) == .pending)
            #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
            #expect(changes == 1)
            try input.write(contentsOf: Data("\n".utf8))
            // From here on only the wake-up can tell the verifier (generous bound for a loaded CI).
            #expect(await eventually(within: .seconds(60)) { verifier.displayedVerdict(for: binding) == .unavailable })
            #expect(changes == 2)
            #expect(verifier.lastFailure == .processChanged)
            #expect(verifier.watchCount == 0)
            #expect(verifier.watchSignalCount == 1)
        }
    }

    /// End to end: a real exit closes the watch at once and changes no verdict; still listed, the
    /// instance is unknown, gone it left cleanly.
    @Test func aRealExitClosesTheWatchAndIsNoClose() async throws {
        try await withChildProcesses { children in
            for listedAfterExit in [true, false] {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sleep")
                child.arguments = ["30"]
                try children.adopt(child).run()
                let listed = ListedPIDs([child.processIdentifier])
                let verifier = RunningApplicationIdentityVerifier(
                    instances: { _ in listed.pids },
                    check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching }),
                    retryInterval: .seconds(600)
                )
                defer { verifier.retainOnly([]) }
                var changes = 0
                verifier.setVerdictsChangedHandler { changes += 1 }
                _ = verifier.verdict(for: binding)
                #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
                child.terminate()
                #expect(await eventually(within: .seconds(60)) { verifier.watchCount == 0 })
                #expect(verifier.watchSignalCount == 1)
                #expect(verifier.displayedVerdict(for: binding) == .verified)
                #expect(changes == 1)
                if listedAfterExit {
                    #expect(verifier.verdict(for: binding) == .unavailable)
                    #expect(verifier.lastFailure == .processChanged)
                } else {
                    listed.pids = []
                    #expect(verifier.verdict(for: binding) == .verified)
                    #expect(verifier.lastFailure == nil)
                }
            }
        }
    }
}

// MARK: - Exec before registration (accepted limit)

/// T6 before registration (docs/design/app-presence-watch-upgrade.md §4.2), an ACCEPTED LIMIT,
/// not a closed gap: an exec that happened before the watch was registered is never reported by
/// the watch, and the kernel start time doesn't change on exec, so nothing says which program the
/// listed instance was launched as. What holds is that the fresh check after registration
/// describes the code running then, never the pre-exec code: the miss affects attribution only.
@Suite("Application identity: exec before registration (accepted limit)", .serialized)
@MainActor
struct ApplicationIdentityExecBeforeRegistrationTests {
    @Test func anExecBeforeRegistrationIsMissedByTheWatchButTheFreshCheckSeesTheNewCode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cybokron-exec-before-registration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A shell and a sleeper under the same signing identifier, different code.
        let launcher = root.appendingPathComponent("Launcher.app", isDirectory: true)
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        try await SignedFixture.make(at: launcher, name: "Launcher", executable: "/bin/bash")
        try await SignedFixture.make(at: target, name: "Target")
        let launcherHash = try #require(ApplicationStaticCodeVerifier.codeHashes(for: launcher)?.first)
        let targetHash = try #require(ApplicationStaticCodeVerifier.codeHashes(for: target)?.first)
        #expect(launcherHash != targetHash)
        let targetExecutable = target.appendingPathComponent("Contents/MacOS/Fixture")
        let identifier = SignedFixture.identifier
        try await withChildProcesses { children in
            let (child, input) = try await startShell(
                children,
                executable: launcher.appendingPathComponent("Contents/MacOS/Fixture"),
                then: "exec \"$0\" 30",
                arguments: [targetExecutable.path]
            )
            defer { try? input.close() }
            let pid = child.processIdentifier
            // Before the exec the launcher's code runs.
            #expect(ApplicationRunningCodeVerifier.compare(pid: pid, expected: launcherHash, bundleIdentifier: identifier) == .matching)
            #expect(ApplicationRunningCodeVerifier.compare(pid: pid, expected: targetHash, bundleIdentifier: identifier) == .different)
            let incarnation = try #require(ProcessIncarnation.read(pid: pid))
            try input.write(contentsOf: Data("\n".utf8))
            #expect(await eventually(within: .seconds(60)) { executablePath(of: pid)?.hasSuffix("/Target.app/Contents/MacOS/Fixture") == true })

            // The limit: registered after the exec, the watch never hears of it, and the start
            // time is the launcher's.
            let watch = try #require(ExperimentalProcessEventWatch(pid: pid))
            defer { watch.close() }
            #expect(watch.poll() == .idle)
            #expect(ProcessIncarnation.read(pid: pid) == incarnation)

            // What holds: a fresh lookup describes the code running now, never the launcher's.
            #expect(ApplicationRunningCodeVerifier.compare(pid: pid, expected: targetHash, bundleIdentifier: identifier) == .matching)
            #expect(ApplicationRunningCodeVerifier.compare(pid: pid, expected: launcherHash, bundleIdentifier: identifier) == .different)

            // And so does the verifier, all real (listing aside): an approval of the launcher's
            // code is never confirmed by the process it exec'd into.
            let verifier = RunningApplicationIdentityVerifier(instances: { _ in [pid] }, retryInterval: .seconds(600))
            defer { verifier.retainOnly([]) }
            let targetBinding = ApplicationIdentityBinding.fixture(identifier, hash: targetHash, signature: .adHoc)
            let launcherBinding = ApplicationIdentityBinding.fixture(identifier, hash: launcherHash, signature: .adHoc)
            #expect(verifier.verdict(for: targetBinding) == .pending)
            #expect(verifier.verdict(for: launcherBinding) == .pending)
            #expect(await eventually { verifier.displayedVerdict(for: targetBinding) == .verified })
            #expect(await eventually { verifier.displayedVerdict(for: launcherBinding) == .codeChanged })
            #expect(verifier.verdict(for: targetBinding) == .verified)
        }
    }
}
