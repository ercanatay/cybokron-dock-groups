import os

// The process-wide bound on open process watches (one kqueue descriptor each), shared by
// `RunningApplicationIdentityVerifier` and `TriggerApplicationApprover`
// (docs/design/app-presence-watch-upgrade.md, "Implementation status (2026-11-06, approval)").

/// How many process watches may be open at once in this process, and how many are. Every watch
/// the verifier or the approver registers takes a slot here first; one that can't get a slot is
/// never registered (fail closed: the verifier answers `unavailable(.atCapacity)`, the approval
/// `checkFailed`), and the watches already open are left alone.
///
/// A slot is freed when its watch is closed (`ApplicationProcessWatching.close()`) or released.
/// A real watch with a started wake-up closes its descriptor in the read source's cancel handler,
/// on the main queue right after `close()` returns, so for that one main-queue turn the process
/// may hold a few more descriptors than open slots; never more than the bound plus the watches
/// closed in that turn.
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
    /// one `make` made and frees the slot (once) when it is closed or released.
    @MainActor
    func open(pid: Int32, with make: @MainActor (Int32) -> (any ApplicationProcessWatching)?) -> Opening {
        guard take() else { return .atCapacity }
        guard let watch = make(pid) else {
            free()
            return .unavailable
        }
        return .opened(BudgetedProcessWatch(watch, budget: self))
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

/// A watch that holds one slot of an `ApplicationProcessWatchBudget`: it forwards every call and
/// frees the slot the first time it is closed, or when it is released unclosed.
private final class BudgetedProcessWatch: ApplicationProcessWatching {
    private let watch: any ApplicationProcessWatching
    private let budget: ApplicationProcessWatchBudget
    private var holdsSlot = true

    init(_ watch: any ApplicationProcessWatching, budget: ApplicationProcessWatchBudget) {
        self.watch = watch
        self.budget = budget
    }

    deinit {
        close()
    }

    func poll() -> ExperimentalProcessEventWatchPollResult {
        watch.poll()
    }

    func close() {
        watch.close()
        guard holdsSlot else { return }
        holdsSlot = false
        budget.free()
    }

    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool {
        watch.startSignalling(handler)
    }
}
