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
    /// Whether it's for a change that happened while the Mac couldn't act ("run what was missed",
    /// `docs/design/app-presence-catch-up.md`), so the notice can say so.
    public let isCatchUp: Bool

    public init(triggerID: GroupTrigger.ID, groupID: DockGroup.ID, groupName: String, action: TriggerAction, runMode: TriggerRunMode, isCatchUp: Bool = false) {
        self.triggerID = triggerID
        self.groupID = groupID
        self.groupName = groupName
        self.action = action
        self.runMode = runMode
        self.isCatchUp = isCatchUp
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
///
/// A trigger with a delay (`GroupTrigger.delaySeconds`) is accepted as above — its notice answered,
/// if it shows one — and then waits, in memory only, without holding other triggers up. While it
/// waits, anything that makes it stale cancels it and records `.cancelledBeforeRun` (or a reason
/// that says more: paused, the budget, the group gone, the app's code not confirmed): its rule
/// changed or can't run, a newer firing of the same trigger came, the screen lock or the
/// application observation it came from changed, the screens slept or woke or the session changed.
/// When the delay is over every check is made again — with the cooldown, At most once a day and the
/// echo window — right before the action runs.
///
/// "Run what was missed" (`GroupTrigger.catchUp`, `docs/design/app-presence-catch-up.md`): for an
/// authorized application trigger with the option on, the last trusted reading (running or not)
/// before the Mac stops being able to act — system sleep, display sleep, another user's session —
/// is kept in memory only. The first trusted reading after the gap is compared with it: a net change
/// that is the trigger's own edge runs it once, through every gate an observed edge goes through,
/// and never right away. Not for gaps longer than 30 minutes (recorded missed), not past 3 per wake
/// (recorded missed), not when no trusted reading came within 60 seconds of the gap's end, not when
/// an automatic action started since the gap ended (recorded as the echo). Opens and closes that
/// cancel out during the gap can't be seen; an unknown reading is never "not running".
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
    /// Why the current firing was invalidated, when that isn't "another trigger" (its record).
    private var currentInvalidationReason: TriggerSkipReason?
    /// Whether this settle was already put off once for a running identity check.
    private var settleWaitedForIdentityCheck = false
    /// A requested restart of the application observations, not yet passed on.
    private var observationRestart: Task<Void, Never>?
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    /// The trigger that started each group, while this app runs (never saved).
    private var startedBy: [DockGroup.ID: GroupTrigger.ID] = [:]
    /// Accepted firings waiting for their trigger's delay, in the order they were accepted; never saved.
    private var delayed: [DelayedFiring] = []
    private var delayToken: UInt64 = 0
    /// Count every change of the screens sleeping (and every report that they sleep: a repeat is the
    /// Mac going to sleep) and of the session being active: a delayed firing is carried out only
    /// while they're the ones it was accepted with.
    private var screensRevision: UInt64 = 0
    private var sessionRevision: UInt64 = 0
    private var isCheckingDelayed = false
    /// Called whenever a firing starts or stops waiting for its delay (`delayedUntil`).
    public var onDelayedFiringsChange: (() -> Void)?
    private var applicationTracker = AppPresenceRuleTracker()
    /// Confirms that the code running under an authorized application rule's identifier is the
    /// authorized code. By default it never confirms anything, so authorized rules don't act (fail
    /// closed); the app puts in `RunningApplicationIdentityVerifier`
    /// (`verifyRunningApplicationIdentities()`), tests their own.
    var applicationIdentityVerifier: any ApplicationIdentityVerifying = UnavailableApplicationIdentityVerifier() {
        didSet {
            applicationIdentityVerifier.setVerdictsChangedHandler { [weak self] in
                self?.applicationIdentityVerdictsChanged()
            }
        }
    }
    /// The running code under these authorized application triggers' identifier isn't the code
    /// they were approved for: the app saves each one as needing re-approval
    /// (`TriggerStore.requireApplicationReapproval(for:)`). Trust is never widened.
    public var onApplicationIdentityCodeChanged: (([GroupTrigger.ID]) -> Void)?
    /// The application observations must start again under a new generation (the verifier's
    /// verdicts changed which rules are observed); the app resets its presence source.
    public var onApplicationObservationsNeedRestart: (() -> Void)?

    // MARK: Run what was missed (memory only, never saved)

    /// The longest gap whose net change still runs (D2): the same 30 minutes as times.
    public static let catchUpLongestGap: TimeInterval = TriggerEvaluator.catchUpWindow
    /// The most catch-up firings one wake lets into the settle (D3); the rest are recorded missed.
    public static let catchUpLimitPerWake = 3
    /// How long after the gap's end the kept readings wait for a trusted reading (D3).
    public static let catchUpReadingWait: TimeInterval = 60

    /// A trusted reading of an application rule that catches up, and the rule as it was read.
    private struct CatchUpReading {
        let rule: GroupTrigger
        let isRunning: Bool
    }

    /// The readings kept across a gap.
    private struct CatchUpGap {
        /// When the Mac stopped being able to act.
        let start: Date
        /// What the gap was, for a `missed` record.
        let reason: TriggerMissReason
        let readings: [GroupTrigger.ID: CatchUpReading]
        /// When it could act again; `nil` while the gap lasts.
        var end: Date?
    }

    /// The last readings of the current observation (`trustedReadingsStamp`), of the rules that
    /// catch up (`recordTrustedReadings`).
    private var trustedReadings: [GroupTrigger.ID: CatchUpReading] = [:]
    private var trustedReadingsStamp: (generation: UInt64, revision: UInt64)?
    private var catchUpGap: CatchUpGap?
    /// When the last automatic action started: a comparison after a gap is void once one started
    /// since the gap ended (it may have opened the app itself).
    private var automaticActionStartedAt: Date?

    /// How many rules' readings wait for the first trusted reading after a gap (for tests).
    var catchUpReadingCount: Int { catchUpGap?.readings.count ?? 0 }

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

    /// Whether nothing is settling, waiting (for its turn or its delay) or being carried out.
    public var isIdle: Bool { settleTask == nil && processing == nil && pending.isEmpty && queue.isEmpty && delayed.isEmpty }

    /// When each trigger waiting for its delay is due, for the trigger rows.
    public var delayedUntil: [GroupTrigger.ID: Date] {
        Dictionary(delayed.map { ($0.firing.triggerID, $0.due) }, uniquingKeysWith: min)
    }

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

    /// What `observeApplications` did with a snapshot, so a UI status can follow the coordinator's
    /// decision instead of guessing it.
    public enum ApplicationObservationOutcome: Equatable, Sendable {
        /// Rejected (stale generation, old or repeated sequence): nothing changed.
        case rejected
        /// The tracker stopped (the Mac can't act, or the rules can't be tracked): the state is unknown.
        case stopped
        /// Accepted; `isUncertain` when macOS couldn't identify every running app.
        case accepted(isUncertain: Bool)
    }

    @discardableResult
    public func observeApplications(generation: UInt64, sequence: UInt64, counts: [String: Int]) -> ApplicationObservationOutcome {
        guard environment.canAct else {
            stopApplicationTracker()
            return .stopped
        }
        guard refresh() else { return .stopped }
        let observation = applicationTracker.observeDetailed(generation: generation, sequence: sequence, counts: counts)
        guard observation.isAccepted else { return .rejected }
        if observation.isUncertain {
            // Fail closed: drop presence firings (queued, pending, awaiting notice) but keep
            // observing and leave other triggers' firings alone. Baselines are already reset, and
            // no reading before this one is trusted for catching up. Readings kept across a gap
            // wait (bounded by `catchUpReadingWait`).
            trustedReadings = [:]
            trustedReadingsStamp = nil
            invalidateApplicationPresenceFirings()
            processIfNeeded()
            return .accepted(isUncertain: true)
        }
        let ids = observation.firedRuleIDs
        // The verifier lists the instances itself: one that disagrees with this snapshot confirms
        // nothing for the rules that fired.
        for rule in rules() where ids.contains(rule.id) {
            guard rule.applicationIdentityStatus == .authorized, let binding = rule.applicationIdentity?.binding else { continue }
            guard case .applicationPresence(let bundleID, _) = rule.event, let count = counts[bundleID.lowercased()] else { continue }
            applicationIdentityVerifier.confirmObservedInstanceCount(count, for: binding)
        }
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
            // An unverified rule still goes through: the evaluator records why its action is skipped.
            guard applicationIdentityClearance(of: current) != .none else { return nil }
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
        catchUpAfterGap(generation: generation, revision: observedRevision, counts: counts, edgeRuleIDs: Set(ids))
        recordTrustedReadings(generation: generation, revision: observedRevision, counts: counts)
        return .accepted(isUncertain: false)
    }

    public func stopApplicationObservations() {
        stopApplicationTracker()
    }

    /// The session-only "identified apps only" option changed: what was read before isn't
    /// compared with what is read after it.
    public func cancelApplicationPresenceForPolicyChange() {
        catchUpGap = nil
        stopApplicationTracker()
    }

    // MARK: - Run what was missed

    /// Keeps the readings of the rules that catch up from `counts`, a trusted snapshot of the
    /// current generation and revision: only authorized rules (D8) with the option on that can run
    /// in an active group, and whose running code is verified or being checked. A reading becomes
    /// trusted only once the code is verified: `beginCatchUpGap` keeps it only if the verdict is
    /// `verified` then (the verifier forgets every verdict at each gap, so it was confirmed since).
    private func recordTrustedReadings(generation: UInt64, revision: UInt64, counts: [String: Int]) {
        trustedReadings = [:]
        trustedReadingsStamp = nil
        guard environment.canAct, applicationTracker.isActive(generation: generation), applicationTracker.isCurrent(revision: revision) else { return }
        let active = activeGroups()
        var readings: [GroupTrigger.ID: CatchUpReading] = [:]
        for rule in rules() where rule.catchesUp && rule.canRun && active.contains(rule.groupID) {
            guard rule.applicationIdentityStatus == .authorized else { continue }
            switch applicationIdentityClearance(of: rule) {
            case .allActions, .awaitingVerification: break
            case .showPopupOnly, .none: continue
            }
            guard case .applicationPresence(let bundleID, _) = rule.event, let count = counts[bundleID.lowercased()], count >= 0 else { continue }
            readings[rule.id] = CatchUpReading(rule: rule, isRunning: count > 0)
        }
        guard !readings.isEmpty else { return }
        trustedReadings = readings
        trustedReadingsStamp = (generation, revision)
    }

    /// The Mac stopped being able to act (D5: system sleep, display sleep, another user's
    /// session): the last trusted readings, if still those of the running observation, are kept
    /// for the first trusted reading after the gap. A gap still waiting for its reading goes on.
    private func beginCatchUpGap(reason: TriggerMissReason) {
        let now = clock()
        var kept: [GroupTrigger.ID: CatchUpReading] = [:]
        if let stamp = trustedReadingsStamp,
           applicationTracker.isActive(generation: stamp.generation),
           applicationTracker.isCurrent(revision: stamp.revision) {
            let current = Dictionary(rules().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let active = activeGroups()
            kept = trustedReadings.filter { id, reading in
                guard let rule = current[id], rule == reading.rule, rule.canRun, active.contains(rule.groupID),
                      let binding = rule.applicationIdentity?.binding
                else { return false }
                return applicationIdentityVerifier.displayedVerdict(for: binding) == .verified
            }
        }
        trustedReadings = [:]
        trustedReadingsStamp = nil
        if !kept.isEmpty {
            catchUpGap = CatchUpGap(start: now, reason: reason, readings: kept)
        } else if var gap = catchUpGap, let end = gap.end {
            // Woke and slept again before a trusted reading came: the same gap goes on, unless its
            // readings already waited too long.
            let waited = now.timeIntervalSince(end)
            if waited >= 0, waited <= Self.catchUpReadingWait {
                gap.end = nil
                catchUpGap = gap
            } else {
                catchUpGap = nil
            }
        }
    }

    /// The Mac can act again: the kept readings wait for the first trusted reading.
    private func endCatchUpGap() {
        guard catchUpGap != nil else { return }
        catchUpGap?.end = clock()
    }

    /// The first trusted reading after a gap: compared with the readings kept before it, at most
    /// one firing per rule, its own edge only (D10), each through every gate (`receive`). The kept
    /// readings are used up whatever happens.
    private func catchUpAfterGap(generation: UInt64, revision: UInt64, counts: [String: Int], edgeRuleIDs: Set<UUID>) {
        guard let gap = catchUpGap, let end = gap.end else { return }
        catchUpGap = nil
        let now = clock()
        let waited = now.timeIntervalSince(end)
        let length = end.timeIntervalSince(gap.start)
        // A clock that went back can't tell how long anything took: nothing is compared.
        guard waited >= 0, waited <= Self.catchUpReadingWait, length >= 0 else {
            logger.notice("Readings kept across a gap expired: nothing caught up")
            return
        }
        // An automatic action that started since the gap ended (or still runs) may have opened
        // the app itself: the change isn't attributed to the gap.
        let isVoid = environment.echoUntil == .distantFuture || (automaticActionStartedAt.map { $0 >= end } ?? false)
        var accepted = 0
        for rule in rules() {
            guard let kept = gap.readings[rule.id] else { continue }
            // The observation went stale meanwhile (a firing's state change re-entered): stop.
            guard environment.canAct, applicationTracker.isActive(generation: generation), applicationTracker.isCurrent(revision: revision) else { return }
            guard rule == kept.rule, rule.catchesUp, rule.canRun, activeGroups().contains(rule.groupID),
                  rule.applicationIdentityStatus == .authorized, applicationIdentityClearance(of: rule) != .none
            else { continue }
            guard case .applicationPresence(let bundleID, let edge) = rule.event,
                  let count = counts[bundleID.lowercased()], count >= 0
            else { continue }
            // An edge this observation already delivered is not run twice.
            guard !edgeRuleIDs.contains(rule.id) else { continue }
            let isRunning = count > 0
            guard isRunning != kept.isRunning, (isRunning ? TriggerEdge.starts : .ends) == edge else { continue }
            if isVoid {
                record(.skipped(.rightAfterAutomaticAction), for: rule.id, at: now)
                continue
            }
            guard length <= Self.catchUpLongestGap, accepted < Self.catchUpLimitPerWake else {
                record(.missed(gap.reason), for: rule.id, at: end)
                continue
            }
            let stamp = ApplicationPresenceStamp(generation: generation, revision: revision, rule: rule)
            let isValid = { [weak self] () -> Bool in
                guard let self else { return false }
                guard self.environment.canAct,
                      self.applicationTracker.isActive(generation: generation),
                      self.applicationTracker.isCurrent(revision: revision),
                      let current = self.rules().first(where: { $0.id == rule.id }), current == rule, current.canRun,
                      self.activeGroups().contains(current.groupID)
                else { return false }
                return self.applicationIdentityClearance(of: current) != .none
            }
            logger.notice("Trigger \(rule.id, privacy: .public) catches up a change while the Mac couldn't act")
            if receive(.applicationEdge(triggerID: rule.id, edge: edge), presence: (stamp, isValid), isCatchUp: true) {
                accepted += 1
            }
        }
    }

    private func record(_ outcome: TriggerOutcome, for id: GroupTrigger.ID, at date: Date) {
        var state = state
        state.record(outcome, for: id, at: date)
        update(state)
    }

    /// The Mac stopped or started being able to act (sleep, wake, a session change): the verifier
    /// forgets everything it confirmed (`ApplicationIdentityVerifying.reset()`), so no verified
    /// state outlives the gap, and every presence firing is dropped. Authorized rules then clear
    /// nothing until a fresh check confirms them. Call it before observations start again, so
    /// the new generation's `refresh()` asks a verifier that starts from nothing.
    public func resetApplicationIdentityVerification() {
        applicationIdentityVerifier.reset()
        invalidateApplicationPresenceFirings()
    }

    /// Checks authorized application triggers' running code with `RunningApplicationIdentityVerifier`
    /// (the app's production setting). Without this call no authorized trigger acts.
    public func verifyRunningApplicationIdentities() {
        applicationIdentityVerifier = RunningApplicationIdentityVerifier()
    }

    /// Whether an authorized application trigger's running code is, as last checked, not
    /// confirmed (never checked, a failed check, or different code), for the trigger lists. Starts
    /// no check. `false` for every other trigger, and while a check is under way.
    public func applicationIdentityIsUnconfirmed(_ trigger: GroupTrigger) -> Bool {
        guard trigger.applicationIdentityStatus == .authorized, let binding = trigger.applicationIdentity?.binding else { return false }
        switch applicationIdentityVerifier.displayedVerdict(for: binding) {
        case .verified?, .pending?: return false
        case .codeChanged?, .unavailable?, nil: return true
        }
    }

    /// The verifier's verdicts changed (it calls this when a check finishes with another answer):
    ///
    /// 1. Authorized rules whose code changed are saved as needing re-approval
    ///    (`onApplicationIdentityCodeChanged`, K2).
    /// 2. Presence firings that are no longer cleared are dropped (an authorized rule's whose code
    ///    isn't confirmed is recorded as skipped), and an awaiting notice of one is dismissed.
    /// 3. The tracker is configured with the rules the verdicts now let be observed; when it can't
    ///    go on with them, observations are restarted under a new generation
    ///    (`onApplicationObservationsNeedRestart`), so the old generation's observations are
    ///    rejected and nothing from them is replayed.
    func applicationIdentityVerdictsChanged() {
        let changed = rules().filter { rule in
            guard rule.applicationIdentityStatus == .authorized, let binding = rule.applicationIdentity?.binding else { return false }
            return applicationIdentityVerifier.displayedVerdict(for: binding) == .codeChanged
        }.map(\.id)
        if !changed.isEmpty {
            logger.notice("\(changed.count, privacy: .public) application trigger(s) need re-approval: the running code changed")
            onApplicationIdentityCodeChanged?(changed)
        }
        dropStaleApplicationPresenceFirings()
        if isPresentingNotice, !currentInvalidated, let currentFiring = current, currentFiring.isApplicationPresence {
            let check = applicationPresenceCheck(currentFiring)
            if check != .current {
                currentInvalidated = true
                currentInvalidationReason = check == .identityNotConfirmed ? .applicationNotConfirmed : nil
                noticePresenter?.dismiss()
            }
        }
        guard environment.canAct else { return }
        if refresh(), !applicationTracker.isObserving {
            requestObservationRestart()
        }
    }

    /// Passes a restart on once the current main-actor turn is done (it re-enters the coordinator),
    /// unless observations are running again by then.
    private func requestObservationRestart() {
        guard observationRestart == nil else { return }
        observationRestart = Task { @MainActor [weak self] in
            guard let self else { return }
            self.observationRestart = nil
            guard self.environment.canAct, !self.applicationTracker.isObserving else { return }
            self.onApplicationObservationsNeedRestart?()
        }
    }

    /// What an application rule may do now (`ApplicationIdentityClearance`).
    private func applicationIdentityClearance(of rule: GroupTrigger) -> ApplicationIdentityClearance {
        ApplicationIdentityClearance.of(rule, verifier: applicationIdentityVerifier)
    }

    /// Every path that stops the tracker comes here: a stopped tracker makes every presence firing
    /// stale, so they are dropped at once (carry-out would refuse them anyway, see
    /// `isApplicationPresenceFiringCurrent`).
    private func stopApplicationTracker() {
        applicationTracker.stop()
        // What the stopped observation read is no longer the last trusted reading; readings kept
        // across a gap stay (`beginCatchUpGap` took them before the stop).
        trustedReadings = [:]
        trustedReadingsStamp = nil
        invalidateApplicationPresenceFirings()
    }

    /// Whether `firing` may still be carried out. Other triggers' firings always may. An
    /// application-presence firing only while the tracker still runs the generation and revision
    /// of its observation, its rule is unchanged and can run, its application identity still clears
    /// its action (`ApplicationIdentityClearance`), its group is active and the Mac can act. Checked
    /// by the coordinator itself, so a stop path that forgot to invalidate can't let a stale firing
    /// run.
    private func isApplicationPresenceFiringCurrent(_ firing: TriggerFiring) -> Bool {
        applicationPresenceCheck(firing) == .current
    }

    private enum ApplicationPresenceCheck: Equatable {
        case current
        /// Outdated (generation, revision, rule, group, the Mac can't act) or not cleared: dropped
        /// without a record, as before.
        case stale
        /// Everything else holds, but the rule is authorized and its running code isn't confirmed
        /// (being checked, or the check failed): skipped and recorded
        /// (`TriggerSkipReason.applicationNotConfirmed`), so it neither vanishes silently nor looks
        /// as if it ran. Different code (`codeChanged`) isn't this: the rule then waits for
        /// re-approval, which its status line says.
        case identityNotConfirmed
    }

    private func applicationPresenceCheck(_ firing: TriggerFiring) -> ApplicationPresenceCheck {
        guard firing.isApplicationPresence else { return .current }
        guard let stamp = firing.presenceStamp else { return .stale }
        guard environment.canAct else { return .stale }
        guard applicationTracker.isActive(generation: stamp.generation),
              applicationTracker.isCurrent(revision: stamp.revision) else { return .stale }
        guard let rule = rules().first(where: { $0.id == firing.triggerID }), rule == stamp.rule, rule.canRun else { return .stale }
        guard activeGroups().contains(rule.groupID) else { return .stale }
        if applicationIdentityClearance(of: rule).permits(firing.action) { return .current }
        guard rule.applicationIdentityStatus == .authorized, let binding = rule.applicationIdentity?.binding,
              applicationIdentityVerifier.displayedVerdict(for: binding) != .codeChanged
        else { return .stale }
        return .identityNotConfirmed
    }

    /// Whether `firing` is an authorized rule's whose running code is being checked right now.
    private func isAwaitingIdentityCheck(_ firing: TriggerFiring) -> Bool {
        guard firing.isApplicationPresence, let rule = rules().first(where: { $0.id == firing.triggerID }) else { return false }
        return applicationIdentityClearance(of: rule) == .awaitingVerification
    }

    /// Drops the presence firings that are pending or queued but no longer current; those of
    /// authorized rules whose running code isn't confirmed are recorded as skipped.
    private func dropStaleApplicationPresenceFirings() {
        var unconfirmed: [TriggerFiring] = []
        func keeps(_ firing: TriggerFiring) -> Bool {
            switch applicationPresenceCheck(firing) {
            case .current: return true
            case .stale: return false
            case .identityNotConfirmed:
                unconfirmed.append(firing)
                return false
            }
        }
        pending = pending.filter(keeps)
        queue = queue.filter(keeps)
        for firing in unconfirmed {
            skip(firing, .applicationNotConfirmed)
        }
        checkDelayedFirings()
    }

    /// Drops every application-presence firing that is pending, queued or awaiting its notice.
    /// Firings keep their original origin flag; other triggers' firings are untouched.
    private func invalidateApplicationPresenceFirings() {
        pending.removeAll { $0.isApplicationPresence }
        queue.removeAll { $0.isApplicationPresence }
        // Not twice for one notice (a verdict change may have dismissed it already).
        if isPresentingNotice, !currentInvalidated, let currentFiring = current, currentFiring.isApplicationPresence {
            currentInvalidated = true
            noticePresenter?.dismiss()
        }
        checkDelayedFirings()
    }

    /// Configures the tracker with the rules that can be observed now. When that changes the
    /// tracked rules while a generation runs (a verdict changed during a check), the tracker stops
    /// and observations are restarted under a new generation (`requestObservationRestart`).
    private func refresh() -> Bool {
        let wasObserving = applicationTracker.isObserving
        defer {
            if wasObserving, !applicationTracker.isObserving, environment.canAct {
                requestObservationRestart()
            }
        }
        let currentRules = rules()
        let active = activeGroups()
        var eligible: [AppPresenceRuleTracker.Rule] = []
        var authorizedBindings: Set<ApplicationIdentityBinding> = []
        defer { applicationIdentityVerifier.retainOnly(authorizedBindings) }
        for trigger in currentRules {
            guard trigger.canRun else { continue }
            guard case .applicationPresence(let bundleID, let edge) = trigger.event else { continue }
            guard active.contains(trigger.groupID) else { continue }
            if trigger.applicationIdentityStatus == .authorized, let binding = trigger.applicationIdentity?.binding {
                authorizedBindings.insert(binding)
            }
            // A rule whose identity clears nothing (waiting for approval, unreadable, or authorized
            // but not confirmed by the verifier) isn't observed at all.
            guard applicationIdentityClearance(of: trigger) != .none else { continue }
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
        // A rule changed in any field, turned off or deleted reads from a fresh baseline after a gap.
        if let gap = catchUpGap {
            let readings = gap.readings.filter { id, reading in
                guard let rule = currentByID[id] else { return false }
                return rule == reading.rule && rule.canRun
            }
            catchUpGap = readings.isEmpty ? nil : CatchUpGap(start: gap.start, reason: gap.reason, readings: readings, end: gap.end)
        }
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
        checkDelayedFirings()
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
    ///   - isCatchUp: The edge is a net change across a gap (`catchUpAfterGap`): its firings never
    ///     run right away.
    /// - Returns: Whether an application-presence firing was enqueued.
    @discardableResult
    private func receive(_ signal: TriggerSignal, presence: (stamp: ApplicationPresenceStamp, isValid: () -> Bool)?, isCatchUp: Bool = false) -> Bool {
        let lockRevision = environment.screenLockRevision
        let wasAsleep = environment.screensAsleep
        let wasActive = environment.sessionActive
        let couldAct = environment.canAct
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
        // A bounded gap starts or ends (D5): before anything below stops the tracker.
        if couldAct, !environment.canAct {
            if case .session(active: false) = signal {
                beginCatchUpGap(reason: .sessionInactive)
            } else {
                beginCatchUpGap(reason: .macAsleep)
            }
        } else if !couldAct, environment.canAct {
            endCatchUpGap()
        }
        if case .screens(asleep: true) = signal {
            screensRevision &+= 1
        } else if environment.screensAsleep != wasAsleep {
            screensRevision &+= 1
        }
        if environment.sessionActive != wasActive {
            sessionRevision &+= 1
        }
        if environment.screenLockRevision != lockRevision {
            // The screen locked or unlocked again, or the lock can't be told: what the earlier lock
            // or unlock asked for is stale.
            invalidateStaleScreenLockFirings()
        }
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
                stamped.isCatchUp = isCatchUp
                return stamped
            }
        } else {
            firings.removeAll { $0.isApplicationPresence }
        }
        let enqueuedPresence = firings.contains { $0.isApplicationPresence }
        if !firings.isEmpty {
            for firing in firings {
                logger.notice("Trigger \(firing.triggerID, privacy: .public) asks to \(firing.action.rawValue, privacy: .public) group \(firing.groupID, privacy: .public)")
            }
            // A trigger's newer firing takes the place of the one waiting for its delay.
            cancelDelayedFirings(of: Set(firings.map(\.triggerID)))
            pending += firings
            restartSettle()
        }
        // The screens slept or woke, the session or the lock changed: a waiting delay may be stale.
        checkDelayedFirings()
        // The screens woke or the session came back: what waited can go on.
        processIfNeeded()
        return enqueuedPresence
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
        // An authorized rule's firing whose running code is still being checked waits one more
        // settle (the check is bounded by its time-out); after that it's skipped and recorded.
        if !settleWaitedForIdentityCheck, pending.contains(where: isAwaitingIdentityCheck) {
            settleWaitedForIdentityCheck = true
            restartSettle()
            return
        }
        settleWaitedForIdentityCheck = false
        // A stale presence or lock firing must not win the reduction over a firing that can still run.
        dropStaleApplicationPresenceFirings()
        invalidateStaleScreenLockFirings()
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

    /// Whether `firing` can be carried out now. A trigger on the screens going to sleep or the
    /// screen locking runs while they sleep — after they wake it would be too late for what it's
    /// for; everything else waits for the screens to wake and the session to be active.
    private func canCarryOut(_ firing: TriggerFiring) -> Bool {
        if environment.canAct { return true }
        return environment.sessionActive && runsWithoutAnyone(firing)
    }

    /// Whether `firing` is a trigger's on the screens going to sleep or the screen locking: nobody
    /// is there to answer a notice, so it runs right away.
    private func runsWithoutAnyone(_ firing: TriggerFiring) -> Bool {
        guard let trigger = rules().first(where: { $0.id == firing.triggerID }) else { return false }
        return trigger.event == .screensSleep || trigger.event == .screenLocks
    }

    // MARK: - Screen lock

    /// Whether a lock or unlock firing still stands for the lock as it is: the lock hasn't changed
    /// (nor become unknown) since it came. Other firings always do.
    private func isScreenLockFiringCurrent(_ firing: TriggerFiring) -> Bool {
        guard let revision = firing.screenLockRevision else {
            // A lock or unlock trigger's firing without its revision never runs.
            return rules().first(where: { $0.id == firing.triggerID })?.event.isScreenLock != true
        }
        return revision == environment.screenLockRevision
    }

    /// Drops the lock and unlock firings that are pending or queued but stale, without a record (the
    /// lock changed again before they ran), and dismisses the notice of a stale one.
    private func invalidateStaleScreenLockFirings() {
        pending.removeAll { !isScreenLockFiringCurrent($0) }
        queue.removeAll { !isScreenLockFiringCurrent($0) }
        if isPresentingNotice, !currentInvalidated, let currentFiring = current, !isScreenLockFiringCurrent(currentFiring) {
            currentInvalidated = true
            noticePresenter?.dismiss()
        }
    }

    private func processIfNeeded() {
        guard processing == nil, handler != nil else { return }
        guard delayed.contains(where: \.isDue) || queue.first.map(canCarryOut) == true else { return }
        processing = Task { @MainActor [weak self] in
            await self?.processQueue()
            self?.processing = nil
            // More may have come while the last one ran.
            self?.processIfNeeded()
        }
    }

    private func processQueue() async {
        while handler != nil {
            // A firing whose delay is over goes first: it was accepted before what waits in the queue.
            if let index = delayed.firstIndex(where: \.isDue) {
                let entry = delayed.remove(at: index)
                onDelayedFiringsChange?()
                current = entry.firing
                currentInvalidated = false
                currentInvalidationReason = nil
                await carryOutDelayed(entry)
                current = nil
                continue
            }
            guard let next = queue.first, canCarryOut(next) else { break }
            let firing = queue.removeFirst()
            current = firing
            currentInvalidated = false
            currentInvalidationReason = nil
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
        guard isScreenLockFiringCurrent(firing) else {
            logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated lock change: nothing done")
            return
        }
        // Like a push invalidation of a queued firing: dropped without a recorded outcome, unless
        // only its rule's running code isn't confirmed.
        switch applicationPresenceCheck(firing) {
        case .current:
            break
        case .identityNotConfirmed:
            dropStaleApplicationPresenceFirings()
            skip(firing, .applicationNotConfirmed)
            return
        case .stale:
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
        var runMode: TriggerRunMode = runsWithoutAnyone(firing) ? .immediately : trigger.runMode
        // A change that happened while the Mac couldn't act is never acted on silently (D6): Run
        // Right Away shows the notice; Show the Popup is its own notice.
        if firing.isCatchUp, runMode == .immediately, firing.action != .showPopup {
            runMode = .notice
        }
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
            switch applicationPresenceCheck(firing) {
            case .current:
                break
            case .identityNotConfirmed:
                dropStaleApplicationPresenceFirings()
                skip(firing, .applicationNotConfirmed)
                return
            case .stale:
                logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated application observation: nothing done")
                dropStaleApplicationPresenceFirings()
                return
            }
            isPresentingNotice = true
            let answer = await presenter.present(TriggerNotice(triggerID: trigger.id, groupID: group.id, groupName: group.name, action: firing.action, runMode: runMode, isCatchUp: firing.isCatchUp))
            isPresentingNotice = false
            // The screen locked or unlocked again while the notice showed: dropped, like a stale
            // firing that never reached its notice.
            guard isScreenLockFiringCurrent(firing) else {
                logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated lock change: nothing done")
                return
            }
            switch answer {
            case .run:
                break
            case .notNow: skip(firing, .notNow); return
            case .timedOut: skip(firing, .noAnswer); return
            case .replaced: skip(firing, currentInvalidationReason ?? .anotherTrigger); return
            }
            guard !currentInvalidated else {
                skip(firing, currentInvalidationReason ?? .anotherTrigger)
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
        // above may have called out (state changes, the handler), so the observation and the lock
        // are looked at again. An action that already started is not undone.
        guard isScreenLockFiringCurrent(firing) else {
            logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated lock change: nothing done")
            return
        }
        switch applicationPresenceCheck(firing) {
        case .current:
            break
        case .identityNotConfirmed:
            dropStaleApplicationPresenceFirings()
            skip(firing, .applicationNotConfirmed)
            return
        case .stale:
            logger.notice("Trigger \(firing.triggerID, privacy: .public) came from an outdated application observation: nothing done")
            dropStaleApplicationPresenceFirings()
            if runMode != .immediately { skip(firing, .anotherTrigger) }
            return
        }
        // Accepted: a trigger with a delay waits for it first (`carryOutDelayed`).
        if trigger.delaySeconds > 0 {
            park(firing, trigger: trigger)
            return
        }
        await run(firing, trigger: trigger, group: group, handler: handler)
    }

    // MARK: - Delays

    /// A firing accepted and waiting for its trigger's delay.
    private struct DelayedFiring {
        let token: UInt64
        let firing: TriggerFiring
        /// The rule as it was accepted: any change to it cancels the firing.
        let rule: GroupTrigger
        let due: Date
        let screensRevision: UInt64
        let sessionRevision: UInt64
        /// The delay is over: it waits for its turn.
        var isDue = false
        var task: Task<Void, Never>?
    }

    private enum DelayedCheck: Equatable {
        case holds
        /// Its rule was deleted: dropped without a record.
        case gone
        case cancelled(TriggerSkipReason)
    }

    /// Starts `firing`'s delay. It doesn't hold the queue up: the next firings go on meanwhile.
    private func park(_ firing: TriggerFiring, trigger: GroupTrigger) {
        delayToken &+= 1
        let token = delayToken
        let seconds = trigger.delaySeconds
        var entry = DelayedFiring(
            token: token,
            firing: firing,
            rule: trigger,
            due: clock().addingTimeInterval(TimeInterval(seconds)),
            screensRevision: screensRevision,
            sessionRevision: sessionRevision
        )
        entry.task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            self.delayElapsed(token)
        }
        delayed.append(entry)
        logger.notice("Trigger \(firing.triggerID, privacy: .public) waits \(seconds, privacy: .public) s before it runs")
        onDelayedFiringsChange?()
    }

    private func delayElapsed(_ token: UInt64) {
        // Cancelled meanwhile: nothing is left to do.
        guard let index = delayed.firstIndex(where: { $0.token == token }) else { return }
        delayed[index].isDue = true
        delayed[index].task = nil
        processIfNeeded()
    }

    /// Whether a waiting firing still stands. `isDue` adds what only counts when it would run now:
    /// the cooldown, At most once a day and the echo window.
    private func delayedCheck(_ entry: DelayedFiring, isDue: Bool) -> DelayedCheck {
        let firing = entry.firing
        guard let rule = rules().first(where: { $0.id == firing.triggerID }) else { return .gone }
        guard rule == entry.rule, rule.canRun else { return .cancelled(.cancelledBeforeRun) }
        let now = clock()
        if state.isPaused(at: now) { return .cancelled(state.pauseReason == .budget ? .budget : .paused) }
        guard activeGroups().contains(firing.groupID) else { return .cancelled(.groupMissing) }
        guard isScreenLockFiringCurrent(firing) else { return .cancelled(.cancelledBeforeRun) }
        switch applicationPresenceCheck(firing) {
        case .current: break
        case .stale: return .cancelled(.cancelledBeforeRun)
        case .identityNotConfirmed: return .cancelled(.applicationNotConfirmed)
        }
        guard entry.sessionRevision == sessionRevision else { return .cancelled(.cancelledBeforeRun) }
        // A lock trigger's Finish is meant for the locked screen: the displays sleeping then don't
        // matter (its lock revision does). Every other firing needs the screens as they were.
        if rule.event != .screenLocks, entry.screensRevision != screensRevision { return .cancelled(.cancelledBeforeRun) }
        guard canCarryOut(firing) else { return .cancelled(.cancelledBeforeRun) }
        guard isDue else { return .holds }
        if !firing.isFinishWhenEnded, let lastRun = state.entry(for: rule.id).lastRunAt {
            let elapsed = now.timeIntervalSince(lastRun)
            if elapsed >= 0, elapsed < TriggerEvaluator.cooldown { return .cancelled(.cooldown) }
            if rule.oncePerDay, calendar().isDate(lastRun, inSameDayAs: now) { return .cancelled(.alreadyRanToday) }
        }
        if rule.event.isEdge, environment.isInEchoWindow(at: now) { return .cancelled(.rightAfterAutomaticAction) }
        return .holds
    }

    /// Cancels the waiting firings that no longer stand, recording why.
    private func checkDelayedFirings() {
        guard !delayed.isEmpty, !isCheckingDelayed else { return }
        isCheckingDelayed = true
        defer { isCheckingDelayed = false }
        let verdicts = delayed.map { delayedCheck($0, isDue: false) }
        var cancelled: [(DelayedFiring, TriggerSkipReason?)] = []
        var kept: [DelayedFiring] = []
        for (entry, verdict) in zip(delayed, verdicts) {
            switch verdict {
            case .holds: kept.append(entry)
            case .gone: cancelled.append((entry, nil))
            case .cancelled(let reason): cancelled.append((entry, reason))
            }
        }
        guard !cancelled.isEmpty else { return }
        delayed = kept
        for (entry, reason) in cancelled {
            entry.task?.cancel()
            logger.notice("Trigger \(entry.firing.triggerID, privacy: .public) was cancelled while it waited")
            if let reason { skip(entry.firing, reason) }
        }
        onDelayedFiringsChange?()
    }

    /// Cancels the waiting firings of `triggerIDs` (a newer firing of each came).
    private func cancelDelayedFirings(of triggerIDs: Set<GroupTrigger.ID>) {
        let superseded = delayed.filter { triggerIDs.contains($0.firing.triggerID) }
        guard !superseded.isEmpty else { return }
        delayed.removeAll { triggerIDs.contains($0.firing.triggerID) }
        for entry in superseded {
            entry.task?.cancel()
            skip(entry.firing, .cancelledBeforeRun)
        }
        onDelayedFiringsChange?()
    }

    /// The app's groups changed (one archived or deleted): the waiting firings are looked at again.
    public func revalidateDelayedFirings() {
        checkDelayedFirings()
    }

    /// A firing whose delay is over: every check again, then the action, with no notice (it was
    /// answered before the delay).
    private func carryOutDelayed(_ entry: DelayedFiring) async {
        let firing = entry.firing
        switch delayedCheck(entry, isDue: true) {
        case .holds:
            break
        case .gone:
            return
        case .cancelled(let reason):
            logger.notice("Trigger \(firing.triggerID, privacy: .public) was cancelled when its delay ended")
            skip(firing, reason)
            return
        }
        guard let handler, let group = handler.group(withID: firing.groupID) else {
            skip(firing, .groupMissing)
            return
        }
        if let reason = blocker(for: firing, trigger: entry.rule, handler: handler) {
            skip(firing, reason)
            return
        }
        await run(firing, trigger: entry.rule, group: group, handler: handler)
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
        automaticActionStartedAt = clock()
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
        // Paused (by the user or the budget): what waits for its delay is cancelled.
        if !delayed.isEmpty, newState.isPaused(at: clock()) {
            checkDelayedFirings()
        }
    }
}
