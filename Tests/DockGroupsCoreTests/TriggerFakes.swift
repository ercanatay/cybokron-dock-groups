import Foundation
@testable import DockGroupsCore

/// Records what triggers asked the app to do: "start:<group>:<trigger>",
/// "finish:<group>:<trigger>:<shows previous>", "openAll:<group>", "popup:<group>". Starting makes
/// the group current, as `ContextSession` does.
@MainActor
final class FakeAutomationHandler: AutomationHandling {
    var groups: [DockGroup]
    var current: DockGroup.ID?
    var trigger: TransitionTrigger?
    /// The outcome of the next Starts (`.repeated` for "just started").
    var startOutcome: TransitionReport.Outcome = .done
    private(set) var calls: [String] = []
    /// Called while an action runs, before it returns (to send signals in the middle of one).
    var duringAction: (() -> Void)?

    init(groups: [DockGroup]) {
        self.groups = groups
    }

    private func name(_ id: DockGroup.ID) -> String {
        groups.first { $0.id == id }?.name ?? id.uuidString
    }

    private func report(_ kind: TransitionPlan.Kind, _ id: DockGroup.ID, trigger: TransitionTrigger, outcome: TransitionReport.Outcome) -> TransitionReport {
        TransitionReport(outcome: outcome, plan: TransitionPlan(kind: kind, trigger: trigger, groupName: name(id), otherGroupName: nil))
    }

    func group(withID id: DockGroup.ID) -> DockGroup? { groups.first { $0.id == id } }
    var currentGroupID: DockGroup.ID? { current }
    var currentGroupStartTrigger: TransitionTrigger? { trigger }

    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport? {
        guard group(withID: id) != nil else { return nil }
        calls.append("start:\(name(id)):\(trigger.rawValue)")
        duringAction?()
        if startOutcome == .done {
            current = id
            self.trigger = trigger
        }
        return report(.start(id), id, trigger: trigger, outcome: startOutcome)
    }

    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport? {
        guard group(withID: id) != nil else { return nil }
        calls.append("finish:\(name(id)):\(trigger.rawValue):\(showsPrevious)")
        duringAction?()
        if current == id {
            current = nil
            self.trigger = nil
        }
        return report(.finish(id), id, trigger: trigger, outcome: .done)
    }

    func openAllItems(of group: DockGroup) async -> LaunchReport {
        calls.append("openAll:\(group.name)")
        duringAction?()
        return LaunchReport(groupName: group.name, entries: [])
    }

    func showPopup(of group: DockGroup) {
        calls.append("popup:\(group.name)")
        duringAction?()
    }

    /// The user (or anything but a trigger) started `id`.
    func userStarted(_ id: DockGroup.ID) {
        current = id
        trigger = .userAction
    }
}

/// Answers notices as told; `answers` are used in turn, then `defaultAnswer`. A notice can be left
/// waiting (`holds`) until `release` or `dismiss`.
@MainActor
final class FakeNoticePresenter: TriggerNoticePresenting {
    var answers: [TriggerNoticeAnswer] = []
    var defaultAnswer: TriggerNoticeAnswer = .run
    /// Whether notices wait for `release(_:)` (or `dismiss()`) instead of answering at once.
    var holds = false
    private(set) var shown: [TriggerNotice] = []
    private(set) var dismissCount = 0
    private var waiting: CheckedContinuation<TriggerNoticeAnswer, Never>?

    var isShowing: Bool { waiting != nil }

    func present(_ notice: TriggerNotice) async -> TriggerNoticeAnswer {
        shown.append(notice)
        if holds {
            return await withCheckedContinuation { waiting = $0 }
        }
        return answers.isEmpty ? defaultAnswer : answers.removeFirst()
    }

    func release(_ answer: TriggerNoticeAnswer) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: answer)
    }

    func dismiss() {
        dismissCount += 1
        release(.replaced)
    }
}

/// Triggers kept in memory; can fail to load, to move a file aside, or to save.
final class MemoryTriggerPersistence: TriggerPersisting {
    struct Failure: Error {}

    private(set) var saveCount = 0
    private(set) var saved: [GroupTrigger]
    var failsToLoad = false
    var failsToMoveAside = false
    var failsToSave = false
    private(set) var movedAside = false
    private(set) var copies: [String] = []

    init(_ triggers: [GroupTrigger] = []) {
        saved = triggers
    }

    func loadTriggers() throws -> [GroupTrigger] {
        if failsToLoad { throw Failure() }
        return saved
    }

    func saveTriggers(_ triggers: [GroupTrigger]) throws {
        if failsToSave { throw Failure() }
        saved = triggers
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? {
        if failsToMoveAside { throw Failure() }
        movedAside = true
        return URL(fileURLWithPath: "/tmp/triggers.unreadable.json")
    }

    func preserveCopy(label: String) throws -> URL? {
        copies.append(label)
        return URL(fileURLWithPath: "/tmp/triggers.\(label).json")
    }
}

/// A trigger state kept in memory, saves counted.
final class MemoryTriggerStatePersistence: TriggerStatePersisting {
    private(set) var saveCount = 0
    private(set) var saved: TriggerState

    init(_ state: TriggerState = TriggerState()) {
        saved = state
    }

    func loadState() -> TriggerState { saved }

    func saveState(_ state: TriggerState) throws {
        saved = state
        saveCount += 1
    }
}

/// Dates and calendars for trigger tests.
enum TriggerTime {
    /// A Gregorian calendar in `zone` (Istanbul by default: no daylight saving time since 2016).
    static func calendar(_ zone: String = "Europe/Istanbul", locale: String = "en_US_POSIX") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    /// A wall-clock moment in `calendar`.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, in calendar: Calendar = calendar()) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// Monday to Friday.
    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
}

extension GroupTrigger {
    /// A trigger of `group` at hour:minute on `days` (every day by default).
    static func at(_ hour: Int, _ minute: Int, days: Set<Int> = TriggerSchedule.everyDay, group: DockGroup, action: TriggerAction = .start, runMode: TriggerRunMode? = .immediately, id: UUID = UUID()) -> GroupTrigger {
        GroupTrigger(id: id, groupID: group.id, event: .schedule(TriggerSchedule(hour: hour, minute: minute, weekdays: days)), action: action, runMode: runMode)
    }

    /// A trigger of `group` on `event`, running right away unless told otherwise.
    static func on(_ event: TriggerEvent, group: DockGroup, action: TriggerAction = .start, runMode: TriggerRunMode? = .immediately, finishesWhenEventEnds: Bool = false, oncePerDay: Bool = false, id: UUID = UUID()) -> GroupTrigger {
        GroupTrigger(id: id, groupID: group.id, event: event, action: action, runMode: runMode, oncePerDay: oncePerDay, finishesWhenEventEnds: finishesWhenEventEnds)
    }
}

extension DisplayIdentity {
    /// An external monitor.
    static func monitor(_ name: String, vendor: UInt32 = 23139, model: UInt32 = 28983, serial: UInt32? = nil) -> DisplayIdentity {
        DisplayIdentity(vendor: vendor, model: model, serial: serial, name: name, isBuiltIn: false)
    }

    static let builtIn = DisplayIdentity(vendor: 1552, model: 41_234, serial: nil, name: "Built-in Retina Display", isBuiltIn: true)
}
