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
    private var currentInvalidated = false  // stays true until the next firing clears it
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    /// The trigger that started each group, while this app runs (never saved).
    private var startedBy: [DockGroup.ID: GroupTrigger.ID] = [:]
    private var applicationTracker = AppPresenceRuleTracker()

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

    // MARK: - Application presence observations

    public func beginApplicationObservations(generation: UInt64) -> Bool {
        guard environment.canAct else { return false }
        guard refresh() else { return false }
        guard applicationTracker.beginGeneration(generation) else { return false }
        // A new generation replaces the previous one: its presence firings no longer count.
        invalidateApplicationPresenceFirings()
        return true
    }

    public func observeApplications(generation: UInt64, sequence: UInt64, counts: [String: Int]) {
        guard environment.canAct else {
            stopApplicationTracker()
            return
        }
        guard refresh() else { return }
        let observation = applicationTracker.observeDetailed(generation: generation, sequence: sequence, counts: counts)
        if observation.isUncertain {
            // Fail closed: drop presence firings (queued, pending, awaiting notice) but keep
            // observing and leave other triggers' firings alone. Baselines are already reset.
            invalidateApplicationPresenceFirings()
            processIfNeeded()
            return
        }
        let ids = observation.firedRuleIDs
        let originalRules = rules()
        let observedRevision = applicationTracker.revision
        func currentRule(for id: UUID) -> GroupTrigger? {
            guard applicationTracker.isCurrent(revision: observedRevision) else { return nil }
            guard refresh() else { return nil }
            guard environment.canAct else { return nil }
            guard applicationTracker.isActive(generation: generation) else { return nil }
            let currentRules = rules()
            guard let current = currentRules.first(where: { $0.id == id }) else { return nil }
            guard let original = originalRules.first(where: { $0.id == id }) else { return nil }
            guard current == original else { return nil }
            guard current.canRun else { return nil }
            guard activeGroups().contains(current.groupID) else { return nil }
            return current
        }
        for id in ids {
            guard let current = currentRule(for: id) else { break }
            guard case .applicationPresence(_, let edge) = current.event else { break }
            // The validity check runs inside receive(), after the state update and its reentrant
            // callbacks but before this delivery's firings are enqueued, so a stale firing is never
            // enqueued and a valid nested newer firing (same trigger ID) is never touched. The stamp
            // is checked again right before the firing is carried out.
            let stamp = ApplicationPresenceStamp(generation: generation, revision: observedRevision, rule: current)
            receive(.applicationEdge(triggerID: id, edge: edge), presence: (stamp, {
                self.applicationTracker.isCurrent(revision: observedRevision) && currentRule(for: id) != nil
            }))
            // Stop delivering the rest of this (now stale) observation.
            if !applicationTracker.isCurrent(revision: observedRevision) || currentRule(for: id) == nil {
                break
            }
        }
    }

    public func stopApplicationObservations() {
        stopApplicationTracker()
    }

    public func cancelApplicationPresenceForPolicyChange() {
        stopApplicationTracker()
    }

    /// Every path that stops the tracker comes here: a stopped tracker makes every presence firing
    /// stale, so they are dropped at once (carry-out would refuse them anyway, see
    /// `isApplicationPresenceFiringCurrent`).
    private func stopApplicationTracker() {
        applicationTracker.stop()
        invalidateApplicationPresenceFirings()
    }

    /// Whether `firing` may still be carried out. Other triggers' firings always may. An
    /// application-presence firing only while the tracker still runs the generation and revision
    /// of its observation, its rule is unchanged and can run, its group is active and the Mac can
    /// act. Checked by the coordinator itself, so a stop path that forgot to invalidate can't let a
    /// stale firing run.
    private func isApplicationPresenceFiringCurrent(_ firing: TriggerFiring) -> Bool {
        guard firing.isApplicationPresence else { return true }
        guard let stamp = firing.presenceStamp else { return false }
        guard environment.canAct else { return false }
        guard applicationTracker.isActive(generation: stamp.generation),
              applicationTracker.isCurrent(revision: stamp.revision) else { return false }
        guard let rule = rules().first(where: { $0.id == firing.triggerID }), rule == stamp.rule, rule.canRun else { return false }
        return activeGroups().contains(rule.groupID)
    }

    /// Drops the presence firings that are pending or queued but no longer current.
    private func dropStaleApplicationPresenceFirings() {
        pending.removeAll { !isApplicationPresenceFiringCurrent($0) }
        queue.removeAll { !isApplicationPresenceFiringCurrent($0) }
    }

    /// Drops every application-presence firing that is pending, queued or awaiting its notice.
    /// Firings keep their original origin flag; other triggers' firings are untouched.
    private func invalidateApplicationPresenceFirings() {
        pending.removeAll { $0.isApplicationPresence }
        queue.removeAll { $0.isApplicationPresence }
        if isPresentingNotice, let currentFiring = current, currentFiring.isApplicationPresence {
            currentInvalidated = true
            noticePresenter?.dismiss()
        }
    }

    private func refresh() -> Bool {
        let currentRules = rules()
        let active = activeGroups()
        var eligible: [AppPresenceRuleTracker.Rule] = []
        for trigger in currentRules {
            guard trigger.canRun else { continue }
            guard case .applicationPresence(let bundleID, let edge) = trigger.event else { continue }
            guard active.contains(trigger.groupID) else { continue }
            guard let identifier = TriggerApplicationIdentifier(bundleID) else {
                stopApplicationTracker()
                return false
            }
            eligible.append(.init(id: trigger.id, identifier: identifier, edge: edge))
        }
        let ok = applicationTracker.configure(eligible)
        if eligible.isEmpty || !ok {
            stopApplicationTracker()
            return false
        }
        return true
    }

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
    /// baseline; firings of changed, gone or off triggers are dropped.
    public func rulesChanged(previous: [GroupTrigger]) {
        let nowRules = rules()
        if previous != nowRules {
            stopApplicationTracker()
        }
        update(TriggerEvaluator.rebaseline(previous: previous, rules: nowRules, state: state, now: clock(), calendar: calendar()))
        let currentByID = Dictionary(nowRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func invalidated(_ firing: TriggerFiring) -> Bool {
            guard let nowRule = currentByID[firing.triggerID] else { return true }
            if !nowRule.canRun { return true }
            guard let oldRule = previousByID[firing.triggerID] else { return true }
            return oldRule != nowRule
        }
        pending.removeAll { invalidated($0) }
        queue.removeAll { invalidated($0) }
        if isPresentingNotice, let currentFiring = current, invalidated(currentFiring) {
            currentInvalidated = true
            noticePresenter?.dismiss()
        }
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

    /// A system source reported `signal`. `.applicationEdge` is ignored here: application edges come
    /// only from `observeApplications`, which checks the tracker generation and revision.
    public func receive(_ signal: TriggerSignal) {
        if case .applicationEdge = signal {
            logger.error("An application edge was sent outside the presence tracker: ignored")
            return
        }
        receive(signal, presence: nil)
    }

    /// - Parameter presence: For an edge from `observeApplications`: the stamp its firings carry,
    ///   and a check evaluated after the state update (and any reentrant callbacks it caused) and
    ///   right before the firings are enqueued; when it returns `false`, only the
    ///   application-presence firings of this delivery are dropped. Without it, application-presence
    ///   firings are never enqueued.
    private func receive(_ signal: TriggerSignal, presence: (stamp: ApplicationPresenceStamp, isValid: () -> Bool)?) {
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
        // If the screens go to sleep or the session stops being active, drop any waiting
        // application-presence firings and invalidate an awaiting notice.
        let shouldInvalidate: Bool
        switch signal {
        case .screens(asleep: true), .session(active: false): shouldInvalidate = true
        default: shouldInvalidate = false
        }
        if shouldInvalidate {
            // Removes only firings that were originally applicationPresence.
            stopApplicationTracker()
        }
        var firings = evaluation.firings
        if let presence, !firings.isEmpty, presence.isValid() {
            firings = firings.map { firing in
                guard firing.isApplicationPresence else { return firing }
                var stamped = firing
                stamped.presenceStamp = presence.stamp
                return stamped
            }
        } else {
            firings.removeAll { $0.isApplicationPresence }
        }
        if !firings.isEmpty {
            for firing in firings {
                logger.notice("Trigger \(firing.triggerID, privacy: .public) asks to \(firing.action.rawValue, privacy: .public) group \(firing.groupID, privacy: .public)")
            }
            pending += firings
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
        // A stale presence firing must not win the reduction over a firing that can still run.
        dropStaleApplicationPresenceFirings()
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
            currentInvalidated = false
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
        // Like a push invalidation of a queued firing: dropped without a recorded outcome.
        guard isApplicationPresenceFiringCurrent(firing) else {
            logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated application observation: nothing done")
            dropStaleApplicationPresenceFirings()
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
            // No notice for a firing the checks above made stale.
            guard isApplicationPresenceFiringCurrent(firing) else {
                logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated application observation: nothing done")
                dropStaleApplicationPresenceFirings()
                return
            }
            isPresentingNotice = true
            let answer = await presenter.present(TriggerNotice(triggerID: trigger.id, groupID: group.id, groupName: group.name, action: firing.action, runMode: runMode))
            isPresentingNotice = false
            switch answer {
            case .run:
                break
            case .notNow: skip(firing, .notNow); return
            case .timedOut: skip(firing, .noAnswer); return
            case .replaced: skip(firing, .anotherTrigger); return
            }
            guard !currentInvalidated else {
                skip(firing, .anotherTrigger)
                return
            }
            guard let currentRule = rules().first(where: { $0.id == firing.triggerID }), currentRule.canRun, currentRule == trigger else {
                skip(firing, .anotherTrigger)
                return
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
        // The last look before the handler is called (no suspension point until then): the checks
        // above may have called out (state changes, the handler), so the observation is looked at
        // again. An action that already started is not undone.
        guard isApplicationPresenceFiringCurrent(firing) else {
            logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated application observation: nothing done")
            dropStaleApplicationPresenceFirings()
            if runMode != .immediately { skip(firing, .anotherTrigger) }
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
