import Foundation

/// What the Mac is doing, as far as triggers care: kept in memory by the coordinator, never saved
/// (at launch the screens are awake and the session is active).
public struct TriggerEnvironment: Equatable, Sendable {
    public var screensAsleep = false
    public var sessionActive = true
    /// Display and network changes before this moment run nothing: an automatic action is under
    /// way or just finished (the echo window, triggers spec §1.9).
    public var echoUntil: Date?

    public init(screensAsleep: Bool = false, sessionActive: Bool = true, echoUntil: Date? = nil) {
        self.screensAsleep = screensAsleep
        self.sessionActive = sessionActive
        self.echoUntil = echoUntil
    }

    /// Whether an action can run now: the screens are awake and the user's session is the active one.
    public var canAct: Bool { !screensAsleep && sessionActive }

    func isInEchoWindow(at date: Date) -> Bool {
        guard let echoUntil else { return false }
        return date < echoUntil
    }
}

/// One trigger asking for its action: what the coordinator settles, reduces and carries out.
public struct TriggerFiring: Hashable, Sendable {
    public let triggerID: GroupTrigger.ID
    public let groupID: DockGroup.ID
    public let action: TriggerAction
    /// The time's occurrence, or when the change came.
    public let occurrence: Date
    /// The finish a Start trigger's "Finish when it ends" asks for.
    public let isFinishWhenEnded: Bool
    /// Where the trigger is in the list (Settings → Triggers' order): the first wins a tie.
    public let order: Int

    public init(triggerID: GroupTrigger.ID, groupID: DockGroup.ID, action: TriggerAction, occurrence: Date, isFinishWhenEnded: Bool = false, order: Int = 0) {
        self.triggerID = triggerID
        self.groupID = groupID
        self.action = action
        self.occurrence = occurrence
        self.isFinishWhenEnded = isFinishWhenEnded
        self.order = order
    }
}

/// What one signal led to: the firings to settle, and the state and environment after it.
public struct TriggerEvaluation: Equatable, Sendable {
    public var firings: [TriggerFiring]
    public var state: TriggerState
    public var environment: TriggerEnvironment
}

/// Turns a signal, the rules and the remembered state into firings (triggers spec §2.4). Pure: it
/// reads nothing and does nothing, so every rule is a property of its result.
///
/// - Only triggers that can run (`GroupTrigger.canRun`) whose group is active fire. The others keep
///   up silently — a time that passes while a trigger is off, or its group archived, counts as
///   handled, and conditions keep their reading — so turning one on, or restoring its group, never
///   runs something that happened before.
/// - A time runs once per occurrence, up to `catchUpWindow` late, and only while the Mac can act;
///   later it's missed. A trigger without remembered state takes the latest occurrence as handled.
/// - A condition fires on a change between two known readings; an unknown reading changes nothing,
///   and the first known one is only a baseline.
/// - Gates, in order: the 60-second cooldown and At most once a day (not for a Start's own "Finish
///   when it ends"), the echo window (changes only), the pause. What a gate stops is recorded and
///   never run later.
public enum TriggerEvaluator {
    /// How late a time may still run (DECISION 3: fixed).
    public static let catchUpWindow: TimeInterval = 30 * 60
    /// The shortest time between two runs of one trigger.
    public static let cooldown: TimeInterval = 60

    public static func evaluate(
        _ signal: TriggerSignal,
        rules: [GroupTrigger],
        state: TriggerState,
        environment: TriggerEnvironment,
        activeGroups: Set<DockGroup.ID>,
        now: Date,
        calendar: Calendar
    ) -> TriggerEvaluation {
        var environment = environment
        let wasAsleep = environment.screensAsleep
        switch signal {
        case .screens(let asleep): environment.screensAsleep = asleep
        case .session(let active): environment.sessionActive = active
        default: break
        }
        var state = baseline(rules: rules, state: state, now: now, calendar: calendar)
        var firings: [TriggerFiring] = []

        for (order, trigger) in rules.enumerated() {
            let live = trigger.canRun && activeGroups.contains(trigger.groupID)
            var entry = state.entry(for: trigger.id)
            func fire(_ action: TriggerAction, at occurrence: Date, edge: Bool, finishWhenEnded: Bool = false) {
                if let reason = gate(trigger, entry: entry, isEdge: edge, isFinishWhenEnded: finishWhenEnded, state: state, environment: environment, now: now, calendar: calendar) {
                    entry.lastOutcome = .skipped(reason)
                    entry.lastOutcomeAt = occurrence
                } else {
                    firings.append(TriggerFiring(triggerID: trigger.id, groupID: trigger.groupID, action: action, occurrence: occurrence, isFinishWhenEnded: finishWhenEnded, order: order))
                }
            }
            switch trigger.event {
            case .schedule(let schedule):
                guard evaluatesSchedules(signal),
                      let latest = TriggerScheduling.latestOccurrence(of: schedule, atOrBefore: now, calendar: calendar),
                      let handled = entry.lastHandledOccurrence, latest > handled
                else { break }
                guard live else {
                    entry.lastHandledOccurrence = latest
                    break
                }
                if now.timeIntervalSince(latest) > catchUpWindow {
                    entry.lastHandledOccurrence = latest
                    entry.lastOutcome = .missed(missReason(for: signal))
                    entry.lastOutcomeAt = latest
                    break
                }
                // Deferred: it runs once the screens wake and the session is active, if still in time.
                guard environment.canAct else { break }
                entry.lastHandledOccurrence = latest
                fire(trigger.action, at: latest, edge: false)
            case .login:
                guard live, case .launched(.login(let session)) = signal, state.lastLoginSession != session else { break }
                fire(trigger.action, at: now, edge: false)
            case .appOpens:
                guard live, case .launched(let kind) = signal, kind != .quiet else { break }
                fire(trigger.action, at: now, edge: false)
            case .screensWake:
                guard live, case .screens(asleep: false) = signal, wasAsleep else { break }
                fire(trigger.action, at: now, edge: false)
            case .screensSleep:
                guard live, case .screens(asleep: true) = signal, !wasAsleep else { break }
                fire(trigger.action, at: now, edge: false)
            case .condition(let condition, let edge):
                guard case .value(let value) = condition.reading(in: signal) else { break }
                let previous = entry.condition
                entry.condition = value
                guard live, let previous, previous != value else { break }
                let started = value > previous
                if (edge == .starts) == started {
                    fire(trigger.action, at: now, edge: true)
                }
                if !started, trigger.finishesWhenEventEnds, trigger.canFinishWhenEventEnds {
                    fire(.finish, at: now, edge: true, finishWhenEnded: true)
                }
            case .unsupported:
                break
            }
            state.entries[trigger.id] = entry
        }
        if case .launched(.login(let session)) = signal {
            state.lastLoginSession = session
        }
        return TriggerEvaluation(firings: firings, state: state, environment: environment)
    }

    /// Remembered state for the triggers that have none: a time's latest occurrence counts as
    /// handled, so a trigger added at 9:05 doesn't run its 9:00 at once, and nothing catches up
    /// after the state file was lost. Conditions start unknown: their first reading is a baseline.
    public static func baseline(rules: [GroupTrigger], state: TriggerState, now: Date, calendar: Calendar) -> TriggerState {
        var state = state
        for trigger in rules where state.entries[trigger.id]?.lastHandledOccurrence == nil {
            guard case .schedule(let schedule) = trigger.event else {
                if state.entries[trigger.id] == nil { state.entries[trigger.id] = TriggerState.Entry() }
                continue
            }
            var entry = state.entry(for: trigger.id)
            entry.lastHandledOccurrence = TriggerScheduling.latestOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
                ?? now
            state.entries[trigger.id] = entry
        }
        return state
    }

    /// The state after the rules changed from `previous` to `rules`: entries of deleted triggers
    /// go, and triggers that are new, were turned on, or whose group or event changed start from a
    /// fresh baseline — nothing that happened before the change runs. Their last run and outcome
    /// are kept.
    public static func rebaseline(previous: [GroupTrigger], rules: [GroupTrigger], state: TriggerState, now: Date, calendar: Calendar) -> TriggerState {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var state = state.keepingEntries(of: Set(rules.map(\.id)))
        for trigger in rules {
            let old = before[trigger.id]
            let changed = old == nil
                || old?.groupID != trigger.groupID
                || old?.event != trigger.event
                || (old?.canRun == false && trigger.canRun)
            guard changed else { continue }
            var entry = state.entry(for: trigger.id)
            entry.lastHandledOccurrence = nil
            entry.condition = nil
            state.entries[trigger.id] = entry
        }
        return baseline(rules: rules, state: state, now: now, calendar: calendar)
    }

    /// When the clock must look next: the earliest coming occurrence of a time that can run, `nil`
    /// when there's none (then no timer is needed at all).
    public static func nextDue(rules: [GroupTrigger], activeGroups: Set<DockGroup.ID>, after now: Date, calendar: Calendar) -> Date? {
        rules.compactMap { trigger -> Date? in
            guard trigger.canRun, activeGroups.contains(trigger.groupID), case .schedule(let schedule) = trigger.event else { return nil }
            return TriggerScheduling.nextOccurrence(of: schedule, after: now, calendar: calendar)
        }.min()
    }

    // MARK: - Helpers

    private static func evaluatesSchedules(_ signal: TriggerSignal) -> Bool {
        switch signal {
        case .clock, .launched, .screens(asleep: false), .session(active: true): return true
        case .screens, .session, .displays, .network: return false
        }
    }

    private static func missReason(for signal: TriggerSignal) -> TriggerMissReason {
        switch signal {
        case .launched: return .appNotOpen
        case .session: return .sessionInactive
        default: return .macAsleep
        }
    }

    private static func gate(
        _ trigger: GroupTrigger,
        entry: TriggerState.Entry,
        isEdge: Bool,
        isFinishWhenEnded: Bool,
        state: TriggerState,
        environment: TriggerEnvironment,
        now: Date,
        calendar: Calendar
    ) -> TriggerSkipReason? {
        if !isFinishWhenEnded, let lastRun = entry.lastRunAt {
            let elapsed = now.timeIntervalSince(lastRun)
            if elapsed >= 0, elapsed < cooldown { return .cooldown }
            if trigger.oncePerDay, calendar.isDate(lastRun, inSameDayAs: now) { return .alreadyRanToday }
        }
        if isEdge, environment.isInEchoWindow(at: now) { return .rightAfterAutomaticAction }
        if state.isPaused(at: now) { return .paused }
        return nil
    }
}
