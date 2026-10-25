import Foundation

/// How many automatic actions may run (triggers spec §1.9, DECISION 8): at most
/// `maximumPerHour` in any hour, across all triggers. The next one pauses every trigger for
/// `pauseLength` instead of running, and is recorded.
public enum TriggerBudget {
    public static let maximumPerHour = 12
    public static let window: TimeInterval = 60 * 60
    public static let pauseLength: TimeInterval = 60 * 60

    /// The runs of the last hour before `now`.
    public static func recent(_ runs: [Date], now: Date) -> [Date] {
        runs.filter { run in
            let age = now.timeIntervalSince(run)
            return age >= 0 && age < window
        }
    }

    /// Whether one more action may run at `now`.
    public static func allows(_ runs: [Date], now: Date) -> Bool {
        recent(runs, now: now).count < maximumPerHour
    }

    /// The text when the budget paused triggers.
    public static var pauseMessage: String {
        let count = maximumPerHour
        return Localization.format("core.trigger.budget.paused", "Triggers paused for an hour: they ran %ld times in an hour.", count)
    }
}

/// How long Pause Triggers lasts (spec §1.9).
public enum TriggerPauseLength: String, CaseIterable, Sendable {
    case oneHour
    /// Until the next midnight.
    case untilTomorrow
    case untilResumed

    /// When a pause of this length that starts at `now` ends.
    public func end(from now: Date, calendar: Calendar) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 60 * 60)
        case .untilResumed:
            return .distantFuture
        }
    }
}
