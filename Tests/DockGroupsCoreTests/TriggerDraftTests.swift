import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: the editor's draft")
struct TriggerDraftTests {
    private static let group = DockGroup.of("Work", ["com.apple.mail"])
    private static let calendar = TriggerTime.calendar(locale: "en_GB")

    @Test func aNewTriggerStartsAtNineOnWeekdaysWithANotice() {
        let draft = TriggerDraft(calendar: Self.calendar)
        #expect(draft.kind == .time)
        #expect(draft.minuteOfDay == 9 * 60)
        #expect(draft.weekdays == TriggerTime.weekdays)
        #expect(draft.action == .start)
        #expect(draft.runMode == .notice)
        #expect(!draft.oncePerDay)
        #expect(draft.isValid)
        #expect(draft.event == .schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: TriggerTime.weekdays)))
    }

    @Test func eachEventOffersOnlyItsActions() {
        var draft = TriggerDraft(calendar: Self.calendar)
        #expect(draft.allowedActions == TriggerAction.allCases)
        draft.setKind(.screensSleep)
        #expect(draft.allowedActions == [.finish])
        #expect(draft.action == .finish)
        #expect(draft.event == .screensSleep)
        draft.setKind(.login)
        #expect(draft.allowedActions == [.showPopup, .openAll, .start])
        #expect(draft.action == .start, "Finish isn't offered at login: Start instead")
        draft.setAction(.finish)
        #expect(draft.action == .start, "an action the event doesn't allow isn't taken")
        draft.setKind(.time)
        draft.setAction(.finish)
        #expect(draft.action == .finish)
        draft.setKind(.appOpens)
        #expect(draft.action == .start)
    }

    @Test func showThePopupRunsRightAwayOnly() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setRunMode(.askFirst)
        #expect(draft.runMode == .askFirst)
        draft.setAction(.showPopup)
        #expect(draft.runMode == .immediately)
        #expect(draft.allowedRunModes == [.immediately])
        draft.setRunMode(.notice)
        #expect(draft.runMode == .immediately, "a run mode the popup doesn't allow isn't taken")
        // Back to an action with a notice: the default notice again.
        draft.setAction(.openAll)
        #expect(draft.runMode == .notice)
        #expect(draft.allowedRunModes == TriggerRunMode.allCases)
        // A popup at the screens' sleep isn't allowed: Finish, with a notice.
        draft.setAction(.showPopup)
        draft.setKind(.screensSleep)
        #expect(draft.action == .finish)
        #expect(draft.runMode == .notice)
    }

    @Test func aTimeNeedsADay() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.weekdays = []
        #expect(!draft.isValid)
        draft.weekdays = [1]
        #expect(draft.isValid)
        // Other events have no days.
        draft.weekdays = []
        draft.setKind(.login)
        #expect(draft.isValid)
    }

    @Test func editingKeepsTheTriggersIdentityAndSwitch() throws {
        var existing = GroupTrigger.at(7, 45, days: [2, 4], group: Self.group, action: .openAll, runMode: .askFirst)
        existing.isEnabled = false
        existing.oncePerDay = true
        var draft = try #require(TriggerDraft(editing: existing, calendar: Self.calendar))
        #expect(draft.kind == .time)
        #expect(draft.minuteOfDay == 7 * 60 + 45)
        #expect(draft.weekdays == [2, 4])
        #expect(draft.action == .openAll)
        #expect(draft.runMode == .askFirst)
        #expect(draft.oncePerDay)
        draft.minuteOfDay = 8 * 60
        let edited = draft.trigger(groupID: UUID(), replacing: existing)
        #expect(edited.id == existing.id)
        #expect(edited.groupID == Self.group.id)
        #expect(!edited.isEnabled)
        #expect(edited.event == .schedule(TriggerSchedule(hour: 8, minute: 0, weekdays: [2, 4])))
        // Unchanged, the trigger comes back as it was.
        let same = try #require(TriggerDraft(editing: existing, calendar: Self.calendar)).trigger(groupID: Self.group.id, replacing: existing)
        #expect(same == existing)
    }

    @Test func aNewTriggerIsOnAndBelongsToTheGroup() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setKind(.screensWake)
        draft.setAction(.showPopup)
        let trigger = draft.trigger(groupID: Self.group.id)
        #expect(trigger.groupID == Self.group.id)
        #expect(trigger.isEnabled)
        #expect(trigger.event == .screensWake)
        #expect(trigger.action == .showPopup)
        #expect(trigger.runMode == .immediately)
        #expect(trigger.canRun)
    }

    @Test func networkAndUnknownTriggersArentEditedHere() throws {
        let group = Self.group
        let display = GroupTrigger.on(.condition(.display(.anyExternal), edge: .starts), group: group)
        let wifi = GroupTrigger.on(.condition(.wifi(WiFiNetworkName("Office")!), edge: .ends), group: group, action: .finish)
        let unknown = GroupTrigger.on(.unsupported(.object(["kind": .string("bluetooth")])), group: group)
        // Display triggers are edited here since phase 4b PR 3.
        #expect(TriggerDraft(editing: display, calendar: Self.calendar)?.event == display.event)
        #expect(TriggerDraft(editing: wifi, calendar: Self.calendar) == nil)
        #expect(TriggerDraft(editing: unknown, calendar: Self.calendar) == nil)
        // An action a newer version wrote: editing would lose it.
        let json = #"{"id":"\#(UUID().uuidString)","groupID":"\#(group.id.uuidString)","enabled":true,"event":{"kind":"login"},"action":"dance"}"#
        let newer = try JSONDecoder().decode(GroupTrigger.self, from: Data(json.utf8))
        #expect(!newer.isRunnable)
        #expect(TriggerDraft(editing: newer, calendar: Self.calendar) == nil)
        // Login, opening and the screens are.
        for event in [TriggerEvent.login, .appOpens, .screensWake] {
            #expect(TriggerDraft(editing: .on(event, group: group), calendar: Self.calendar)?.event == event)
        }
        #expect(TriggerDraft(editing: .on(.screensSleep, group: group, action: .finish), calendar: Self.calendar)?.event == .screensSleep)
    }

    @Test func everyKindMakesItsEvent() {
        var draft = TriggerDraft(calendar: Self.calendar)
        let events: [TriggerDraft.Kind: TriggerEvent] = [
            .login: .login, .appOpens: .appOpens, .screensWake: .screensWake, .screensSleep: .screensSleep,
        ]
        for (kind, event) in events {
            draft.setKind(kind)
            #expect(draft.event == event)
            #expect(draft.allowedActions.contains(draft.action))
        }
        #expect(Set(TriggerDraft.Kind.allCases) == Set(events.keys).union([.time]))
    }
}
