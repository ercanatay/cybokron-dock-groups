import Foundation

/// What the trigger editor shows and changes (triggers spec §3.2), for the events this version's
/// editor offers: a time, login, the app opening, the screens waking or sleeping. Choosing an
/// event offers only the actions it allows (§1.6); Show the Popup always runs right away.
public struct TriggerDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case time
        case login
        case appOpens
        case screensWake
        case screensSleep
    }

    public private(set) var kind: Kind
    /// Minutes since midnight, for a time.
    public var minuteOfDay: Int
    /// Gregorian weekday numbers, for a time.
    public var weekdays: Set<Int>
    public private(set) var action: TriggerAction
    public private(set) var runMode: TriggerRunMode
    public var oncePerDay: Bool

    /// A new trigger: at 9:00 on the calendar's working days, Start, with a notice.
    public init(calendar: Calendar) {
        kind = .time
        minuteOfDay = 9 * 60
        weekdays = TriggerSchedule.workingDays(in: calendar)
        action = .start
        runMode = .notice
        oncePerDay = false
    }

    /// The draft of `trigger`; `nil` for an event this editor doesn't offer (a display or a
    /// network, or one it can't read) and for an action a newer version wrote.
    public init?(editing trigger: GroupTrigger, calendar: Calendar) {
        // An action a newer version wrote: editing would replace it.
        guard trigger.unrecognizedAction == nil else { return nil }
        switch trigger.event {
        case .schedule(let schedule):
            kind = .time
            minuteOfDay = schedule.minuteOfDay
            weekdays = schedule.weekdays
        case .login: kind = .login; minuteOfDay = 9 * 60; weekdays = TriggerSchedule.workingDays(in: calendar)
        case .appOpens: kind = .appOpens; minuteOfDay = 9 * 60; weekdays = TriggerSchedule.workingDays(in: calendar)
        case .screensWake: kind = .screensWake; minuteOfDay = 9 * 60; weekdays = TriggerSchedule.workingDays(in: calendar)
        case .screensSleep: kind = .screensSleep; minuteOfDay = 9 * 60; weekdays = TriggerSchedule.workingDays(in: calendar)
        case .condition, .unsupported: return nil
        }
        action = trigger.action
        runMode = trigger.runMode
        oncePerDay = trigger.oncePerDay
        normalize()
    }

    /// The event the draft describes.
    public var event: TriggerEvent {
        switch kind {
        case .time: return .schedule(TriggerSchedule(minuteOfDay: minuteOfDay, weekdays: weekdays))
        case .login: return .login
        case .appOpens: return .appOpens
        case .screensWake: return .screensWake
        case .screensSleep: return .screensSleep
        }
    }

    public var allowedActions: [TriggerAction] { event.allowedActions }

    /// Show the Popup runs right away only (its popup is its own notice).
    public var allowedRunModes: [TriggerRunMode] {
        action == .showPopup ? [.immediately] : TriggerRunMode.allCases
    }

    /// Whether it can be saved: a time needs at least one day.
    public var isValid: Bool {
        GroupTrigger(groupID: UUID(), event: event, action: action, runMode: runMode).isRunnable
    }

    public mutating func setKind(_ kind: Kind) {
        let previous = action
        self.kind = kind
        normalize()
        if previous == .showPopup, action != .showPopup {
            runMode = .notice
        }
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

    /// The trigger: a new one, or `existing` changed (its identifier and switch kept).
    public func trigger(groupID: DockGroup.ID, replacing existing: GroupTrigger? = nil) -> GroupTrigger {
        GroupTrigger(
            id: existing?.id ?? UUID(),
            groupID: existing?.groupID ?? groupID,
            event: event,
            action: action,
            runMode: runMode,
            isEnabled: existing?.isEnabled ?? true,
            oncePerDay: oncePerDay
        )
    }

    private mutating func normalize() {
        if !allowedActions.contains(action) {
            action = allowedActions.contains(.start) ? .start : (allowedActions.first ?? .start)
        }
        if !allowedRunModes.contains(runMode) {
            runMode = allowedRunModes.first ?? .notice
        }
    }
}
