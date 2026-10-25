import Foundation
import OSLog

/// What triggers are carried out with: the app's groups, its current group and its commands. The
/// coordinator always passes `TransitionTrigger.automation`, so nothing a trigger asks for quits
/// an app or asks a question (triggers spec §2.5).
@MainActor
public protocol AutomationHandling: AnyObject {
    func group(withID id: DockGroup.ID) -> DockGroup?
    /// The current group (`ContextSession.current`) and who started it.
    var currentGroupID: DockGroup.ID? { get }
    var currentGroupStartTrigger: TransitionTrigger? { get }
    /// Start; `nil` when it couldn't be started (the group is gone).
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport?
    /// Finish; `nil` when it couldn't be finished.
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport?
    func openAllItems(of group: DockGroup) async -> LaunchReport
    func showPopup(of group: DockGroup)
}

/// The notice before a trigger runs (spec §1.7).
public struct TriggerNotice: Hashable, Sendable {
    /// The notice's countdown.
    public static let countdown: Duration = .seconds(5)
    /// How long Ask First waits for an answer.
    public static let askFirstTimeout: Duration = .seconds(120)

    public let triggerID: GroupTrigger.ID
    public let groupID: DockGroup.ID
    public let groupName: String
    public let action: TriggerAction
    /// `.notice` (a countdown) or `.askFirst` (a question).
    public let runMode: TriggerRunMode
    /// The countdown, or how long the question waits.
    public let waits: Duration

    public init(triggerID: GroupTrigger.ID, groupID: DockGroup.ID, groupName: String, action: TriggerAction, runMode: TriggerRunMode) {
        self.triggerID = triggerID
        self.groupID = groupID
        self.groupName = groupName
        self.action = action
        self.runMode = runMode
        waits = runMode == .askFirst ? Self.askFirstTimeout : Self.countdown
    }
}

/// How a notice ended.
public enum TriggerNoticeAnswer: Hashable, Sendable {
    /// The countdown ended, or the user clicked Start Now (or Start).
    case run
    case notNow
    /// Ask First got no answer in time.
    case timedOut
    /// A newer firing took its place (`TriggerNoticePresenting.dismiss()`).
    case replaced
}

/// Shows the notice (the app's panel); tests answer for it.
@MainActor
public protocol TriggerNoticePresenting: AnyObject {
    /// Shows `notice` and returns once it's answered, counted down, timed out or dismissed.
    func present(_ notice: TriggerNotice) async -> TriggerNoticeAnswer
    /// Ends the notice showing now; its `present` returns `.replaced`.
    func dismiss()
}

/// Turns system signals into at most one action at a time (triggers spec §2.5), modeled on
/// `FocusRequestCoordinator`:
///
/// 1. Each signal is evaluated at once (`TriggerEvaluator`); its firings wait 2 seconds after the
///    last one (the settle), then are reduced (`TriggerReducer`) together with those still waiting.
/// 2. Each is carried out in turn: not while paused, not past the hourly budget (which pauses), not
///    for a group that's gone; Finish only for the current group, and a Start's own "Finish when it
///    ends" only when this trigger started it. The notice comes first unless the trigger runs
///    right away; without anyone to show it, nothing runs.
/// 3. Start, Finish, Open All and Show the Popup go to the handler with
///    `TransitionTrigger.automation`. Changes of displays and networks run nothing while an action
///    runs and for 15 seconds after it (the echo window).
///
/// Firings that come while the app isn't ready (no handler yet), or while the screens sleep or the
/// session isn't active, wait — up to the catch-up window. The state changes are handed to
/// `onStateChange` (the app saves them, `TriggerStateStore`). Nothing is polled.
@MainActor
public final class TriggerCoordinator {
    /// How long firings wait for more before they're reduced.
    public static let settleInterval: Duration = .seconds(2)
    /// How long after an automatic action changes run nothing.
    public static let echoInterval: TimeInterval = 15

    /// Carries the actions out; until it's set, firings wait.
    public weak var handler: AutomationHandling? {
        didSet { processIfNeeded() }
    }
    /// Shows the notices; without one, triggers that show a notice or ask first don't run.
    public weak var noticePresenter: TriggerNoticePresenting?
    /// Called with every changed state.
    public var onStateChange: ((TriggerState) -> Void)?

    public private(set) var state: TriggerState
    public private(set) var environment = TriggerEnvironment()

    private let rules: () -> [GroupTrigger]
    private let activeGroups: () -> Set<DockGroup.ID>
    private let sleeper: Sleeping
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// Firings settling.
    private var pending: [TriggerFiring] = []
    /// Reduced firings waiting their turn.
    private var queue: [TriggerFiring] = []
    /// The firing being carried out, and whether its notice is showing.
    private var current: TriggerFiring?
    private var isPresentingNotice = false
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    /// The trigger that started each group, while this app runs (never saved).
    private var startedBy: [DockGroup.ID: GroupTrigger.ID] = [:]

    /// - Parameters:
    ///   - rules: The triggers, in Settings → Triggers' order.
    ///   - activeGroups: The groups that aren't archived or deleted.
    public init(
        state: TriggerState,
        rules: @escaping () -> [GroupTrigger],
        activeGroups: @escaping () -> Set<DockGroup.ID>,
        sleeper: Sleeping? = nil,
        clock: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { Calendar.current }
    ) {
        self.state = state
        self.rules = rules
        self.activeGroups = activeGroups
        self.sleeper = sleeper ?? TaskSleeping()
        self.clock = clock
        self.calendar = calendar
    }

    /// Whether nothing is settling, waiting or being carried out.
    public var isIdle: Bool { settleTask == nil && processing == nil && pending.isEmpty && queue.isEmpty }

    /// The firings waiting to be carried out, in order.
    public var waitingFirings: [TriggerFiring] { queue }

    // MARK: - Rules

    /// Gives every trigger without remembered state its baseline. Call once at launch, before the
    /// first signal.
    public func start() {
        let now = clock()
        var state = TriggerEvaluator.baseline(rules: rules(), state: state, now: now, calendar: calendar())
        state = state.keepingEntries(of: Set(rules().map(\.id)))
        if let quiet = state.quietLaunchUntil, quiet <= now {
            state.quietLaunchUntil = nil
        }
        update(state)
    }

    /// The triggers changed from `previous`: new, re-enabled and changed ones start from a fresh
    /// baseline, and firings of triggers that are gone or off are dropped.
    public func rulesChanged(previous: [GroupTrigger]) {
        let current = rules()
        update(TriggerEvaluator.rebaseline(previous: previous, rules: current, state: state, now: clock(), calendar: calendar()))
        let runnable = Set(current.filter(\.canRun).map(\.id))
        pending.removeAll { !runnable.contains($0.triggerID) }
        queue.removeAll { !runnable.contains($0.triggerID) }
    }

    /// When the clock must look next (`TriggerEvaluator.nextDue`).
    public var nextDue: Date? {
        TriggerEvaluator.nextDue(rules: rules(), activeGroups: activeGroups(), after: clock(), calendar: calendar())
    }

    // MARK: - Pausing

    public var isPaused: Bool { state.isPaused(at: clock()) }

    /// Pause Triggers: nothing runs until the pause ends; what comes meanwhile is skipped.
    public func pause(_ length: TriggerPauseLength) {
        let now = clock()
        var state = state
        state.pause(until: length.end(from: now, calendar: calendar()), reason: .user)
        update(state)
        logger.notice("Triggers paused (\(length.rawValue, privacy: .public))")
    }

    public func resume() {
        var state = state
        state.resume()
        update(state)
        logger.notice("Triggers resumed")
    }

    /// Marks the next launches before `date` quiet (an update's or a language change's relaunch).
    public func markQuietLaunch(until date: Date) {
        var state = state
        state.quietLaunchUntil = date
        update(state)
    }

    /// How the coming launch counts: `.quiet` while the quiet-launch marker holds.
    public func launchKind(_ kind: LaunchKind) -> LaunchKind {
        guard let quiet = state.quietLaunchUntil, clock() < quiet else { return kind }
        return .quiet
    }

    // MARK: - Signals

    /// A system source reported `signal`.
    public func receive(_ signal: TriggerSignal) {
        let evaluation = TriggerEvaluator.evaluate(
            signal,
            rules: rules(),
            state: state,
            environment: environment,
            activeGroups: activeGroups(),
            now: clock(),
            calendar: calendar()
        )
        environment = evaluation.environment
        if case .launched = signal, state.quietLaunchUntil != nil {
            var settled = evaluation.state
            settled.quietLaunchUntil = nil
            update(settled)
        } else {
            update(evaluation.state)
        }
        if !evaluation.firings.isEmpty {
            for firing in evaluation.firings {
                logger.notice("Trigger \(firing.triggerID, privacy: .public) asks to \(firing.action.rawValue, privacy: .public) group \(firing.groupID, privacy: .public)")
            }
            pending += evaluation.firings
            restartSettle()
        }
        // The screens woke or the session came back: what waited can go on.
        processIfNeeded()
    }

    private func restartSettle() {
        generation += 1
        let current = generation
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper.sleep(for: Self.settleInterval)
            } catch {
                return
            }
            guard current == self.generation else { return }
            self.settleTask = nil
            self.settled()
        }
    }

    private func settled() {
        let batch = pending
        pending = []
        let reduction = TriggerReducer.reduce(queue + batch)
        var state = state
        for skip in reduction.skipped {
            state.record(.skipped(skip.reason), for: skip.firing.triggerID, at: skip.firing.occurrence)
            logger.notice("Trigger \(skip.firing.triggerID, privacy: .public) skipped: \(skip.reason.rawValue, privacy: .public)")
        }
        update(state)
        queue = reduction.run
        // A newer Start takes the place of one whose notice is showing.
        if isPresentingNotice, let current, current.action == .start,
           let start = queue.first(where: { $0.action == .start }), start.occurrence >= current.occurrence, start.triggerID != current.triggerID {
            noticePresenter?.dismiss()
        }
        processIfNeeded()
    }

    // MARK: - Carrying out

    /// Whether `firing` can be carried out now. A trigger on the screens going to sleep runs while
    /// they sleep — after they wake it would be too late for what it's for; everything else waits
    /// for the screens to wake and the session to be active.
    private func canCarryOut(_ firing: TriggerFiring) -> Bool {
        if environment.canAct { return true }
        return environment.sessionActive && runsWhileScreensSleep(firing)
    }

    private func runsWhileScreensSleep(_ firing: TriggerFiring) -> Bool {
        guard let trigger = rules().first(where: { $0.id == firing.triggerID }), case .screensSleep = trigger.event else { return false }
        return true
    }

    private func processIfNeeded() {
        guard processing == nil, let next = queue.first, handler != nil, canCarryOut(next) else { return }
        processing = Task { @MainActor [weak self] in
            await self?.processQueue()
            self?.processing = nil
            // More may have come while the last one ran.
            self?.processIfNeeded()
        }
    }

    private func processQueue() async {
        while let next = queue.first, handler != nil, canCarryOut(next) {
            let firing = queue.removeFirst()
            current = firing
            await carryOut(firing)
            current = nil
        }
    }

    private func carryOut(_ firing: TriggerFiring) async {
        guard let handler else {
            queue.insert(firing, at: 0)
            return
        }
        guard let trigger = rules().first(where: { $0.id == firing.triggerID }), trigger.canRun else {
            logger.notice("Trigger \(firing.triggerID, privacy: .public) is gone or off: nothing done")
            return
        }
        guard clock().timeIntervalSince(firing.occurrence) <= TriggerEvaluator.catchUpWindow else {
            var state = state
            state.record(.missed(.macAsleep), for: trigger.id, at: firing.occurrence)
            update(state)
            return
        }
        if let reason = blocker(for: firing, trigger: trigger, handler: handler) {
            skip(firing, reason)
            return
        }
        guard let group = handler.group(withID: firing.groupID) else { return }

        // Nobody can answer a notice while the screens sleep: a trigger on them going to sleep runs
        // right away (it can only finish — hide — the current group).
        let runMode: TriggerRunMode = runsWhileScreensSleep(firing) ? .immediately : trigger.runMode
        switch runMode {
        case .immediately:
            break
        case .notice, .askFirst:
            guard let presenter = noticePresenter else {
                logger.error("Trigger \(trigger.id, privacy: .public) needs a notice and none can be shown: nothing done")
                skip(firing, .noAnswer)
                return
            }
            isPresentingNotice = true
            let answer = await presenter.present(TriggerNotice(triggerID: trigger.id, groupID: group.id, groupName: group.name, action: firing.action, runMode: runMode))
            isPresentingNotice = false
            switch answer {
            case .run: break
            case .notNow: skip(firing, .notNow); return
            case .timedOut: skip(firing, .noAnswer); return
            case .replaced: skip(firing, .anotherTrigger); return
            }
            // A notice takes seconds: the group, the pause and the current group are looked at again.
            guard let stillHandler = self.handler else {
                queue.insert(firing, at: 0)
                return
            }
            if let reason = blocker(for: firing, trigger: trigger, handler: stillHandler) {
                skip(firing, reason)
                return
            }
        }
        guard let handler = self.handler, let group = handler.group(withID: firing.groupID) else {
            skip(firing, .groupMissing)
            return
        }
        await run(firing, trigger: trigger, group: group, handler: handler)
    }

    /// Why `firing` can't run now, or `nil`.
    private func blocker(for firing: TriggerFiring, trigger: GroupTrigger, handler: AutomationHandling) -> TriggerSkipReason? {
        let now = clock()
        if state.isPaused(at: now) { return .paused }
        guard activeGroups().contains(firing.groupID), handler.group(withID: firing.groupID) != nil else { return .groupMissing }
        if !TriggerBudget.allows(state.recentRuns, now: now) {
            var state = state
            state.pause(until: now.addingTimeInterval(TriggerBudget.pauseLength), reason: .budget)
            update(state)
            logger.error("Triggers ran \(TriggerBudget.maximumPerHour) times in an hour: paused for an hour")
            return .budget
        }
        if firing.action == .finish {
            guard handler.currentGroupID == firing.groupID else { return .notCurrentGroup }
            if firing.isFinishWhenEnded {
                guard handler.currentGroupStartTrigger == .automation, startedBy[firing.groupID] == trigger.id else { return .notStartedByTrigger }
            }
        }
        return nil
    }

    private func run(_ firing: TriggerFiring, trigger: GroupTrigger, group: DockGroup, handler: AutomationHandling) async {
        environment.echoUntil = .distantFuture
        var outcome: TriggerOutcome = .ran(firing.action)
        switch firing.action {
        case .start:
            if let report = await handler.startGroup(group.id, trigger: .automation) {
                if report.outcome == .repeated {
                    outcome = .skipped(.alreadyDone)
                } else {
                    startedBy[group.id] = trigger.id
                }
            } else {
                outcome = .skipped(.groupMissing)
            }
        case .finish:
            if await handler.finishGroup(group.id, trigger: .automation, showsPrevious: true) != nil {
                startedBy[group.id] = nil
            } else {
                outcome = .skipped(.groupMissing)
            }
        case .openAll:
            _ = await handler.openAllItems(of: group)
        case .showPopup:
            handler.showPopup(of: group)
        }
        let end = clock()
        environment.echoUntil = end.addingTimeInterval(Self.echoInterval)
        var state = state
        if case .ran(let action) = outcome {
            state.recordRun(action, for: trigger.id, at: end)
            logger.notice("Trigger \(trigger.id, privacy: .public) (\(trigger.event.kindName, privacy: .public)) did \(action.rawValue, privacy: .public) for group \(group.id, privacy: .public)")
        } else {
            state.record(outcome, for: trigger.id, at: end)
        }
        update(state)
    }

    private func skip(_ firing: TriggerFiring, _ reason: TriggerSkipReason) {
        var state = state
        state.record(.skipped(reason), for: firing.triggerID, at: firing.occurrence)
        update(state)
        logger.notice("Trigger \(firing.triggerID, privacy: .public) skipped: \(reason.rawValue, privacy: .public)")
    }

    private func update(_ newState: TriggerState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
