import Foundation

/// The words a trigger is shown with (triggers spec §1.14): its rule ("At 9:00 on weekdays:
/// start"), its time and days, and what happened the last time ("Last ran today at 9:00: started
/// “Work”."). Times follow the user's locale (`DateFormatter` templates, never hand-made); weekday
/// names come from the calendar, in its week's order.
public enum TriggerDescriptions {
    // MARK: - Times and days

    /// `minuteOfDay` as the locale writes a time: "9:00", "09:00", "9:00 AM". Worked out in UTC, where
    /// every minute of the day exists, so no clock change can shift it.
    public static func time(_ minuteOfDay: Int, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let clamped = max(0, min(minuteOfDay, TriggerSchedule.minutesPerDay - 1))
        let date = Date(timeIntervalSince1970: TimeInterval(clamped * 60))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// How a set of days reads.
    public enum Days: Equatable, Sendable {
        case everyDay
        /// The calendar's working days.
        case weekdays
        /// The calendar's weekend.
        case weekends
        /// Some days: their short names in the week's order, joined as the locale joins a list.
        case some(String)
    }

    public static func days(_ weekdays: Set<Int>, calendar: Calendar, locale: Locale) -> Days {
        if weekdays == TriggerSchedule.everyDay { return .everyDay }
        let weekend = TriggerSchedule.weekendDays(in: calendar)
        if !weekend.isEmpty, weekdays == weekend { return .weekends }
        if weekdays == TriggerSchedule.workingDays(in: calendar) { return .weekdays }
        var named = calendar
        named.locale = locale
        let symbols = named.shortWeekdaySymbols
        let names = weekOrder(calendar).filter(weekdays.contains).compactMap { day in
            symbols.indices.contains(day - 1) ? symbols[day - 1] : nil
        }
        let list = ListFormatter()
        list.locale = locale
        return .some(list.string(from: names) ?? names.joined(separator: ", "))
    }

    /// Gregorian weekday numbers in the order `calendar`'s week runs (its first weekday first).
    public static func weekOrder(_ calendar: Calendar) -> [Int] {
        let first = (1...7).contains(calendar.firstWeekday) ? calendar.firstWeekday : 1
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    // MARK: - Rules

    /// What the event waits for: "At 9:00 on weekdays", "At login", "When the screens wake".
    /// `appName` names Cybokron Dock Groups (for "When … opens").
    public static func event(_ event: TriggerEvent, appName: String, calendar: Calendar, locale: Locale) -> String {
        switch event {
        case .schedule(let schedule):
            let time = time(schedule.minuteOfDay, locale: locale)
            switch days(schedule.weekdays, calendar: calendar, locale: locale) {
            case .everyDay: return Localization.format("core.trigger.summary.time.everyDay", "At %@ every day", time)
            case .weekdays: return Localization.format("core.trigger.summary.time.weekdays", "At %@ on weekdays", time)
            case .weekends: return Localization.format("core.trigger.summary.time.weekends", "At %@ on weekends", time)
            case .some(let names): return Localization.format("core.trigger.summary.time.days", "At %1$@ on %2$@", time, names)
            }
        case .login:
            return Localization.string("core.trigger.summary.login", "At login")
        case .appOpens:
            return Localization.format("core.trigger.summary.appOpens", "When %@ opens", appName)
        case .screensWake:
            return Localization.string("core.trigger.summary.screensWake", "When the screens wake")
        case .screensSleep:
            return Localization.string("core.trigger.summary.screensSleep", "When the screens sleep")
        case .screenLocks:
            return Localization.string("core.trigger.summary.screenLocks", "When the screen locks")
        case .screenUnlocks:
            return Localization.string("core.trigger.summary.screenUnlocks", "When the screen unlocks")
        case .condition(let condition, let edge):
            return Self.condition(condition, edge: edge)
        case .unsupported:
            return Localization.string("core.trigger.summary.unsupported", "A trigger made by a newer version")
        case .applicationPresence(let bundleIdentifier, let edge):
            return edge == .starts
                ? Localization.format("core.trigger.summary.application.opens", "When %@ opens", bundleIdentifier)
                : Localization.format("core.trigger.summary.application.closes", "When %@ closes", bundleIdentifier)
        }
    }

    private static func condition(_ condition: TriggerCondition, edge: TriggerEdge) -> String {
        let starts = edge == .starts
        switch condition {
        case .display(.anyExternal):
            return starts
                ? Localization.string("core.trigger.summary.display.anyConnects", "When a display connects")
                : Localization.string("core.trigger.summary.display.anyDisconnects", "When a display disconnects")
        case .display(.display(let identity)):
            let name = identity.name
            return starts
                ? Localization.format("core.trigger.summary.display.connects", "When “%@” connects", name)
                : Localization.format("core.trigger.summary.display.disconnects", "When “%@” disconnects", name)
        case .displays:
            return starts
                ? Localization.string("core.trigger.summary.displays.connected", "When these displays are connected")
                : Localization.string("core.trigger.summary.displays.disconnected", "When these displays are no longer connected")
        case .wifi(let network):
            let name = network.name
            return starts
                ? Localization.format("core.trigger.summary.wifi.joins", "When the Mac joins “%@”", name)
                : Localization.format("core.trigger.summary.wifi.leaves", "When the Mac leaves “%@”", name)
        case .ethernet:
            return starts
                ? Localization.string("core.trigger.summary.ethernet.connects", "When Ethernet connects")
                : Localization.string("core.trigger.summary.ethernet.disconnects", "When Ethernet disconnects")
        case .vpn:
            return starts
                ? Localization.string("core.trigger.summary.vpn.connects", "When a VPN connects")
                : Localization.string("core.trigger.summary.vpn.disconnects", "When a VPN disconnects")
        }
    }

    /// The action as it completes a rule: "start", "open all", "show the popup", "finish".
    public static func action(_ action: TriggerAction) -> String {
        switch action {
        case .showPopup: return Localization.string("core.trigger.summary.action.showPopup", "show the popup")
        case .openAll: return Localization.string("core.trigger.summary.action.openAll", "open all")
        case .start: return Localization.string("core.trigger.summary.action.start", "start")
        case .finish: return Localization.string("core.trigger.summary.action.finish", "finish")
        }
    }

    /// The whole rule: "At 9:00 on weekdays: start"; with "Finish when it ends", "…: start, finish
    /// when it ends".
    public static func summary(_ trigger: GroupTrigger, appName: String, calendar: Calendar, locale: Locale) -> String {
        let event = event(trigger.event, appName: appName, calendar: calendar, locale: locale)
        let action = action(trigger.action)
        if trigger.finishesWhenEventEnds {
            return Localization.format("core.trigger.summary.ruleFinishing", "%1$@: %2$@, finish when it ends", event, action)
        }
        return Localization.format("core.trigger.summary.rule", "%1$@: %2$@", event, action)
    }

    /// A delay as the trigger rows show it, the one set or the time left while it waits: "After
    /// 30 s" (the words an item's launch delay is shown with).
    public static func delay(_ seconds: Int) -> String {
        Localization.format("item.launch.row.delay", "After %ld s", seconds)
    }

    /// The line under a notice's title: what the trigger waits for ("When com.example.app opens"),
    /// or, for a change that happened while the Mac couldn't act (`TriggerNotice.isCatchUp`), that
    /// the app opened or quit meanwhile ("com.example.app opened while the Mac was asleep").
    public static func noticeDetail(_ trigger: GroupTrigger, isCatchUp: Bool, appName: String, calendar: Calendar, locale: Locale) -> String {
        if isCatchUp, case .applicationPresence(let bundleIdentifier, let edge) = trigger.event {
            return edge == .starts
                ? Localization.format("core.trigger.afterWake.opened", "%@ opened while the Mac was asleep", bundleIdentifier)
                : Localization.format("core.trigger.afterWake.closed", "%@ quit while the Mac was asleep", bundleIdentifier)
        }
        return event(trigger.event, appName: appName, calendar: calendar, locale: locale)
    }

    // MARK: - What happened

    /// A moment as the last-run line says it: "today at 9:00", "yesterday at 9:00", or the date and
    /// time.
    public static func moment(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        if calendar.isDate(date, inSameDayAs: now) {
            let text = time.string(from: date)
            return Localization.format("core.trigger.lastRun.todayAt", "today at %@", text)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            let text = time.string(from: date)
            return Localization.format("core.trigger.lastRun.yesterdayAt", "yesterday at %@", text)
        }
        let full = DateFormatter()
        full.locale = locale
        full.timeZone = calendar.timeZone
        full.dateStyle = .medium
        full.timeStyle = .short
        return full.string(from: date)
    }

    /// What happened the last time the trigger's event came: "Last ran today at 9:00: started
    /// “Work”.", "Skipped today at 9:00: triggers were paused.", "Missed at 9:00: the Mac was
    /// asleep.", "Not run yet." For a change that happened while the Mac couldn't act
    /// (`TriggerState.Entry.isCatchUp`) the moment says so: "Last ran today at 9:00 (after the Mac
    /// woke): started “Work”."; missed, it says why it didn't catch up.
    public static func lastRun(_ entry: TriggerState.Entry, groupName: String, now: Date, calendar: Calendar, locale: Locale) -> String {
        guard let outcome = entry.lastOutcome else {
            return Localization.string("core.trigger.lastRun.never", "Not run yet.")
        }
        var when = (entry.lastOutcomeAt ?? entry.lastRunAt).map { moment($0, now: now, calendar: calendar, locale: locale) }
            ?? Localization.string("core.trigger.lastRun.recently", "recently")
        if entry.isCatchUp {
            when = Localization.format("core.trigger.lastRun.afterWake", "%@ (after the Mac woke)", when)
        }
        switch outcome {
        case .ran(.start):
            return Localization.format("core.trigger.lastRun.started", "Last ran %1$@: started “%2$@”.", when, groupName)
        case .ran(.openAll):
            return Localization.format("core.trigger.lastRun.opened", "Last ran %1$@: opened “%2$@”.", when, groupName)
        case .ran(.showPopup):
            return Localization.format("core.trigger.lastRun.shown", "Last ran %1$@: showed “%2$@”.", when, groupName)
        case .ran(.finish):
            return Localization.format("core.trigger.lastRun.finished", "Last ran %1$@: finished “%2$@”.", when, groupName)
        case .skipped(let reason):
            let why = reason.explanation
            return Localization.format("core.trigger.lastRun.skipped", "Skipped %1$@: %2$@.", when, why)
        case .missed(let reason):
            let why = entry.isCatchUp
                ? Localization.string("core.trigger.missed.afterWake", "it changed too long ago, or too many triggers caught up at once")
                : reason.explanation
            return Localization.format("core.trigger.lastRun.missed", "Missed %1$@: %2$@.", when, why)
        }
    }
}
