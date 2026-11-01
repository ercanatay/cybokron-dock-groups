import Darwin

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

/// UNUSED, EXPERIMENTAL, macOS 14+ synchronous wrapper over kqueue `EVFILT_PROC`
/// (`NOTE_EXEC | NOTE_EXIT`).
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
/// - Do not use in production code paths.
///
/// Not thread-safe: the caller must serialize every call including `close()` and release.
/// No background queue, global state, logging or access to other processes beyond the
/// kqueue registration for the given PID.
final class ExperimentalProcessEventWatch {
    typealias PollResult = ExperimentalProcessEventWatchPollResult

    private let watchedPID: Int32
    private var descriptor: Int32
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
    init?(pid: Int32) {
        guard pid > 0 else { return nil }
        let fd = kqueue()
        guard fd >= 0 else { return nil }

        // Close-on-exec is mandatory: read existing FD flags, then add FD_CLOEXEC to them.
        let existingFlags = fcntl(fd, F_GETFD)
        guard existingFlags >= 0 else {
            Darwin.close(fd)
            return nil
        }
        guard fcntl(fd, F_SETFD, existingFlags | FD_CLOEXEC) >= 0 else {
            Darwin.close(fd)
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
            Darwin.close(fd)
            return nil
        }

        watchedPID = pid
        descriptor = fd
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

    /// Closes the kqueue descriptor. Idempotent.
    func close() {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        Darwin.close(fd)
    }

    private func latchUnknown() -> PollResult {
        isLatched = true
        return .unknown
    }
}
