import os

// The process-wide bound on open process watches (one kqueue descriptor each), shared by
// `RunningApplicationIdentityVerifier` and `TriggerApplicationApprover`
// (docs/design/app-presence-watch-upgrade.md, "Implementation status (2026-11-06, approval)").

/// How many process watches may be open at once in this process, and how many are. Every watch
/// the verifier or the approver registers takes a slot here first; one that can't get a slot is
/// never registered (fail closed: the verifier answers `unavailable(.atCapacity)`, the approval
/// `checkFailed`), and the watches already open are left alone.
///
/// A slot is taken before the watch's descriptor is opened and freed only once that descriptor is
/// really closed (`ApplicationProcessWatching.whenDescriptorClosed`), not when `close()` returns: a
/// real watch with a started wake-up closes its descriptor in the read source's cancel handler, on
/// the main queue after `close()`, and its slot stays taken until then. So the process never holds
/// more watch descriptors than `limit`; a slot freed late only makes the bound fail closed
/// (`atCapacity`) a main-queue turn longer.
///
/// Thread-safe (the count is behind a lock), so a slot can be freed from a `deinit`.
final class ApplicationProcessWatchBudget: Sendable {
    /// The one bound for the whole process.
    static let processLimit = 64
    /// What the verifier and the approver use unless a test gives them their own.
    static let shared = ApplicationProcessWatchBudget(limit: processLimit)

    let limit: Int
    private let used = OSAllocatedUnfairLock(initialState: 0)

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Slots taken now.
    var openCount: Int { used.withLock { $0 } }

    /// Slots free now.
    var available: Int { limit - openCount }

    /// What opening a watch did.
    enum Opening {
        /// A registered watch holding one slot until it is closed.
        case opened(any ApplicationProcessWatching)
        /// Every slot is taken; nothing was registered.
        case atCapacity
        /// `make` couldn't register a watch; its slot is free again.
        case unavailable
    }

    /// Takes a slot, then registers a watch on `pid` with `make`. The watch handed back closes the
    /// one `make` made when it is closed or released, and frees the slot once, when that watch's
    /// descriptor is closed.
    @MainActor
    func open(pid: Int32, with make: @MainActor (Int32) -> (any ApplicationProcessWatching)?) -> Opening {
        guard take() else { return .atCapacity }
        guard let watch = make(pid) else {
            free()
            return .unavailable
        }
        return .opened(BudgetedProcessWatch(watch, slot: Slot(budget: self)))
    }

    private func take() -> Bool {
        used.withLock { used in
            guard used < limit else { return false }
            used += 1
            return true
        }
    }

    fileprivate func free() {
        used.withLock { used in
            // Never below zero: a slot is freed once per taken slot (`BudgetedProcessWatch`).
            used = max(0, used - 1)
        }
    }
}

/// One taken slot of an `ApplicationProcessWatchBudget`, freed the first time `free()` is called;
/// later calls do nothing. Thread-safe: it is freed where the descriptor is closed.
private final class Slot: Sendable {
    private let budget: ApplicationProcessWatchBudget
    private let held = OSAllocatedUnfairLock(initialState: true)

    init(budget: ApplicationProcessWatchBudget) {
        self.budget = budget
    }

    func free() {
        let wasHeld = held.withLock { held in
            defer { held = false }
            return held
        }
        if wasHeld { budget.free() }
    }
}

/// A watch that holds one slot of an `ApplicationProcessWatchBudget`: it forwards every call,
/// closes the watch it wraps when closed or released, and frees the slot when that watch reports
/// its descriptor closed (once, however often that is reported).
private final class BudgetedProcessWatch: ApplicationProcessWatching {
    private let watch: any ApplicationProcessWatching
    /// The caller's own `whenDescriptorClosed` action, run after the slot is freed.
    private let descriptorClosed = DescriptorClosedNotice()

    init(_ watch: any ApplicationProcessWatching, slot: Slot) {
        self.watch = watch
        let descriptorClosed = descriptorClosed
        watch.whenDescriptorClosed {
            slot.free()
            descriptorClosed.fire()
        }
    }

    deinit {
        watch.close()
    }

    func poll() -> ExperimentalProcessEventWatchPollResult {
        watch.poll()
    }

    func close() {
        watch.close()
    }

    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool {
        watch.startSignalling(handler)
    }

    /// The slot is freed whatever is set here.
    func whenDescriptorClosed(_ action: @escaping @Sendable () -> Void) {
        descriptorClosed.set(action)
    }
}
