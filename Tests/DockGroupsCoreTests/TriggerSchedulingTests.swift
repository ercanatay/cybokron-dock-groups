import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: when a time falls")
struct TriggerSchedulingTests {
    private let istanbul = TriggerTime.calendar()

    private func components(_ date: Date?, in calendar: Calendar) -> DateComponents? {
        date.map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: $0) }
    }

    @Test func latestAndNextFollowTheChosenDays() {
        // Wednesday 2026-10-28 at 10:00 in Istanbul.
        let now = TriggerTime.date(2026, 10, 28, 10, 0)
        let nine = TriggerSchedule(hour: 9, minute: 0, weekdays: TriggerTime.weekdays)
        #expect(TriggerScheduling.latestOccurrence(of: nine, atOrBefore: now, calendar: istanbul) == TriggerTime.date(2026, 10, 28, 9, 0))
        #expect(TriggerScheduling.nextOccurrence(of: nine, after: now, calendar: istanbul) == TriggerTime.date(2026, 10, 29, 9, 0))
        // At the moment itself, it's the latest, not the next.
        let atNine = TriggerTime.date(2026, 10, 28, 9, 0)
        #expect(TriggerScheduling.latestOccurrence(of: nine, atOrBefore: atNine, calendar: istanbul) == atNine)
        #expect(TriggerScheduling.nextOccurrence(of: nine, after: atNine, calendar: istanbul) == TriggerTime.date(2026, 10, 29, 9, 0))
        // Friday evening: next is Monday; Monday morning before 9: latest is Friday.
        let friday = TriggerTime.date(2026, 10, 30, 18, 0)
        #expect(TriggerScheduling.nextOccurrence(of: nine, after: friday, calendar: istanbul) == TriggerTime.date(2026, 11, 2, 9, 0))
        let monday = TriggerTime.date(2026, 11, 2, 8, 0)
        #expect(TriggerScheduling.latestOccurrence(of: nine, atOrBefore: monday, calendar: istanbul) == TriggerTime.date(2026, 10, 30, 9, 0))
        // One day a week, from the same day after the time: a week on.
        let sundays = TriggerSchedule(hour: 9, minute: 0, weekdays: [1])
        let sundayNoon = TriggerTime.date(2026, 11, 1, 12, 0)
        #expect(TriggerScheduling.nextOccurrence(of: sundays, after: sundayNoon, calendar: istanbul) == TriggerTime.date(2026, 11, 8, 9, 0))
        #expect(TriggerScheduling.latestOccurrence(of: sundays, atOrBefore: TriggerTime.date(2026, 11, 1, 8, 0), calendar: istanbul) == TriggerTime.date(2026, 10, 25, 9, 0))
    }

    @Test func midnightAndTheLastMinute() {
        let midnight = TriggerSchedule(hour: 0, minute: 0, weekdays: TriggerSchedule.everyDay)
        let late = TriggerSchedule(hour: 23, minute: 59, weekdays: TriggerSchedule.everyDay)
        let now = TriggerTime.date(2026, 10, 28, 23, 59, 30)
        #expect(TriggerScheduling.latestOccurrence(of: late, atOrBefore: now, calendar: istanbul) == TriggerTime.date(2026, 10, 28, 23, 59))
        #expect(TriggerScheduling.nextOccurrence(of: midnight, after: now, calendar: istanbul) == TriggerTime.date(2026, 10, 29, 0, 0))
    }

    @Test func aScheduleThatCantRunHasNoOccurrence() {
        let now = TriggerTime.date(2026, 10, 28, 10, 0)
        #expect(TriggerScheduling.latestOccurrence(of: TriggerSchedule(minuteOfDay: 2000, weekdays: [4]), atOrBefore: now, calendar: istanbul) == nil)
        #expect(TriggerScheduling.nextOccurrence(of: TriggerSchedule(hour: 9, minute: 0, weekdays: []), after: now, calendar: istanbul) == nil)
    }

    /// Spring forward: 02:30 doesn't exist that day and falls at 03:00 instead; the day after, it's
    /// 02:30 again.
    @Test(arguments: [
        ("Europe/Berlin", 2026, 3, 29, 3, 0),
        ("America/New_York", 2026, 3, 8, 3, 0),
    ])
    func aTimeInTheGapFallsAfterIt(zone: String, year: Int, month: Int, day: Int, hour: Int, minute: Int) throws {
        let calendar = TriggerTime.calendar(zone)
        let schedule = TriggerSchedule(hour: 2, minute: 30, weekdays: TriggerSchedule.everyDay)
        let before = TriggerTime.date(year, month, day, 0, 30, in: calendar)
        let occurrence = try #require(TriggerScheduling.nextOccurrence(of: schedule, after: before, calendar: calendar))
        let parts = try #require(components(occurrence, in: calendar))
        #expect(parts.day == day && parts.hour == hour && parts.minute == minute)
        let following = try #require(components(TriggerScheduling.nextOccurrence(of: schedule, after: occurrence, calendar: calendar), in: calendar))
        #expect(following.day == day + 1 && following.hour == 2 && following.minute == 30)
    }

    /// Lord Howe Island moves its clocks by 30 minutes: 02:15 falls at 02:30 that day.
    @Test func aHalfHourGapToo() throws {
        let calendar = TriggerTime.calendar("Australia/Lord_Howe")
        let schedule = TriggerSchedule(hour: 2, minute: 15, weekdays: TriggerSchedule.everyDay)
        let occurrence = try #require(TriggerScheduling.occurrence(of: schedule, onDayOf: TriggerTime.date(2026, 10, 4, 12, 0, in: calendar), calendar: calendar))
        let parts = try #require(components(occurrence, in: calendar))
        #expect(parts.day == 4 && parts.hour == 2 && parts.minute == 30)
    }

    /// Fall back: 02:30 happens twice in Berlin; it falls the first time only.
    @Test func aRepeatedTimeFallsOnce() throws {
        let calendar = TriggerTime.calendar("Europe/Berlin")
        let schedule = TriggerSchedule(hour: 2, minute: 30, weekdays: TriggerSchedule.everyDay)
        let day = TriggerTime.date(2026, 10, 25, 12, 0, in: calendar)
        let first = try #require(TriggerScheduling.occurrence(of: schedule, onDayOf: day, calendar: calendar))
        #expect(calendar.timeZone.secondsFromGMT(for: first) == 7_200)
        // After the first, the next is the following day's, not the second 02:30 an hour later.
        let next = try #require(TriggerScheduling.nextOccurrence(of: schedule, after: first, calendar: calendar))
        #expect(next.timeIntervalSince(first) > 23 * 3600)
        // Right after the second 02:30, the latest is still the first.
        #expect(TriggerScheduling.latestOccurrence(of: schedule, atOrBefore: first.addingTimeInterval(3_700), calendar: calendar) == first)
    }

    @Test func weekdaysAreGregorianWhateverTheCalendar() throws {
        var persian = Calendar(identifier: .persian)
        persian.timeZone = TimeZone(identifier: "Asia/Tehran")!
        let schedule = TriggerSchedule(hour: 9, minute: 0, weekdays: [6])
        // Friday 2026-10-30 at noon in Tehran.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = persian.timeZone
        let noon = TriggerTime.date(2026, 10, 30, 12, 0, in: gregorian)
        let latest = try #require(TriggerScheduling.latestOccurrence(of: schedule, atOrBefore: noon, calendar: persian))
        #expect(latest == TriggerTime.date(2026, 10, 30, 9, 0, in: gregorian))
    }
}
