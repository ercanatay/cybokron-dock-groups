import Foundation

/// What the trigger editor shows and changes (triggers spec §3.2): when — a moment (a time, login,
/// the app opening, the screens waking or sleeping) or a change (a display connecting or
/// disconnecting, a set of displays being connected or no longer) —, the action that event allows
/// (§1.6), how it runs, At most once a day and, for a Start on a change's start, Finish when it
/// ends. Show the Popup always runs right away.
public struct TriggerDraft: Equatable, Sendable {
    /// Events that happen at a moment.
    public enum Kind: String, CaseIterable, Sendable {
        case time
        case login
        case appOpens
        case screensWake
        case screensSleep
    }

    /// Events that are the start or the end of a condition.
    public enum Change: String, CaseIterable, Sendable {
        /// A display (any external one, or a chosen one) connects; its end is `displayDisconnects`.
        case displayConnects
        case displayDisconnects
        /// The connected displays become exactly the chosen ones; its end is `displaysDisconnected`.
        case displaysConnected
        case displaysDisconnected

        /// The condition it starts or ends.
        public var edge: TriggerEdge {
            switch self {
            case .displayConnects, .displaysConnected: return .starts
            case .displayDisconnects, .displaysDisconnected: return .ends
            }
        }
    }

    /// The editor's When pop-up: a moment or a change.
    public enum When: Hashable, Sendable {
        case moment(Kind)
        case change(Change)

        /// Every event the editor offers, in the pop-up's order.
        public static var offered: [When] {
            Kind.allCases.map(When.moment) + Change.allCases.map(When.change)
        }
    }

    public private(set) var when: When
    /// Minutes since midnight, for a time.
    public var minuteOfDay: Int
    /// Gregorian weekday numbers, for a time.
    public var weekdays: Set<Int>
    /// The display a display trigger waits for.
    public var display: DisplayMatch
    /// The displays a These Displays trigger waits for (Use Current Displays fills them in).
    public var displays: [DisplayIdentity]
    public private(set) var action: TriggerAction
    public private(set) var runMode: TriggerRunMode
    public var oncePerDay: Bool
    /// Finish when it ends: only for a Start on a change's start (`canFinishWhenEventEnds`).
    public var finishesWhenEventEnds: Bool

    /// A new trigger: at 9:00 on the calendar's working days, Start, with a notice.
    public init(calendar: Calendar) {
        when = .moment(.time)
        minuteOfDay = 9 * 60
        weekdays = TriggerSchedule.workingDays(in: calendar)
        display = .anyExternal
        displays = []
        action = .start
        runMode = .notice
        oncePerDay = false
        finishesWhenEventEnds = false
    }

    /// The draft of `trigger`; `nil` for an event this editor doesn't offer (a network, or one it
    /// can't read) and for an action a newer version wrote.
    public init?(editing trigger: GroupTrigger, calendar: Calendar) {
        // An action a newer version wrote: editing would replace it.
        guard trigger.unrecognizedAction == nil else { return nil }
        self.init(calendar: calendar)
        switch trigger.event {
        case .schedule(let schedule):
            when = .moment(.time)
            minuteOfDay = schedule.minuteOfDay
            weekdays = schedule.weekdays
        case .login: when = .moment(.login)
        case .appOpens: when = .moment(.appOpens)
        case .screensWake: when = .moment(.screensWake)
        case .screensSleep: when = .moment(.screensSleep)
        case .condition(.display(let match), let edge):
            when = .change(edge == .starts ? .displayConnects : .displayDisconnects)
            display = match
        case .condition(.displays(let arrangement), let edge):
            when = .change(edge == .starts ? .displaysConnected : .displaysDisconnected)
            displays = arrangement.displays
        case .condition, .unsupported:
            return nil
        }
        action = trigger.action
        runMode = trigger.runMode
        oncePerDay = trigger.oncePerDay
        finishesWhenEventEnds = trigger.finishesWhenEventEnds
        normalize()
    }

    /// The moment, when the event is one.
    public var kind: Kind? {
        if case .moment(let kind) = when { return kind }
        return nil
    }

    /// The change, when the event is one.
    public var change: Change? {
        if case .change(let change) = when { return change }
        return nil
    }

    /// The event the draft describes.
    public var event: TriggerEvent {
        switch when {
        case .moment(.time): return .schedule(TriggerSchedule(minuteOfDay: minuteOfDay, weekdays: weekdays))
        case .moment(.login): return .login
        case .moment(.appOpens): return .appOpens
        case .moment(.screensWake): return .screensWake
        case .moment(.screensSleep): return .screensSleep
        case .change(let change): return .condition(condition(of: change), edge: change.edge)
        }
    }

    private func condition(of change: Change) -> TriggerCondition {
        switch change {
        case .displayConnects, .displayDisconnects: return .display(display)
        case .displaysConnected, .displaysDisconnected: return .displays(DisplayArrangement(displays: displays))
        }
    }

    public var allowedActions: [TriggerAction] { event.allowedActions }

    /// Show the Popup runs right away only (its popup is its own notice).
    public var allowedRunModes: [TriggerRunMode] {
        action == .showPopup ? [.immediately] : TriggerRunMode.allCases
    }

    /// Whether Finish when it ends applies: a Start on a change's start.
    public var canFinishWhenEventEnds: Bool {
        action == .start && change?.edge == .starts
    }

    /// Whether it can be saved: a time needs at least one day, These Displays one to eight
    /// displays, a chosen display can't be the built-in one.
    public var isValid: Bool {
        GroupTrigger(groupID: UUID(), event: event, action: action, runMode: runMode).isRunnable
    }

    public mutating func setWhen(_ when: When) {
        let previous = action
        self.when = when
        normalize()
        if previous == .showPopup, action != .showPopup {
            runMode = .notice
        }
    }

    public mutating func setKind(_ kind: Kind) {
        setWhen(.moment(kind))
    }

    public mutating func setChange(_ change: Change) {
        setWhen(.change(change))
    }

    public mutating func setAction(_ action: TriggerAction) {
        let wasPopup = self.action == .showPopup
        self.action = action
        if wasPopup, action != .showPopup {
            runMode = .notice
        }
        normalize()
    }

    public mutating func setRunMode(_ runMode: TriggerRunMode) {
        guard allowedRunModes.contains(runMode) else { return }
        self.runMode = runMode
    }

    /// Use Current Displays: the displays connected now, at most `DisplayArrangement.maximumCount`.
    public mutating func useDisplays(_ connected: [DisplayIdentity]) {
        displays = Array(connected.prefix(DisplayArrangement.maximumCount))
    }

    /// The trigger: a new one, or `existing` changed (its identifier and switch kept).
    public func trigger(groupID: DockGroup.ID, replacing existing: GroupTrigger? = nil) -> GroupTrigger {
        GroupTrigger(
            id: existing?.id ?? UUID(),
            groupID: existing?.groupID ?? groupID,
            event: event,
            action: action,
            runMode: runMode,
            isEnabled: existing?.isEnabled ?? true,
            oncePerDay: oncePerDay,
            finishesWhenEventEnds: finishesWhenEventEnds && canFinishWhenEventEnds
        )
    }

    private mutating func normalize() {
        if !allowedActions.contains(action) {
            action = allowedActions.contains(.start) ? .start : (allowedActions.first ?? .start)
        }
        if !allowedRunModes.contains(runMode) {
            runMode = allowedRunModes.first ?? .notice
        }
        if !canFinishWhenEventEnds {
            finishesWhenEventEnds = false
        }
    }
}

/// The displays a display trigger's chooser offers (triggers spec §1.4, §3.2): any external
/// display, each external display connected now — two identical ones without serial numbers are
/// one choice, since they can't be told apart — and the saved display when it isn't connected.
public enum DisplayChoices {
    public struct Option: Hashable, Sendable {
        public let match: DisplayMatch
        /// Whether a display it matches is connected now (always true for any external display).
        public let isConnected: Bool
    }

    public static func options(connected: [DisplayIdentity], saved: DisplayMatch) -> [Option] {
        var options = [Option(match: .anyExternal, isConnected: true)]
        var seen: [DisplayIdentity] = []
        for display in connected where !display.isBuiltIn && !seen.contains(where: display.matches) {
            seen.append(display)
            options.append(Option(match: .display(display), isConnected: true))
        }
        if case .display(let identity) = saved, !seen.contains(where: identity.matches) {
            options.append(Option(match: saved, isConnected: false))
        }
        return options
    }

    /// The choice `saved` is among `options`: the connected display it matches, so the pop-up shows
    /// it chosen even when its name changed.
    public static func selection(for saved: DisplayMatch, in options: [Option]) -> DisplayMatch {
        guard case .display(let identity) = saved else { return saved }
        for option in options {
            if case .display(let candidate) = option.match, candidate.matches(identity) {
                return option.match
            }
        }
        return saved
    }

    /// Whether `display` of a These Displays trigger is connected now.
    public static func isConnected(_ display: DisplayIdentity, in connected: [DisplayIdentity]) -> Bool {
        connected.contains(where: display.matches)
    }
}
