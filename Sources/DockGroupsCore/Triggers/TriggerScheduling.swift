import Foundation

/// When a schedule's time falls (triggers spec §1.3): wall-clock time in the time zone of the
/// calendar it's given, on Gregorian weekdays, whatever calendar system the user has.
///
/// - A time that doesn't exist that day (02:30 when clocks spring forward) falls at the first
///   moment after the gap (03:00; 02:30 on Lord Howe Island, whose clocks move 30 minutes).
/// - A time that happens twice (01:30 when clocks fall back) falls the first time only.
public enum TriggerScheduling {
    /// The moment `schedule` falls on the day that contains `day`, or `nil` when it doesn't fall on
    /// that weekday.
    public static func occurrence(of schedule: TriggerSchedule, onDayOf day: Date, calendar: Calendar) -> Date? {
        let gregorian = gregorian(like: calendar)
        let start = gregorian.startOfDay(for: day)
        guard schedule.weekdays.contains(gregorian.component(.weekday, from: start)) else { return nil }
        let time = DateComponents(hour: schedule.hour, minute: schedule.minute, second: 0)
        if let match = gregorian.nextDate(
            after: start.addingTimeInterval(-1),
            matching: time,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        ), gregorian.isDate(match, inSameDayAs: start) {
            return match
        }
        // The time doesn't exist that day: clocks moved forward over it. The first moment after the
        // gap is the transition itself.
        guard let transition = gregorian.timeZone.nextDaylightSavingTimeTransition(after: start),
              gregorian.isDate(transition, inSameDayAs: start)
        else { return nil }
        return transition
    }

    /// The latest moment `schedule` fell at or before `date`, within the last eight days.
    public static func latestOccurrence(of schedule: TriggerSchedule, atOrBefore date: Date, calendar: Calendar) -> Date? {
        guard schedule.isValid else { return nil }
        let gregorian = gregorian(like: calendar)
        let today = gregorian.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = gregorian.date(byAdding: .day, value: -offset, to: today),
                  let occurrence = occurrence(of: schedule, onDayOf: day, calendar: gregorian),
                  occurrence <= date
            else { continue }
            return occurrence
        }
        return nil
    }

    /// The first moment `schedule` falls after `date`, within the next eight days.
    public static func nextOccurrence(of schedule: TriggerSchedule, after date: Date, calendar: Calendar) -> Date? {
        guard schedule.isValid else { return nil }
        let gregorian = gregorian(like: calendar)
        let today = gregorian.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = gregorian.date(byAdding: .day, value: offset, to: today),
                  let occurrence = occurrence(of: schedule, onDayOf: day, calendar: gregorian),
                  occurrence > date
            else { continue }
            return occurrence
        }
        return nil
    }

    /// A Gregorian calendar in `calendar`'s time zone: weekdays are numbered the same in every
    /// calendar system, and times of day don't depend on it.
    static func gregorian(like calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        return gregorian
    }
}
