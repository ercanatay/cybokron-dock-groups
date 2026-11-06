import Darwin
import Dispatch

/// Result of one non-blocking `ExperimentalProcessEventWatch.poll()`.
enum ExperimentalProcessEventWatchPollResult: Equatable {
    /// A clean, immediate timeout: no notification was pending. Not proof the process is alive or unchanged.
    case idle
    /// An exec notification was received. Terminal: the binding is no longer trusted, so callers
    /// must stop using this watch and re-establish a new one.
    case exec
    /// An exit notification was received. Terminal: callers must stop using the watch.
    case exit
    /// Exec and exit were both reported in one (coalesced) notification. Terminal.
    case execAndExit
    /// Anything else: closed descriptor, syscall error (including EINTR), `EV_ERROR`, wrong
    /// ident/filter, unexpected flags, or an unrecognised notification. Fail closed. Terminal:
    /// the watch latches and every later poll also returns `.unknown`, never `.idle`.
    case unknown
}

/// Experimental macOS 14+ synchronous wrapper over kqueue `EVFILT_PROC` (`NOTE_EXEC | NOTE_EXIT`).
/// Its production callers are `RunningApplicationIdentityVerifier`, which registers it before a
/// running-code check, and `TriggerApplicationApprover`, which registers it before reading the
/// code it approves; both poll it on the main actor, let it wake them (`startSignalling`) and take
/// a slot of the process-wide `ApplicationProcessWatchBudget` for it. Everything below applies to
/// both.
///
/// This is NOT a process identity, NOT authorization, and NOT race-free. Read the design draft
/// `docs/design/app-presence-watch-protocol-draft.md` before touching it.
///
/// - Registration is PID based and cannot authenticate which program the PID denotes; a PID can
///   be reused and may already belong to a different process when registration happens.
/// - Registration succeeds only if the kevent call returns zero events and no error. Any returned
///   event (including an immediate `EV_ERROR` such as `ESRCH`) closes the descriptor and fails.
/// - Every returned event must carry `ident == pid` the watch was created with; otherwise the
///   watch latches terminal and reports `.unknown`.
/// - Events that happened before registration are never replayed.
/// - Notifications are asynchronous and may be coalesced (for example exec and exit together).
/// - Exec, exit, and any fail-closed condition are terminal. After any of them the caller must
///   discard this watch and establish a new binding; "no event" is never read as "alive".
/// - Any liveness check, identity verification and subsequent action are not atomic with each
///   other or with the watch.
/// - Use only through `RunningApplicationIdentityVerifier` or `TriggerApplicationApprover`, which
///   treat every non-idle poll as a change.
///
/// Not thread-safe: the caller must serialize every call including `close()` and release; with
/// `startSignalling` that is the main actor. No global state, logging or access to other processes
/// beyond the kqueue registration for the given PID; the only queue is the main queue a started
/// wake-up delivers on.
final class ExperimentalProcessEventWatch {
    typealias PollResult = ExperimentalProcessEventWatchPollResult
    /// Closes the kqueue descriptor (`Darwin.close`); a seam so tests can see when and how often.
    typealias CloseDescriptor = @Sendable (Int32) -> Void

    private let watchedPID: Int32
    private var descriptor: Int32
    private let closeDescriptor: CloseDescriptor
    /// The started wake-up (`startSignalling`): a read source on `descriptor`. While it exists,
    /// only its cancel handler closes the descriptor. `nil` before it starts and after `close()`.
    private(set) var signalSource: (any DispatchSourceRead)?
    /// Latched once exec, exit, or any fail-closed condition is observed. Never cleared.
    private var isLatched = false

    private static let execFlag = UInt32(truncatingIfNeeded: NOTE_EXEC)
    private static let exitFlag = UInt32(truncatingIfNeeded: NOTE_EXIT)
    private static let errorFlag = UInt16(truncatingIfNeeded: EV_ERROR)
    private static let procFilter = Int16(truncatingIfNeeded: EVFILT_PROC)
    private static let allowedReturnedFlags: UInt16 =
        UInt16(truncatingIfNeeded: EV_ADD) | UInt16(truncatingIfNeeded: EV_ENABLE)
        | UInt16(truncatingIfNeeded: EV_CLEAR) | UInt16(truncatingIfNeeded: EV_EOF)
        | UInt16(truncatingIfNeeded: EV_ONESHOT)

    /// Registers for exec/exit notifications of `pid`. Fails (returns nil) for `pid <= 0` or any
    /// kqueue, close-on-exec, or registration failure. Registration succeeds only when the kevent
    /// call returns zero events; an owned descriptor is closed on every failure path.
    init?(pid: Int32, closeDescriptor: @escaping CloseDescriptor = { _ = Darwin.close($0) }) {
        guard pid > 0 else { return nil }
        let fd = kqueue()
        guard fd >= 0 else { return nil }

        // Close-on-exec is mandatory: read existing FD flags, then add FD_CLOEXEC to them.
        let existingFlags = fcntl(fd, F_GETFD)
        guard existingFlags >= 0 else {
            closeDescriptor(fd)
            return nil
        }
        guard fcntl(fd, F_SETFD, existingFlags | FD_CLOEXEC) >= 0 else {
            closeDescriptor(fd)
            return nil
        }

        var change = kevent()
        change.ident = UInt(pid)
        change.filter = Self.procFilter
        change.flags = UInt16(truncatingIfNeeded: EV_ADD) | UInt16(truncatingIfNeeded: EV_ENABLE)
            | UInt16(truncatingIfNeeded: EV_CLEAR)
        change.fflags = Self.execFlag | Self.exitFlag
        change.data = 0
        change.udata = nil

        // Room for one returned event so that any event at all is observed and rejected rather
        // than silently consumed. Success requires count == 0.
        var result = kevent()
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(fd, &change, 1, &result, 1, &zero)
        guard count == 0 else {
            closeDescriptor(fd)
            return nil
        }

        watchedPID = pid
        descriptor = fd
        self.closeDescriptor = closeDescriptor
    }

    deinit {
        close()
    }

    /// Non-blocking poll (zero timeout). Exec, exit, and every fail-closed condition latch the
    /// watch terminal; later polls return `.unknown`. "No event" must never be read as "alive".
    func poll() -> PollResult {
        guard descriptor >= 0, !isLatched else { return .unknown }

        var event = kevent()
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(descriptor, nil, 0, &event, 1, &zero)
        return consumePollResult(count: count, event: event)
    }

    /// Interprets one kevent result. Internal seam so tests can feed deterministic simulated
    /// results; not used by product code. Closed or latched watches always return `.unknown`.
    func consumePollResult(count: Int32, event: kevent) -> PollResult {
        guard descriptor >= 0, !isLatched else { return .unknown }

        if count == 0 { return .idle }
        // -1 (including EINTR) or an unexpected count.
        guard count == 1 else { return latchUnknown() }

        guard event.ident == UInt(watchedPID),
              event.filter == Self.procFilter,
              event.flags & Self.errorFlag == 0,
              event.flags & ~Self.allowedReturnedFlags == 0,
              event.fflags & ~(Self.execFlag | Self.exitFlag) == 0
        else { return latchUnknown() }

        let sawExec = event.fflags & Self.execFlag != 0
        let sawExit = event.fflags & Self.exitFlag != 0

        switch (sawExec, sawExit) {
        case (true, false):
            isLatched = true
            return .exec
        case (false, true):
            isLatched = true
            return .exit
        case (true, true):
            isLatched = true
            return .execAndExit
        case (false, false):
            return latchUnknown()
        }
    }

    /// Wakes `handler` on the main queue whenever the kqueue has an event pending, through a
    /// `DispatchSourceRead` on the descriptor, until `close()`. The wake-up only says "look now": it
    /// reads nothing, so the handler must `poll()` (which reads the event) and must close the watch
    /// once a poll isn't `.idle`, because a latched watch no longer reads its kqueue, which then
    /// stays readable. It proves nothing about the process either; a wake-up that never comes changes
    /// nothing a poll would see.
    ///
    /// `false`, and nothing started, for a closed or latched watch or one that already signals.
    /// Once started, `close()` cancels the source and the source's cancel handler closes the
    /// descriptor (libdispatch requires the descriptor to outlive the source), exactly once.
    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard descriptor >= 0, !isLatched, signalSource == nil else { return false }
        let fd = descriptor
        let closeDescriptor = closeDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler {
            closeDescriptor(fd)
        }
        signalSource = source
        source.activate()
        return true
    }

    /// Closes the kqueue descriptor; with a started wake-up, cancels its source first and leaves
    /// the closing to the source's cancel handler (on the main queue, after this returns).
    /// Idempotent.
    func close() {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        if let source = signalSource {
            signalSource = nil
            source.cancel()
        } else {
            closeDescriptor(fd)
        }
    }

    private func latchUnknown() -> PollResult {
        isLatched = true
        return .unknown
    }
}
