import Foundation
import Security

// The user's explicit approval of an application trigger's app
// (docs/design/app-presence-identity-authorization.md, "Approval"): the only way an `authorized`
// record is created. It reads the code of the instances of the app that run now, confirms it with
// the same requirement the verifier uses, and saves the binding through
// `TriggerStore.setApplicationIdentityAuthorization`, which takes only a value made here. Nothing
// is logged; no path, PID or hash leaves this file except into the store.

// MARK: - Reading one running instance

/// The code of one running instance, as Security reports it.
struct ApplicationRunningIdentity: Hashable, Sendable {
    let codeHash: ApplicationCodeHash
    let signature: ApplicationIdentityBinding.SignatureKind
}

/// What reading one running instance's code found.
enum ApplicationRunningIdentityReading: Hashable, Sendable {
    /// Signed with the expected identifier, read and then confirmed (`identifier` + exact `cdhash`).
    case identity(ApplicationRunningIdentity)
    /// Its signing identifier isn't exactly the expected one (compared case-sensitively).
    case identifierMismatch
    /// Unsigned, or signed in a way that has no `SignatureKind` (a development signature, say).
    case notApprovable
    /// The confirmation found other code than was read: the process changed in between.
    case changed
    /// Security couldn't decide (no such process, invalid signature, an error).
    case unknown
}

/// Reads a running process's signing identifier, exact code hash and signature kind, then
/// confirms them with `ApplicationRunningCodeVerifier.compare` (fresh `SecCode` by PID, validity,
/// `identifier` + `cdhash`). PID based like the verifier, so not race-free (PID reuse, exec before
/// a watch; see the threat model). Synchronous: call it off the main actor, bounded.
enum ApplicationRunningIdentityReader {
    private static let appStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    private static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func read(pid: Int32, expectedIdentifier: String) -> ApplicationRunningIdentityReading {
        guard pid > 0, TriggerApplicationIdentifier(expectedIdentifier) != nil else { return .unknown }
        var dynamicCode: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: Int(pid)] as CFDictionary, SecCSFlags(), &dynamicCode)
        guard status == errSecSuccess, let code = dynamicCode else { return .unknown }
        let validity = SecCodeCheckValidity(code, SecCSFlags(), nil)
        if validity == errSecCSUnsigned { return .notApprovable }
        guard validity == errSecSuccess else { return .unknown }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &onDisk) == errSecSuccess, let staticCode = onDisk else { return .unknown }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { return .unknown }
        guard let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return .notApprovable }
        guard identifier == expectedIdentifier else { return .identifierMismatch }
        guard let unique = info[kSecCodeInfoUnique as String] as? Data, let codeHash = ApplicationCodeHash(bytes: Array(unique)) else { return .unknown }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let signature: ApplicationIdentityBinding.SignatureKind
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            signature = .adHoc
        } else if satisfies(code, "anchor apple") {
            signature = .apple
        } else if satisfies(code, appStore) {
            signature = .appStore
        } else if satisfies(code, developerID) {
            signature = .developerID
        } else {
            return .notApprovable
        }
        // Confirm what was read against the running code, with the verifier's own requirement.
        switch ApplicationRunningCodeVerifier.compare(pid: pid, expected: codeHash, bundleIdentifier: expectedIdentifier) {
        case .matching: return .identity(ApplicationRunningIdentity(codeHash: codeHash, signature: signature))
        case .different: return .changed
        case .unknown: return .unknown
        }
    }

    private static func satisfies(_ code: SecCode, _ expression: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}

// MARK: - Outcome

/// What approving an application trigger's app did (`TriggerApplicationApprover.approve`).
public enum TriggerApplicationApprovalOutcome: Hashable, Sendable {
    /// The running app's code is saved as the trigger's approved code.
    case approved
    /// The app is ad-hoc signed and the user declined the second confirmation. Nothing was saved,
    /// and it isn't an error.
    case declined
    /// The app doesn't run, so there is nothing to check. Nothing was saved.
    case notRunning
    /// Nothing was saved.
    case failed(TriggerApplicationApprovalFailure)
}

/// Why nothing was approved. Abstract on purpose: no path, PID, name or hash.
public enum TriggerApplicationApprovalFailure: String, CaseIterable, Hashable, Sendable {
    /// The trigger isn't a saved application trigger that is unverified or waiting for approval.
    case notApprovable
    /// Another approval is under way.
    case alreadyApproving
    /// The trigger changed (or went) while its app was being checked.
    case triggerChanged
    /// The running app's signing identifier isn't exactly the trigger's bundle identifier.
    case identifierMismatch
    /// Unsigned, or signed in a way that can't be approved.
    case unsupportedSignature
    /// Instances with different code run under the identifier.
    case differentVersionsRunning
    /// More instances than are checked.
    case tooManyInstances
    /// An instance quit, started, exec'd or changed code while it was being checked, or its PID's
    /// kernel start time changed (the PID may name another process now).
    case appChanged
    /// The check took longer than its time bound.
    case timedOut
    /// The check was cancelled.
    case cancelled
    /// The code couldn't be checked (Security error, a watch or its wake-up that couldn't be
    /// started, no room left in the process-wide watch bound, the running apps couldn't be listed,
    /// an instance's kernel start time couldn't be read).
    case checkFailed
    /// The approval couldn't be written to the triggers file.
    case notSaved
}

/// A binding made from a verified, user-approved running instance: only
/// `TriggerApplicationApprover` can make one, so only it can put `authorized` in the store.
struct VerifiedApplicationApproval: Sendable {
    let binding: ApplicationIdentityBinding

    fileprivate init(binding: ApplicationIdentityBinding) {
        self.binding = binding
    }
}

// MARK: - The approver

/// Approves an application trigger's app when the user asks (the editor's Approve button):
///
/// 1. The trigger must be a saved application trigger that is `unverified` or `needsReapproval`.
/// 2. No instance runs: `notRunning`, nothing is saved.
/// 3. Every instance's kernel start time (`ProcessIncarnation`) is read when it is listed. An
///    exec/exit watch with its wake-up (`ApplicationProcessWatching.startSignalling`) is
///    registered on every instance first, each taking a slot of the process-wide
///    `ApplicationProcessWatchBudget` (shared with the verifier); then each instance is read and
///    confirmed off the main actor (`ApplicationRunningIdentityReader`), each bounded by `timeout`
///    and cancellable with the calling task. A watch that can't be registered, whose wake-up can't
///    be started, or that finds no room in the bound saves nothing (`checkFailed`).
///    The start time brackets the approval as it brackets the verifier's check: it is read again
///    after the watch is registered, right before and right after each reading (on the thread
///    that makes the Security call), after the reading and after the ad-hoc confirmation, and
///    must equal the first reading every time. A different one means the PID may now name another
///    process (`appChanged`); one that can't be read is `checkFailed`. Neither saves anything.
/// 4. A watch that reports exec, exit or an error while the approval runs ends it at once
///    (`appChanged`): the watch is closed and the reading cancelled, so no Security answer is
///    waited for. During the ad-hoc confirmation the event is recorded the same way and the
///    user's answer can no longer approve.
/// 5. Saved only when every instance read the same identifier (exactly the trigger's), the same
///    exact `cdhash` and an approvable signature, every watch stayed idle, the instance list and
///    every start time are unchanged and the trigger is as it was. Anything else saves nothing.
///
/// Every watch is closed when `approve` returns, whatever it answers (a cancellation included);
/// closing cancels its wake-up, and a late wake-up changes nothing.
///
/// Saving doesn't turn the trigger on or off. Verification alone never authorizes: the coordinator
/// keeps asking `RunningApplicationIdentityVerifier` before the approved trigger acts.
@MainActor
public final class TriggerApplicationApprover {
    typealias Instances = @MainActor (TriggerApplicationIdentifier) -> [Int32]?
    typealias MakeWatch = @MainActor (Int32) -> (any ApplicationProcessWatching)?
    typealias Read = @Sendable (_ pid: Int32, _ identifier: String) -> ApplicationRunningIdentityReading
    typealias Sleep = @Sendable (Duration) async throws -> Void

    nonisolated static let defaultTimeout: Duration = .seconds(2)

    private let store: TriggerStore
    private let instances: Instances
    private let makeWatch: MakeWatch
    /// Where every watch takes its slot (`ApplicationProcessWatchBudget.shared` in the app).
    let budget: ApplicationProcessWatchBudget
    private let read: Read
    private let readIncarnation: ProcessIncarnation.Read
    private let timeout: Duration
    private let sleep: Sleep
    private let clock: () -> Date

    /// Whether an approval is under way.
    public private(set) var isApproving = false

    public convenience init(store: TriggerStore) {
        self.init(store: store, instances: RunningApplicationIdentityVerifier.runningInstances(of:))
    }

    init(
        store: TriggerStore,
        instances: @escaping Instances,
        makeWatch: @escaping MakeWatch = { ExperimentalProcessEventWatch(pid: $0) },
        budget: ApplicationProcessWatchBudget = .shared,
        read: @escaping Read = { ApplicationRunningIdentityReader.read(pid: $0, expectedIdentifier: $1) },
        readIncarnation: @escaping ProcessIncarnation.Read = { ProcessIncarnation.read(pid: $0) },
        timeout: Duration = TriggerApplicationApprover.defaultTimeout,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.instances = instances
        self.makeWatch = makeWatch
        self.budget = budget
        self.read = read
        self.readIncarnation = readIncarnation
        self.timeout = timeout
        self.sleep = sleep
        self.clock = clock
    }

    private enum InstanceResult: Sendable {
        case read(ApplicationRunningIdentityReading)
        /// The start time right before or right after the reading wasn't the listed one (or
        /// couldn't be read): the reading doesn't count.
        case incarnation(TriggerApplicationApprovalFailure)
        case timedOut
        case cancelled
    }

    /// `nil` when `pid` still runs `expected`; `appChanged` for another start time, `checkFailed`
    /// for one that can't be read.
    nonisolated private static func incarnationFailure(pid: Int32, expected: ProcessIncarnation?, read: ProcessIncarnation.Read) -> TriggerApplicationApprovalFailure? {
        switch ApplicationRunningCodeCheck.incarnationProblem(pid: pid, expected: expected, read: read) {
        case nil: return nil
        case .processChanged?: return .appChanged
        default: return .checkFailed
        }
    }

    /// The first failure among `pids` (`incarnationFailure`), `appChanged` before `checkFailed`.
    private func incarnationFailure(of pids: Set<Int32>, expected: [Int32: ProcessIncarnation]) -> TriggerApplicationApprovalFailure? {
        let failures = pids.compactMap { Self.incarnationFailure(pid: $0, expected: expected[$0], read: readIncarnation) }
        if failures.contains(.appChanged) { return .appChanged }
        return failures.first
    }

    /// One approval's watches and their wake-ups. A wake-up polls its watch (the same poll the
    /// approval makes) and, when the poll isn't `.idle`, marks the approval changed, closes that
    /// watch (a latched watch would keep its source firing) and cancels the reading. Its handlers
    /// hold neither this object nor the watch, and a wake-up after `close()` only closes its watch
    /// again.
    @MainActor
    private final class ApprovalWatches {
        private(set) var watches: [any ApplicationProcessWatching] = []
        /// A watch reported exec, exit or an error since it was registered.
        private(set) var changed = false
        private var isClosed = false
        /// The reading under way; a wake-up that reports something cancels it.
        var reading: Task<[InstanceResult], Never>?

        func add(_ watch: any ApplicationProcessWatching) {
            watches.append(watch)
        }

        func handler(for watch: any ApplicationProcessWatching) -> @MainActor @Sendable () -> Void {
            { [weak self, weak watch] in
                guard let watch else { return }
                guard let self else {
                    watch.close()
                    return
                }
                self.signalled(watch)
            }
        }

        /// Every watch still idle and none reported anything before.
        var allIdle: Bool {
            !changed && watches.allSatisfy { $0.poll() == .idle }
        }

        /// Closes every watch (cancelling its wake-up) and the reading. Idempotent.
        func close() {
            isClosed = true
            reading?.cancel()
            reading = nil
            for watch in watches { watch.close() }
        }

        private func signalled(_ watch: any ApplicationProcessWatching) {
            guard !isClosed, watches.contains(where: { $0 === watch }) else {
                watch.close()
                return
            }
            guard watch.poll() != .idle else { return }
            changed = true
            watch.close()
            reading?.cancel()
        }
    }

    /// Asks the user to confirm approving ad-hoc signed code; `true` approves.
    public typealias AdHocConfirmation = @MainActor () async -> Bool

    /// `confirmAdHoc` is asked once the running code is verified and only when it is ad-hoc signed
    /// (a signature that doesn't verify who made the app). Without it, or when it answers `false`,
    /// an ad-hoc app isn't approved: `declined`, nothing saved. Other signatures never ask.
    public func approve(triggerID: GroupTrigger.ID, confirmAdHoc: AdHocConfirmation? = nil) async -> TriggerApplicationApprovalOutcome {
        guard !isApproving else { return .failed(.alreadyApproving) }
        isApproving = true
        defer { isApproving = false }

        guard let rule = store.trigger(withID: triggerID), rule.canApproveApplication,
              case .applicationPresence(let bundleIdentifier, _) = rule.event,
              let identifier = TriggerApplicationIdentifier(bundleIdentifier)
        else { return .failed(.notApprovable) }
        guard let listed = instances(identifier) else { return .failed(.checkFailed) }
        let pids = Set(listed)
        if pids.isEmpty { return .notRunning }
        guard pids.count <= RunningApplicationIdentityVerifier.maximumInstancesPerApplication else { return .failed(.tooManyInstances) }

        // The incarnations listed, read in the turn that listed them; every later reading must
        // equal these.
        var incarnations: [Int32: ProcessIncarnation] = [:]
        for pid in pids {
            guard let listedIncarnation = readIncarnation(pid) else { return .failed(.checkFailed) }
            incarnations[pid] = listedIncarnation
        }

        // Every watch fits in the process-wide bound, or none is registered.
        guard budget.available >= pids.count else { return .failed(.checkFailed) }

        // Watch first, so an exec or exit around the reading is seen; the wake-up makes one seen
        // at once. Fail closed: a watch that can't wake the approval counts as not registered.
        let watches = ApprovalWatches()
        defer { watches.close() }
        for pid in pids {
            guard case .opened(let watch) = budget.open(pid: pid, with: makeWatch) else { return .failed(.checkFailed) }
            watches.add(watch)
            guard watch.startSignalling(watches.handler(for: watch)) else { return .failed(.checkFailed) }
            guard watch.poll() == .idle else { return .failed(.appChanged) }
            // The watch is on the incarnation that was listed, not on a process that got its PID.
            if let failure = Self.incarnationFailure(pid: pid, expected: incarnations[pid], read: readIncarnation) { return .failed(failure) }
        }

        let read = read, readIncarnation = readIncarnation, timeout = timeout, sleep = sleep
        let expected = incarnations
        let reading = Task { () -> [InstanceResult] in
            await withTaskGroup(of: InstanceResult.self) { group -> [InstanceResult] in
                for pid in pids {
                    let incarnation = expected[pid]
                    group.addTask {
                        await BoundedSecurityCall.run(timeout: timeout, sleep: sleep, timedOut: .timedOut, cancelled: .cancelled, misuse: .read(.unknown)) {
                            // Bracketed on the thread of the Security call, like the verifier's check.
                            if let failure = Self.incarnationFailure(pid: pid, expected: incarnation, read: readIncarnation) { return .incarnation(failure) }
                            let reading = read(pid, bundleIdentifier)
                            if let failure = Self.incarnationFailure(pid: pid, expected: incarnation, read: readIncarnation) { return .incarnation(failure) }
                            return .read(reading)
                        }
                    }
                }
                var results: [InstanceResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }
        watches.reading = reading
        let results = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
        watches.reading = nil

        // A watch reported something: the reading was cancelled, its answers don't count.
        if watches.changed { return .failed(.appChanged) }
        if Task.isCancelled || results.contains(where: { if case .cancelled = $0 { return true }; return false }) {
            return .failed(.cancelled)
        }
        if results.contains(where: { if case .timedOut = $0 { return true }; return false }) {
            return .failed(.timedOut)
        }
        let bracketFailures = results.compactMap { result -> TriggerApplicationApprovalFailure? in
            if case .incarnation(let failure) = result { return failure }
            return nil
        }
        if bracketFailures.contains(.appChanged) { return .failed(.appChanged) }
        if let failure = bracketFailures.first { return .failed(failure) }
        guard watches.allIdle else { return .failed(.appChanged) }
        guard let relisted = instances(identifier) else { return .failed(.checkFailed) }
        guard Set(relisted) == pids else { return .failed(.appChanged) }
        if let failure = incarnationFailure(of: pids, expected: incarnations) { return .failed(failure) }

        let readings = results.compactMap { result -> ApplicationRunningIdentityReading? in
            if case .read(let reading) = result { return reading }
            return nil
        }
        guard readings.count == pids.count else { return .failed(.checkFailed) }
        if readings.contains(.changed) { return .failed(.appChanged) }
        if readings.contains(.identifierMismatch) { return .failed(.identifierMismatch) }
        if readings.contains(.notApprovable) { return .failed(.unsupportedSignature) }
        if readings.contains(.unknown) { return .failed(.checkFailed) }
        // Every reading is an identity now; one exact code for every instance, or nothing.
        let identities = Set(readings.compactMap { reading -> ApplicationRunningIdentity? in
            if case .identity(let identity) = reading { return identity }
            return nil
        })
        guard identities.count == 1, let identity = identities.first else { return .failed(.differentVersionsRunning) }

        // A signature that verifies nobody needs a second, explicit confirmation. The watches stay
        // open meanwhile, so the code is re-checked after the user answers.
        if identity.signature == .adHoc {
            guard let confirmAdHoc, await confirmAdHoc() else { return .declined }
            if Task.isCancelled { return .failed(.cancelled) }
            guard watches.allIdle else { return .failed(.appChanged) }
            guard let confirmed = instances(identifier), Set(confirmed) == pids else { return .failed(.appChanged) }
            if let failure = incarnationFailure(of: pids, expected: incarnations) { return .failed(failure) }
        }

        // The trigger the user approved, unchanged meanwhile.
        guard store.trigger(withID: triggerID) == rule else { return .failed(.triggerChanged) }
        guard let binding = ApplicationIdentityBinding(identifier: bundleIdentifier, codeHash: identity.codeHash, signature: identity.signature, authorizedAt: clock()) else {
            return .failed(.checkFailed)
        }
        guard store.setApplicationIdentityAuthorization(VerifiedApplicationApproval(binding: binding), forTrigger: triggerID, replacing: rule) else {
            return .failed(store.trigger(withID: triggerID) == rule ? .notSaved : .triggerChanged)
        }
        return .approved
    }
}
