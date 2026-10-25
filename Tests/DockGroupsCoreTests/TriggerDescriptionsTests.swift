import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: how a trigger reads")
struct TriggerDescriptionsTests {
    private static let us = Locale(identifier: "en_US")
    private static let uk = Locale(identifier: "en_GB")
    private static let group = DockGroup.of("Work", ["com.apple.mail"])
    private static let appName = "Cybokron Dock Groups"

    /// Istanbul, the week starting on `firstWeekday`.
    private static func calendar(locale: String = "en_GB", firstWeekday: Int = 2) -> Calendar {
        var calendar = TriggerTime.calendar(locale: locale)
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// AM and PM come after a narrow no-break space in newer ICU versions.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func summary(_ trigger: GroupTrigger, locale: Locale = uk) -> String {
        TriggerDescriptions.summary(trigger, appName: Self.appName, calendar: Self.calendar(), locale: locale)
    }

    // MARK: - Times and days

    @Test func timesFollowTheLocale() {
        #expect(Self.plain(TriggerDescriptions.time(9 * 60, locale: Self.us)) == "9:00 AM")
        #expect(Self.plain(TriggerDescriptions.time(13 * 60 + 5, locale: Self.us)) == "1:05 PM")
        #expect(TriggerDescriptions.time(9 * 60, locale: Self.uk) == "09:00")
        #expect(TriggerDescriptions.time(0, locale: Locale(identifier: "de_DE")) == "00:00")
        // Out of range: clamped to the day.
        #expect(TriggerDescriptions.time(-5, locale: Self.uk) == "00:00")
        #expect(TriggerDescriptions.time(5_000, locale: Self.uk) == "23:59")
    }

    @Test func daysReadAsNamedSetsOrInTheWeeksOrder() {
        let calendar = Self.calendar()
        #expect(TriggerDescriptions.days(TriggerSchedule.everyDay, calendar: calendar, locale: Self.uk) == .everyDay)
        #expect(TriggerDescriptions.days(TriggerTime.weekdays, calendar: calendar, locale: Self.uk) == .weekdays)
        #expect(TriggerDescriptions.days([1, 7], calendar: calendar, locale: Self.uk) == .weekends)
        #expect(TriggerDescriptions.days([2, 4], calendar: calendar, locale: Self.uk) == .some("Mon and Wed"))
        // Sunday comes last in a week that starts on Monday, first in one that starts on Sunday.
        #expect(TriggerDescriptions.days([1, 2], calendar: calendar, locale: Self.uk) == .some("Mon and Sun"))
        let sundayFirst = Self.calendar(locale: "en_US", firstWeekday: 1)
        #expect(TriggerDescriptions.days([1, 2], calendar: sundayFirst, locale: Self.us) == .some("Sun and Mon"))
        #expect(TriggerDescriptions.days([2, 4, 6], calendar: sundayFirst, locale: Self.us) == .some("Mon, Wed, and Fri"))
    }

    @Test func theWeekOrderStartsOnTheFirstWeekday() {
        #expect(TriggerDescriptions.weekOrder(Self.calendar(firstWeekday: 2)) == [2, 3, 4, 5, 6, 7, 1])
        #expect(TriggerDescriptions.weekOrder(Self.calendar(firstWeekday: 1)) == [1, 2, 3, 4, 5, 6, 7])
        #expect(TriggerDescriptions.weekOrder(Self.calendar(firstWeekday: 7)) == [7, 1, 2, 3, 4, 5, 6])
    }

    // MARK: - Rules

    @Test func rulesReadAsTheSpecWritesThem() {
        let group = Self.group
        let monitor = DisplayIdentity.monitor("LG UltraFine")
        #expect(summary(.at(9, 0, days: TriggerTime.weekdays, group: group)) == "At 09:00 on weekdays: start")
        #expect(Self.plain(summary(.at(9, 0, days: TriggerTime.weekdays, group: group), locale: Self.us)) == "At 9:00 AM on weekdays: start")
        #expect(summary(.at(18, 30, group: group, action: .finish)) == "At 18:30 every day: finish")
        #expect(summary(.at(10, 0, days: [1, 7], group: group, action: .openAll)) == "At 10:00 on weekends: open all")
        #expect(summary(.at(8, 15, days: [3, 5], group: group)) == "At 08:15 on Tue and Thu: start")
        #expect(summary(.on(.login, group: group, action: .showPopup)) == "At login: show the popup")
        #expect(summary(.on(.appOpens, group: group)) == "When Cybokron Dock Groups opens: start")
        #expect(summary(.on(.screensWake, group: group, action: .openAll)) == "When the screens wake: open all")
        #expect(summary(.on(.screensSleep, group: group, action: .finish)) == "When the screens sleep: finish")
        #expect(summary(.on(.condition(.display(.display(monitor)), edge: .starts), group: group, action: .openAll)) == "When “LG UltraFine” connects: open all")
        #expect(summary(.on(.condition(.display(.anyExternal), edge: .ends), group: group, action: .finish)) == "When a display disconnects: finish")
        #expect(summary(.on(.condition(.wifi(WiFiNetworkName("Office")!), edge: .ends), group: group, action: .finish)) == "When the Mac leaves “Office”: finish")
        #expect(summary(.on(.condition(.ethernet, edge: .starts), group: group)) == "When Ethernet connects: start")
        #expect(summary(.on(.condition(.vpn, edge: .ends), group: group, action: .finish)) == "When a VPN disconnects: finish")
        #expect(summary(.on(.unsupported(.object(["kind": .string("bluetooth")])), group: group)) == "A trigger made by a newer version: start")
    }

    @Test func aStartThatFinishesWhenItsEventEndsSaysSo() {
        let trigger = GroupTrigger.on(.condition(.display(.display(.monitor("VX2776-4K-mhd"))), edge: .starts), group: Self.group, finishesWhenEventEnds: true)
        #expect(trigger.finishesWhenEventEnds)
        #expect(summary(trigger) == "When “VX2776-4K-mhd” connects: start, finish when it ends")
    }

    // MARK: - Last runs

    @Test func lastRunsSayWhenAndWhat() {
        let calendar = Self.calendar()
        let now = TriggerTime.date(2026, 10, 28, 10, 0)
        let today = TriggerTime.date(2026, 10, 28, 9, 0)
        let yesterday = TriggerTime.date(2026, 10, 27, 9, 0)
        func line(_ entry: TriggerState.Entry) -> String {
            TriggerDescriptions.lastRun(entry, groupName: "Work", now: now, calendar: calendar, locale: Self.uk)
        }
        #expect(line(.init()) == "Not run yet.")
        #expect(line(.init(lastRunAt: today, lastOutcome: .ran(.start), lastOutcomeAt: today)) == "Last ran today at 09:00: started “Work”.")
        #expect(line(.init(lastOutcome: .ran(.openAll), lastOutcomeAt: yesterday)) == "Last ran yesterday at 09:00: opened “Work”.")
        #expect(line(.init(lastOutcome: .ran(.showPopup), lastOutcomeAt: today)) == "Last ran today at 09:00: showed “Work”.")
        #expect(line(.init(lastOutcome: .ran(.finish), lastOutcomeAt: today)) == "Last ran today at 09:00: finished “Work”.")
        #expect(line(.init(lastOutcome: .skipped(.paused), lastOutcomeAt: today)) == "Skipped today at 09:00: triggers were paused.")
        #expect(line(.init(lastOutcome: .missed(.macAsleep), lastOutcomeAt: yesterday)) == "Missed yesterday at 09:00: the Mac was asleep.")
        // Without when it happened: the last run's time, else no time at all.
        #expect(line(.init(lastRunAt: today, lastOutcome: .skipped(.notNow))) == "Skipped today at 09:00: you chose Not Now.")
        #expect(line(.init(lastOutcome: .skipped(.notNow))) == "Skipped recently: you chose Not Now.")
    }

    @Test func olderRunsShowTheirDate() {
        let calendar = Self.calendar()
        let now = TriggerTime.date(2026, 10, 28, 10, 0)
        let lastWeek = TriggerTime.date(2026, 10, 21, 9, 0)
        let text = TriggerDescriptions.lastRun(.init(lastOutcome: .missed(.appNotOpen), lastOutcomeAt: lastWeek), groupName: "Work", now: now, calendar: calendar, locale: Self.uk)
        #expect(text.hasPrefix("Missed "))
        #expect(text.hasSuffix(": the app wasn't open."))
        #expect(text.contains("21"))
        #expect(text.contains("09:00"))
        #expect(!text.contains("today") && !text.contains("yesterday"))
    }

    @Test func todayAndYesterdayFollowTheCalendarsTimeZone() {
        // 23:30 in Istanbul is 20:30 UTC: still the same day there, whatever the Mac's zone.
        let istanbul = Self.calendar()
        let now = TriggerTime.date(2026, 10, 29, 0, 30)
        let lateLastNight = TriggerTime.date(2026, 10, 28, 23, 30)
        #expect(TriggerDescriptions.moment(lateLastNight, now: now, calendar: istanbul, locale: Self.uk) == "yesterday at 23:30")
        #expect(TriggerDescriptions.moment(now, now: now, calendar: istanbul, locale: Self.uk) == "today at 00:30")
    }
}
