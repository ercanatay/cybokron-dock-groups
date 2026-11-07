import AppKit
import Foundation
import OSLog
import os

// Running-code verification for authorized application-presence rules
// (docs/design/app-presence-identity-authorization.md, "Verifier"). Not race-free, not a process
// identity and not publisher trust: it answers "was every running instance under this identifier
// the authorized code when it was last checked, and has none of their watches reported anything
// since?". The gaps it can't close are listed there and in app-presence-threat-model.md §3.1.

// MARK: - One check

/// Why a running-code check gave no answer. Abstract on purpose: no PID, path, name or hash, so it
/// can be logged (`diagnosticCode`).
enum ApplicationCodeCheckFailure: UInt8, CaseIterable, Sendable {
    /// A PID, identifier or time bound that can't be checked.
    case invalidInput = 1
    /// The Security framework couldn't decide (no such process, invalid signature, an error).
    case securityUnavailable = 2
    /// No answer within the time bound.
    case timedOut = 3
    /// The waiting task was cancelled.
    case cancelled = 4
    /// The running instances couldn't be listed.
    case instancesUnknown = 5
    /// More instances of one app than the verifier takes on.
    case tooManyInstances = 6
    /// A process watch couldn't be registered (the process may already be gone).
    case watchUnavailable = 7
    /// A watch reported exec, exit or an error around a check, an instance left before its check
    /// finished, or its kernel start time changed between two readings (the PID now names another
    /// process): the answer might describe code that no longer runs.
    case processChanged = 8
    /// An instance's kernel start time couldn't be read (`ProcessIncarnation`; the process may be
    /// gone, or reading isn't permitted).
    case processUnreadable = 9
    /// The process-wide watch bound (`ApplicationProcessWatchBudget`) has no room for the
    /// instances' watches; nothing was registered.
    case atCapacity = 10

    var diagnosticCode: UInt8 { rawValue }
}

/// What one fresh check of one running instance found.
enum ApplicationCodeCheckResult: Hashable, Sendable {
    case verified
    case codeChanged
    case unavailable(ApplicationCodeCheckFailure)
}

/// One fresh check of one running process against an expected identifier and exact code hash
/// (`ApplicationRunningCodeVerifier`), off the main actor and bounded in time.
///
/// The Security calls are synchronous and can't be interrupted. A timeout or a cancellation only
/// stops *waiting*: the call keeps running on its own thread until Security returns, and its
/// answer is then ignored. Timeout and cancellation are `unavailable`, never `verified`.
struct ApplicationRunningCodeCheck: Sendable {
    typealias Compare = @Sendable (_ pid: Int32, _ expected: ApplicationCodeHash, _ identifier: String) -> ApplicationRunningCodeVerifier.Comparison
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let defaultTimeout: Duration = .seconds(2)

    let timeout: Duration
    private let compare: Compare
    private let sleep: Sleep

    init(
        timeout: Duration = Self.defaultTimeout,
        compare: @escaping Compare = { ApplicationRunningCodeVerifier.compare(pid: $0, expected: $1, bundleIdentifier: $2) },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.timeout = timeout
        self.compare = compare
        self.sleep = sleep
    }

    func check(pid: Int32, identifier: String, codeHash: ApplicationCodeHash) async -> ApplicationCodeCheckResult {
        guard pid > 0, TriggerApplicationIdentifier(identifier) != nil, timeout > .zero else { return .unavailable(.invalidInput) }
        let compare = compare
        return await BoundedSecurityCall.run(
            timeout: timeout,
            sleep: sleep,
            timedOut: .unavailable(.timedOut),
            cancelled: .unavailable(.cancelled),
            misuse: .unavailable(.invalidInput)
        ) {
            Self.result(of: compare(pid, codeHash, identifier))
        }
    }

    /// The same check, bracketed by `incarnation` on the thread that makes the Security call: the
    /// PID's kernel start time is read right before and right after the comparison and must equal
    /// `incarnation` both times. Otherwise the answer may describe another process that got the
    /// PID, so it is `unavailable(.processChanged)` (or `.processUnreadable` when a reading fails),
    /// never `verified` and never `codeChanged`. Timeout and cancellation are as above.
    func check(pid: Int32, identifier: String, codeHash: ApplicationCodeHash, incarnation: ProcessIncarnation, readIncarnation: @escaping ProcessIncarnation.Read) async -> ApplicationCodeCheckResult {
        guard pid > 0, incarnation.pid == pid, TriggerApplicationIdentifier(identifier) != nil, timeout > .zero else { return .unavailable(.invalidInput) }
        let compare = compare
        return await BoundedSecurityCall.run(
            timeout: timeout,
            sleep: sleep,
            timedOut: .unavailable(.timedOut),
            cancelled: .unavailable(.cancelled),
            misuse: .unavailable(.invalidInput)
        ) {
            if let problem = Self.incarnationProblem(pid: pid, expected: incarnation, read: readIncarnation) { return .unavailable(problem) }
            let result = Self.result(of: compare(pid, codeHash, identifier))
            if let problem = Self.incarnationProblem(pid: pid, expected: incarnation, read: readIncarnation) { return .unavailable(problem) }
            return result
        }
    }

    /// `nil` when `pid` still runs `expected`.
    static func incarnationProblem(pid: Int32, expected: ProcessIncarnation?, read: ProcessIncarnation.Read) -> ApplicationCodeCheckFailure? {
        guard let now = read(pid) else { return .processUnreadable }
        guard let expected, now == expected else { return .processChanged }
        return nil
    }

    private static func result(of comparison: ApplicationRunningCodeVerifier.Comparison) -> ApplicationCodeCheckResult {
        switch comparison {
        case .matching: return .verified
        case .different: return .codeChanged
        case .unknown: return .unavailable(.securityUnavailable)
        }
    }
}

/// A synchronous Security call run on a Dispatch global queue, waited for at most `timeout` and
/// cancellable. The call itself can't be interrupted: a timeout or a cancellation only stops
/// waiting, the call runs to its end and its answer is ignored.
///
/// The call runs outside Swift concurrency's cooperative pool, so a call that hangs never holds a
/// pool thread (the pool has only one per core, and blocking it stalls every task).
enum BoundedSecurityCall {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static func run<Value: Sendable>(
        timeout: Duration,
        sleep: @escaping Sleep,
        timedOut: Value,
        cancelled: Value,
        misuse: Value,
        _ call: @escaping @Sendable () -> Value
    ) async -> Value {
        guard !Task.isCancelled else { return cancelled }
        let outcome = FirstAnswer<Value>(misuse: misuse)
        // Not cancellable: the Security call runs to its end; only the first answer counts.
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.decide(call())
        }
        let timer = Task.detached {
            do { try await sleep(timeout) } catch { return }
            outcome.decide(timedOut)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { outcome.wait($0) }
        } onCancel: {
            outcome.decide(cancelled)
        }
        timer.cancel()
        return result
    }
}

/// The first of a call's answer, its timeout and its cancellation; the others are ignored.
private final class FirstAnswer<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case empty
        case waiting(CheckedContinuation<Value, Never>)
        case decided(Value)
        case done
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .empty)
    private let misuse: Value

    init(misuse: Value) {
        self.misuse = misuse
    }

    func wait(_ continuation: CheckedContinuation<Value, Never>) {
        let misuse = misuse
        let decided: Value? = state.withLock { state in
            switch state {
            case .empty:
                state = .waiting(continuation)
                return nil
            case .decided(let result):
                state = .done
                return result
            case .waiting, .done:
                // Waited on once only.
                return misuse
            }
        }
        if let decided { continuation.resume(returning: decided) }
    }

    func decide(_ result: Value) {
        let waiting: CheckedContinuation<Value, Never>? = state.withLock { state in
            switch state {
            case .empty:
                state = .decided(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .decided, .done:
                return nil
            }
        }
        waiting?.resume(returning: result)
    }
}

// MARK: - Process watches

/// An exec/exit watch on one process (`ExperimentalProcessEventWatch`, kqueue `EVFILT_PROC`).
/// Exec, exit and `.unknown` are terminal; after `close()` it must only answer `.unknown`.
protocol ApplicationProcessWatching: AnyObject {
    /// Non-blocking.
    func poll() -> ExperimentalProcessEventWatchPollResult
    /// Idempotent. Stops a started wake-up; nothing is delivered after it returns.
    func close()
    /// Calls `handler` on the main actor whenever the watch may have something to report, until
    /// `close()`. A hint, never evidence: the handler must `poll()` and decide from that. `false`
    /// when it can't be started; the caller then treats the watch as not registered.
    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool
    /// Calls `action` at most once, right after the watch's descriptor is really closed (at once
    /// when it already is), on whatever thread closes it. `close()` may close it later (a started
    /// wake-up closes it in its source's cancel handler), so this, not `close()`, is when the
    /// descriptor is gone: `ApplicationProcessWatchBudget` frees a slot here. A later call replaces
    /// an action that hasn't run yet.
    func whenDescriptorClosed(_ action: @escaping @Sendable () -> Void)
}

extension ExperimentalProcessEventWatch: ApplicationProcessWatching {}

// MARK: - The verifier

/// The app's `ApplicationIdentityVerifying`: for every authorized binding it is asked about, it
/// lists the running instances under the identifier, reads each one's kernel start time
/// (`ProcessIncarnation`) and registers an exec/exit watch on it FIRST, reads the start time
/// again, then checks each one freshly (`ApplicationRunningCodeCheck`, off the main actor, 2 s by
/// default, bracketed by the start time right before and after the Security call), then polls the
/// watches and reads the start times again. Every reading must equal the one taken at listing. A
/// watch whose wake-up (`ApplicationProcessWatching.startSignalling`) can't be started counts as
/// not registered (`unavailable(.watchUnavailable)`). It answers from that result:
///
/// - `verified` while the instance set is unchanged (instances that were verified may leave),
///   every watch stays idle and every start time is unchanged; with no instance running and none
///   unconfirmed having left, too.
/// - `pending` while the check of a new instance set runs (nothing acts meanwhile).
/// - `codeChanged` when any instance is different code; the coordinator then saves the rule as
///   needing re-approval (K2). Never retried, never widened.
/// - `unavailable` for every failure: time-out, cancellation, a Security error, a watch that
///   couldn't be registered or reported exec, exit or an error, an instance that left before it
///   was confirmed, a start time that changed or couldn't be read, too many instances, no room
///   left in the process-wide watch bound. A failed
///   binding is checked again after `retryInterval` while it keeps answering `unavailable`, so a
///   retry can't make the rule flap.
///
/// `reset()` forgets everything (the Mac can act again after sleep or a session change): no
/// verified state outlives the gap, and every binding is listed, watched and checked again.
///
/// Wake-up (docs/design/app-presence-watch-upgrade.md §4.1): a watch that reports something
/// between questions wakes the verifier (`watchSignalled`), which polls it at once, the same poll a
/// question makes. It only ever narrows: exec, an error, or exit before the instance was confirmed
/// is `unavailable(.processChanged)` at once, with the change handler called and the usual retry
/// scheduled; an exit of a verified instance closes its watch and changes no verdict (whether the
/// instance left is the workspace list's business at the next question). Nothing is confirmed by
/// a wake-up, and a wake-up that never comes leaves the poll at every question as it was.
///
/// Known gaps (see the threat model): a PID reused before the instances were listed (a stale
/// workspace entry) reads as the new process; an exec before a watch is registered isn't reported
/// by the watch (the fresh check sees the post-exec code, so it affects attribution only); check
/// and action aren't atomic (a wake-up after the final poll doesn't stop an action already
/// started); a Security call can't be interrupted. Every watch takes a slot of the process-wide
/// `ApplicationProcessWatchBudget` (shared with `TriggerApplicationApprover`); an instance set whose
/// watches don't fit is `unavailable(.atCapacity)` and the watches already open stay as they are.
/// Logs only `ApplicationCodeCheckFailure.diagnosticCode`.
@MainActor
final class RunningApplicationIdentityVerifier: ApplicationIdentityVerifying {
    typealias Instances = @MainActor (TriggerApplicationIdentifier) -> [Int32]?
    typealias MakeWatch = @MainActor (Int32) -> (any ApplicationProcessWatching)?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// More instances of one app than this are `unavailable(.tooManyInstances)`.
    static let maximumInstancesPerApplication = 16
    nonisolated static let defaultRetryInterval: Duration = .seconds(10)

    private enum Phase {
        /// Checking; answers `reportAs` meanwhile (`pending` for a new set, `unavailable` for a retry).
        case checking(reportAs: ApplicationIdentityVerdict)
        case verified
        case codeChanged
        case unavailable(ApplicationCodeCheckFailure)

        var verdict: ApplicationIdentityVerdict {
            switch self {
            case .checking(let reportAs): return reportAs
            case .verified: return .verified
            case .codeChanged: return .codeChanged
            case .unavailable: return .unavailable
            }
        }
    }

    private struct Entry {
        var instances: Set<Int32>
        var watches: [Int32: any ApplicationProcessWatching]
        /// The incarnation each watched instance had when it was listed.
        var incarnations: [Int32: ProcessIncarnation] = [:]
        var phase: Phase
        /// Never reused: a finished check or retry for an older token changes nothing.
        var token: UInt64
        /// The running check or the scheduled retry.
        var work: Task<Void, Never>?
    }

    private let instances: Instances
    private let makeWatch: MakeWatch
    /// Where every watch takes its slot (`ApplicationProcessWatchBudget.shared` in the app).
    let budget: ApplicationProcessWatchBudget
    private let readIncarnation: ProcessIncarnation.Read
    private let check: ApplicationRunningCodeCheck
    private let retryInterval: Duration
    private let sleep: Sleep
    private var entries: [ApplicationIdentityBinding: Entry] = [:]
    private var lastToken: UInt64 = 0
    private var onChange: (@MainActor () -> Void)?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// The latest failure, for tests (never logged with anything identifying).
    private(set) var lastFailure: ApplicationCodeCheckFailure?
    /// How often `reset()` ran, for tests.
    private(set) var resetCount = 0
    /// How many wake-ups reached a current watch, for tests.
    private(set) var watchSignalCount = 0

    init(
        instances: @escaping Instances = RunningApplicationIdentityVerifier.runningInstances(of:),
        makeWatch: @escaping MakeWatch = { ExperimentalProcessEventWatch(pid: $0) },
        budget: ApplicationProcessWatchBudget = .shared,
        readIncarnation: @escaping ProcessIncarnation.Read = { ProcessIncarnation.read(pid: $0) },
        check: ApplicationRunningCodeCheck = ApplicationRunningCodeCheck(),
        retryInterval: Duration = RunningApplicationIdentityVerifier.defaultRetryInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.instances = instances
        self.makeWatch = makeWatch
        self.budget = budget
        self.readIncarnation = readIncarnation
        self.check = check
        self.retryInterval = retryInterval
        self.sleep = sleep
    }

    /// Open watches, for tests.
    var watchCount: Int { entries.values.reduce(0) { $0 + $1.watches.count } }

    // MARK: ApplicationIdentityVerifying

    func verdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict {
        guard let identifier = TriggerApplicationIdentifier(binding.identifier) else { return .unavailable }
        guard let listed = instances(identifier) else {
            fail(binding, .instancesUnknown, instances: entries[binding]?.instances ?? [])
            return .unavailable
        }
        let current = Set(listed)
        guard var entry = entries[binding] else {
            if current.isEmpty {
                entries[binding] = Entry(instances: [], watches: [:], phase: .verified, token: nextToken())
                return .verified
            }
            startCheck(binding, identifier: identifier, instances: current, reportAs: .pending)
            return entries[binding]?.phase.verdict ?? .unavailable
        }
        switch entry.phase {
        case .codeChanged:
            return .codeChanged
        case .unavailable:
            // Waits for its retry; a new set doesn't count as a fresh start.
            entry.instances = current
            entries[binding] = entry
            return .unavailable
        case .checking(let reportAs):
            guard entry.instances != current else { return reportAs }
            if !entry.instances.subtracting(current).isEmpty {
                // An instance left before its check finished: it was never confirmed.
                fail(binding, .processChanged, instances: current)
                return .unavailable
            }
            startCheck(binding, identifier: identifier, instances: current, reportAs: reportAs)
            return entries[binding]?.phase.verdict ?? .unavailable
        case .verified:
            // A verified instance may leave (its watch may already say exit, or have been closed
            // by an exit wake-up); anything else a watch reports — exec, an error — means the
            // confirmed code may no longer run. A listed instance without a watch fails below.
            let left = entry.instances.subtracting(current)
            let leftCleanly = left.allSatisfy { pid in
                guard let watch = entry.watches[pid] else { return true }
                switch watch.poll() {
                case .idle, .exit: return true
                case .exec, .execAndExit, .unknown: return false
                }
            }
            let stayed = current.intersection(entry.instances)
            let stayedIdle = stayed.allSatisfy { pid in
                entry.watches[pid]?.poll() == .idle
            }
            guard leftCleanly, stayedIdle else {
                fail(binding, .processChanged, instances: current)
                return .unavailable
            }
            // A second line behind the watches: the instances still listed are still the
            // incarnations that were checked.
            if let problem = incarnationProblem(of: entry, pids: stayed) {
                fail(binding, problem, instances: current)
                return .unavailable
            }
            if current.isSubset(of: entry.instances) {
                for pid in left {
                    entry.watches.removeValue(forKey: pid)?.close()
                    entry.incarnations[pid] = nil
                }
                entry.instances = current
                entries[binding] = entry
                return .verified
            }
            startCheck(binding, identifier: identifier, instances: current, reportAs: .pending)
            return entries[binding]?.phase.verdict ?? .unavailable
        }
    }

    func displayedVerdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict? {
        entries[binding]?.phase.verdict
    }

    func setVerdictsChangedHandler(_ handler: @escaping @MainActor () -> Void) {
        onChange = handler
    }

    /// Forgotten bindings' watches are closed, which cancels their wake-ups.
    func retainOnly(_ bindings: Set<ApplicationIdentityBinding>) {
        for binding in entries.keys where !bindings.contains(binding) {
            guard var entry = entries.removeValue(forKey: binding) else { continue }
            entry.work?.cancel()
            closeWatches(of: &entry)
        }
    }

    /// Forgets every binding: checks and retries are cancelled (a Security call already running
    /// isn't interrupted, its answer is ignored), watches are closed (their wake-ups cancelled, a
    /// late one is ignored) and verdicts dropped, so the next question lists, watches and checks
    /// again (`pending` while instances run). No change notification: the caller restarts its
    /// observations itself.
    func reset() {
        resetCount += 1
        let forgotten = entries
        entries = [:]
        for var entry in forgotten.values {
            entry.work?.cancel()
            closeWatches(of: &entry)
        }
        logger.notice("Application identity checks reset")
    }

    /// The snapshot and this verifier's own list read the same workspace list in the same
    /// main-actor turn, so they agree; when they don't, nothing under the identifier is confirmed
    /// (an empty list must never confirm an instance the snapshot counted).
    func confirmObservedInstanceCount(_ count: Int, for binding: ApplicationIdentityBinding) {
        guard let identifier = TriggerApplicationIdentifier(binding.identifier) else { return }
        let listed = instances(identifier).map(Set.init)
        guard listed?.count != count else { return }
        if case .codeChanged? = entries[binding]?.phase { return }
        // No change notification: the caller asks for the verdict next and reconfigures itself.
        fail(binding, .instancesUnknown, instances: listed ?? [])
    }

    // MARK: Checking

    private func nextToken() -> UInt64 {
        lastToken &+= 1
        return lastToken
    }

    /// Start time and watch (with its wake-up) first, then the bracketed check, then poll and read
    /// again (in `finish`). Any failure here is `unavailable`, and nothing is checked.
    ///
    /// The bracket for each instance: its start time read when it is listed (in the main-actor
    /// turn that listed it), again after its watch is registered, right before and right after
    /// the Security call (`ApplicationRunningCodeCheck`), in `finish`, and at every later question
    /// (`verdict(for:)`). All must equal the first.
    private func startCheck(_ binding: ApplicationIdentityBinding, identifier: TriggerApplicationIdentifier, instances current: Set<Int32>, reportAs: ApplicationIdentityVerdict) {
        if var old = entries[binding] {
            old.work?.cancel()
            closeWatches(of: &old)
            entries[binding] = old
        }
        guard current.count <= Self.maximumInstancesPerApplication else {
            fail(binding, .tooManyInstances, instances: current)
            return
        }
        // The whole set fits in the process-wide bound, or nothing is registered (the old watches
        // of this binding were closed above, so their slots count as free).
        guard budget.available >= current.count else {
            fail(binding, .atCapacity, instances: current)
            return
        }
        var watches: [Int32: any ApplicationProcessWatching] = [:]
        var incarnations: [Int32: ProcessIncarnation] = [:]
        func abandon(_ failure: ApplicationCodeCheckFailure) {
            watches.values.forEach { $0.close() }
            fail(binding, failure, instances: current)
        }
        // The wake-ups name this token: one for a check that's gone changes nothing.
        let token = nextToken()
        for pid in current {
            guard let listed = readIncarnation(pid) else {
                abandon(.processUnreadable)
                return
            }
            let watch: any ApplicationProcessWatching
            switch budget.open(pid: pid, with: makeWatch) {
            case .opened(let opened): watch = opened
            case .atCapacity:
                // Another owner took the room between the bound check and here.
                abandon(.atCapacity)
                return
            case .unavailable:
                abandon(.watchUnavailable)
                return
            }
            watches[pid] = watch
            // Fail closed: a watch that can't wake the verifier counts as not registered, never as
            // a poll-only watch.
            guard watch.startSignalling(signalHandler(binding, token: token, pid: pid, watch: watch)) else {
                abandon(.watchUnavailable)
                return
            }
            // Anything already pending: the process changed around registration.
            guard watch.poll() == .idle else {
                abandon(.processChanged)
                return
            }
            // The watch is on the incarnation that was listed, not on a process that got its PID.
            if let problem = ApplicationRunningCodeCheck.incarnationProblem(pid: pid, expected: listed, read: readIncarnation) {
                abandon(problem)
                return
            }
            incarnations[pid] = listed
        }
        var entry = Entry(instances: current, watches: watches, incarnations: incarnations, phase: .checking(reportAs: reportAs), token: token)
        let check = check
        let readIncarnation = readIncarnation
        let pids = incarnations.map { ($0.key, $0.value) }
        entry.work = Task { @MainActor [weak self] in
            var results: [ApplicationCodeCheckResult] = []
            await withTaskGroup(of: ApplicationCodeCheckResult.self) { group in
                for (pid, incarnation) in pids {
                    group.addTask {
                        await check.check(pid: pid, identifier: binding.identifier, codeHash: binding.codeHash, incarnation: incarnation, readIncarnation: readIncarnation)
                    }
                }
                for await result in group {
                    results.append(result)
                }
            }
            if Task.isCancelled { return }
            self?.finish(binding, token: token, identifier: identifier, results: results)
        }
        entries[binding] = entry
    }

    private func finish(_ binding: ApplicationIdentityBinding, token: UInt64, identifier: TriggerApplicationIdentifier, results: [ApplicationCodeCheckResult]) {
        guard var entry = entries[binding], entry.token == token, case .checking = entry.phase else { return }
        let before = entry.phase.verdict
        entry.work = nil
        let watchesIdle = entry.watches.values.allSatisfy { $0.poll() == .idle }
        let bracketProblem = incarnationProblem(of: entry, pids: entry.instances)
        let failure = results.lazy.compactMap { result -> ApplicationCodeCheckFailure? in
            if case .unavailable(let failure) = result { return failure }
            return nil
        }.first
        if results.contains(.codeChanged) {
            // Only a check whose own bracket held answers `codeChanged`.
            closeWatches(of: &entry)
            entry.phase = .codeChanged
            entries[binding] = entry
            logger.notice("Application identity check: different code")
        } else if !watchesIdle {
            entries[binding] = entry
            fail(binding, .processChanged, instances: entry.instances)
        } else if let bracketProblem {
            entries[binding] = entry
            fail(binding, bracketProblem, instances: entry.instances)
        } else if let failure {
            entries[binding] = entry
            fail(binding, failure, instances: entry.instances)
        } else if results.count == entry.instances.count, results.allSatisfy({ $0 == .verified }) {
            entry.phase = .verified
            entries[binding] = entry
        } else {
            entries[binding] = entry
            fail(binding, .securityUnavailable, instances: entry.instances)
        }
        if entries[binding]?.phase.verdict != before {
            onChange?()
        }
    }

    /// `unavailable(failure)` for `instances`, watches closed, and a retry scheduled.
    private func fail(_ binding: ApplicationIdentityBinding, _ failure: ApplicationCodeCheckFailure, instances current: Set<Int32>) {
        var entry = entries[binding] ?? Entry(instances: current, watches: [:], phase: .unavailable(failure), token: 0)
        entry.work?.cancel()
        closeWatches(of: &entry)
        entry.instances = current
        entry.phase = .unavailable(failure)
        let token = nextToken()
        entry.token = token
        lastFailure = failure
        logger.notice("Application identity check unavailable (code \(failure.diagnosticCode, privacy: .public))")
        let sleep = sleep, interval = retryInterval
        entry.work = Task { @MainActor [weak self] in
            do { try await sleep(interval) } catch { return }
            self?.retry(binding, token: token)
        }
        entries[binding] = entry
    }

    /// Checks a failed binding again; it keeps answering `unavailable` until the check succeeds.
    private func retry(_ binding: ApplicationIdentityBinding, token: UInt64) {
        guard let entry = entries[binding], entry.token == token, case .unavailable = entry.phase,
              let identifier = TriggerApplicationIdentifier(binding.identifier)
        else { return }
        guard let listed = instances(identifier) else {
            fail(binding, .instancesUnknown, instances: entry.instances)
            return
        }
        let current = Set(listed)
        if current.isEmpty {
            // Nothing runs: a fresh start. The coordinator restarts its observations (a new
            // generation), so nothing observed while this binding was unavailable is replayed.
            entries[binding] = Entry(instances: [], watches: [:], phase: .verified, token: nextToken())
            onChange?()
            return
        }
        startCheck(binding, identifier: identifier, instances: current, reportAs: .unavailable)
    }

    // MARK: Wake-up

    /// What a watch's wake-up calls. Holds neither the verifier nor the watch.
    private func signalHandler(_ binding: ApplicationIdentityBinding, token: UInt64, pid: Int32, watch: any ApplicationProcessWatching) -> @MainActor () -> Void {
        { [weak self, weak watch] in
            guard let watch else { return }
            guard let self else {
                watch.close()
                return
            }
            self.watchSignalled(binding, token: token, pid: pid, watch: watch)
        }
    }

    /// A watch woke the verifier: poll it now, the same poll a question makes, and narrow the
    /// verdict at once. Never confirms anything and starts no check; a retry does that after
    /// `retryInterval`, with a new watch.
    ///
    /// - `.idle`: nothing (a spurious wake-up).
    /// - `.exit` of a verified instance: its watch is closed (the descriptor doesn't outlive the
    ///   process), the verdict stays. The exit isn't a close: listed at the next question, the
    ///   instance is `processChanged`; gone from the list, it left cleanly.
    /// - Anything else (exec, exec and exit, an error, or an exit before the instance was
    ///   confirmed): `unavailable(.processChanged)`, watches closed, the running check cancelled,
    ///   and the change handler called when the verdict changed (the coordinator then drops the
    ///   firings that are no longer cleared and dismisses their notice).
    ///
    /// A wake-up of a replaced or forgotten watch (another token, another watch) changes nothing;
    /// that watch is closed again, which stops a source that would otherwise keep firing.
    private func watchSignalled(_ binding: ApplicationIdentityBinding, token: UInt64, pid: Int32, watch: any ApplicationProcessWatching) {
        guard var entry = entries[binding], entry.token == token, let current = entry.watches[pid], current === watch else {
            watch.close()
            return
        }
        watchSignalCount += 1
        let event = watch.poll()
        if event == .idle { return }
        if case .verified = entry.phase, event == .exit {
            entry.watches.removeValue(forKey: pid)?.close()
            entries[binding] = entry
            logger.debug("Application identity watch: a verified instance exited")
            return
        }
        let before = entry.phase.verdict
        fail(binding, .processChanged, instances: entry.instances)
        if entries[binding]?.phase.verdict != before {
            onChange?()
        }
    }

    private func closeWatches(of entry: inout Entry) {
        for watch in entry.watches.values { watch.close() }
        entry.watches = [:]
        entry.incarnations = [:]
    }

    /// `nil` when each of `pids` still runs the incarnation `entry` recorded for it (a PID
    /// without a record is a change).
    private func incarnationProblem(of entry: Entry, pids: Set<Int32>) -> ApplicationCodeCheckFailure? {
        for pid in pids {
            if let problem = ApplicationRunningCodeCheck.incarnationProblem(pid: pid, expected: entry.incarnations[pid], read: readIncarnation) {
                return problem
            }
        }
        return nil
    }

    // MARK: Instances

    /// The PIDs of the running applications counted under `identifier`, matched the way
    /// `ApplicationSnapshotCounter` matches them (ASCII, case-insensitive); `nil` for one without
    /// a PID.
    static func runningInstances(of identifier: TriggerApplicationIdentifier) -> [Int32]? {
        var pids: [Int32] = []
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier.utf8.allSatisfy({ $0 < 128 }),
                  bundleIdentifier.lowercased() == identifier.matchKey
            else { continue }
            let pid = application.processIdentifier
            guard pid > 0 else { return nil }
            pids.append(pid)
        }
        return pids
    }
}
