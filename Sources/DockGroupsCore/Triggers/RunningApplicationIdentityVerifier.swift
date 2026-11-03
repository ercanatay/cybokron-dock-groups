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
    /// More instances or watches than the verifier takes on.
    case tooManyInstances = 6
    /// A process watch couldn't be registered (the process may already be gone).
    case watchUnavailable = 7
    /// A watch reported exec, exit or an error around a check, or an instance left before its
    /// check finished: the answer might describe code that no longer runs.
    case processChanged = 8

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
/// stops *waiting*: the call keeps running on a detached task until Security returns, and its
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

    private static func result(of comparison: ApplicationRunningCodeVerifier.Comparison) -> ApplicationCodeCheckResult {
        switch comparison {
        case .matching: return .verified
        case .different: return .codeChanged
        case .unknown: return .unavailable(.securityUnavailable)
        }
    }
}

/// A synchronous Security call run on a detached task, waited for at most `timeout` and
/// cancellable. The call itself can't be interrupted: a timeout or a cancellation only stops
/// waiting, the call runs to its end and its answer is ignored.
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
        Task.detached(priority: .userInitiated) {
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
    /// Idempotent.
    func close()
}

extension ExperimentalProcessEventWatch: ApplicationProcessWatching {}

// MARK: - The verifier

/// The app's `ApplicationIdentityVerifying`: for every authorized binding it is asked about, it
/// lists the running instances under the identifier, registers an exec/exit watch on each FIRST,
/// then checks each one freshly (`ApplicationRunningCodeCheck`, off the main actor, 2 s by
/// default), then polls the watches again. It answers from that result:
///
/// - `verified` while the instance set is unchanged (instances that were verified may leave) and
///   every watch stays idle; with no instance running and none unconfirmed having left, too.
/// - `pending` while the check of a new instance set runs (nothing acts meanwhile).
/// - `codeChanged` when any instance is different code; the coordinator then saves the rule as
///   needing re-approval (K2). Never retried, never widened.
/// - `unavailable` for every failure: time-out, cancellation, a Security error, a watch that
///   couldn't be registered or reported exec, exit or an error, an instance that left before it
///   was confirmed, too many instances. A failed binding is checked again after `retryInterval`
///   while it keeps answering `unavailable`, so a retry can't make the rule flap.
///
/// Known gaps (see the threat model): PID reuse and exec before a watch is registered are not
/// detected; nothing wakes the verifier on a watch event (it polls when asked); check and action
/// aren't atomic; the per-verifier watch limit is no process-wide descriptor limit. Logs only
/// `ApplicationCodeCheckFailure.diagnosticCode`.
@MainActor
final class RunningApplicationIdentityVerifier: ApplicationIdentityVerifying {
    typealias Instances = @MainActor (TriggerApplicationIdentifier) -> [Int32]?
    typealias MakeWatch = @MainActor (Int32) -> (any ApplicationProcessWatching)?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// More instances of one app than this are `unavailable(.tooManyInstances)`.
    static let maximumInstancesPerApplication = 16
    /// Open watches (one descriptor each) across every binding of this verifier.
    static let maximumWatches = 64
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
        var phase: Phase
        /// Never reused: a finished check or retry for an older token changes nothing.
        var token: UInt64
        /// The running check or the scheduled retry.
        var work: Task<Void, Never>?
    }

    private let instances: Instances
    private let makeWatch: MakeWatch
    private let check: ApplicationRunningCodeCheck
    private let retryInterval: Duration
    private let sleep: Sleep
    private var entries: [ApplicationIdentityBinding: Entry] = [:]
    private var lastToken: UInt64 = 0
    private var onChange: (@MainActor () -> Void)?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// The latest failure, for tests (never logged with anything identifying).
    private(set) var lastFailure: ApplicationCodeCheckFailure?

    init(
        instances: @escaping Instances = RunningApplicationIdentityVerifier.runningInstances(of:),
        makeWatch: @escaping MakeWatch = { ExperimentalProcessEventWatch(pid: $0) },
        check: ApplicationRunningCodeCheck = ApplicationRunningCodeCheck(),
        retryInterval: Duration = RunningApplicationIdentityVerifier.defaultRetryInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.instances = instances
        self.makeWatch = makeWatch
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
            // A verified instance may leave (its watch may already say exit); anything else a
            // watch reports — exec, an error — means the confirmed code may no longer run.
            let left = entry.instances.subtracting(current)
            let leftCleanly = left.allSatisfy { pid in
                guard let watch = entry.watches[pid] else { return true }
                switch watch.poll() {
                case .idle, .exit: return true
                case .exec, .execAndExit, .unknown: return false
                }
            }
            let stayedIdle = current.intersection(entry.instances).allSatisfy { pid in
                entry.watches[pid]?.poll() == .idle
            }
            guard leftCleanly, stayedIdle else {
                fail(binding, .processChanged, instances: current)
                return .unavailable
            }
            if current.isSubset(of: entry.instances) {
                for pid in left {
                    entry.watches.removeValue(forKey: pid)?.close()
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

    func retainOnly(_ bindings: Set<ApplicationIdentityBinding>) {
        for binding in entries.keys where !bindings.contains(binding) {
            guard var entry = entries.removeValue(forKey: binding) else { continue }
            entry.work?.cancel()
            closeWatches(of: &entry)
        }
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

    /// Watch first, then check, then poll again (in `finish`). Any failure here is `unavailable`.
    private func startCheck(_ binding: ApplicationIdentityBinding, identifier: TriggerApplicationIdentifier, instances current: Set<Int32>, reportAs: ApplicationIdentityVerdict) {
        if var old = entries[binding] {
            old.work?.cancel()
            closeWatches(of: &old)
            entries[binding] = old
        }
        guard current.count <= Self.maximumInstancesPerApplication,
              watchCount + current.count <= Self.maximumWatches
        else {
            fail(binding, .tooManyInstances, instances: current)
            return
        }
        var watches: [Int32: any ApplicationProcessWatching] = [:]
        for pid in current {
            guard let watch = makeWatch(pid) else {
                watches.values.forEach { $0.close() }
                fail(binding, .watchUnavailable, instances: current)
                return
            }
            watches[pid] = watch
            // Anything already pending: the process changed around registration.
            guard watch.poll() == .idle else {
                watches.values.forEach { $0.close() }
                fail(binding, .processChanged, instances: current)
                return
            }
        }
        let token = nextToken()
        var entry = Entry(instances: current, watches: watches, phase: .checking(reportAs: reportAs), token: token)
        let check = check
        let pids = Array(current)
        entry.work = Task { @MainActor [weak self] in
            var results: [ApplicationCodeCheckResult] = []
            await withTaskGroup(of: ApplicationCodeCheckResult.self) { group in
                for pid in pids {
                    group.addTask { await check.check(pid: pid, identifier: binding.identifier, codeHash: binding.codeHash) }
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
        let failure = results.lazy.compactMap { result -> ApplicationCodeCheckFailure? in
            if case .unavailable(let failure) = result { return failure }
            return nil
        }.first
        if results.contains(.codeChanged) {
            closeWatches(of: &entry)
            entry.phase = .codeChanged
            entries[binding] = entry
            logger.notice("Application identity check: different code")
        } else if !watchesIdle {
            entries[binding] = entry
            fail(binding, .processChanged, instances: entry.instances)
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

    private func closeWatches(of entry: inout Entry) {
        for watch in entry.watches.values { watch.close() }
        entry.watches = [:]
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
