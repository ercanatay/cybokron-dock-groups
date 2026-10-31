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
        // Wi-Fi and Ethernet are edited here since phase 4b PR 4; a VPN isn't (TS-8).
        #expect(TriggerDraft(editing: wifi, calendar: Self.calendar)?.event == wifi.event)
        let vpn = GroupTrigger.on(.condition(.vpn, edge: .starts), group: group)
        #expect(TriggerDraft(editing: vpn, calendar: Self.calendar) == nil)
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

    @Test func applicationEventsUseExactIdentifier() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.applicationBundleIdentifier = "My.Custom-App-123"
        draft.setWhen(.application(.starts))
        #expect(draft.event == .applicationPresence(bundleIdentifier: "My.Custom-App-123", edge: .starts))
        draft.setWhen(.application(.ends))
        #expect(draft.event == .applicationPresence(bundleIdentifier: "My.Custom-App-123", edge: .ends))
    }

    @Test func invalidOrEmptyApplicationIdentifierMakesDraftInvalid() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.applicationBundleIdentifier = ""
        draft.setWhen(.application(.starts))
        #expect(!draft.isValid)
        draft.applicationBundleIdentifier = "bad id!"
        #expect(!draft.isValid)
    }

    @Test func applicationActionsNormalizeCorrectly() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.applicationBundleIdentifier = "com.example.App"
        draft.setWhen(.application(.starts))
        draft.setAction(.finish)
        #expect(draft.action == .finish)
        draft.setAction(.start)
        #expect(draft.action == .start)
        draft.setAction(.showPopup)
        #expect(draft.action == .showPopup)
    }

    @Test func applicationCasesAreAbsentFromOffered() {
        #expect(!TriggerDraft.When.offered.contains(where: {
            if case .application = $0 { return true }
            return false
        }))
    }

    @Test func editingApplicationPresencePreservesRule() throws {
        for edge in [TriggerEdge.starts, .ends] {
            let trigger = GroupTrigger(groupID: Self.group.id, event: .applicationPresence(bundleIdentifier: "com.Example.App", edge: edge), action: .start, runMode: .askFirst, isEnabled: false, oncePerDay: true)
            let draft = try #require(TriggerDraft(editing: trigger, calendar: Self.calendar))
            #expect(draft.when == .application(edge))
            #expect(draft.applicationBundleIdentifier == "com.Example.App")
            #expect(draft.trigger(groupID: UUID(), replacing: trigger) == trigger)
        }
    }

    @Test func editingInvalidApplicationIdentifierCannotBeSaved() throws {
        let trigger = GroupTrigger(groupID: Self.group.id, event: .applicationPresence(bundleIdentifier: "bad id", edge: .starts), action: .start)
        let draft = try #require(TriggerDraft(editing: trigger, calendar: Self.calendar))
        #expect(draft.applicationBundleIdentifier == "bad id")
        #expect(!draft.isValid)
    }

    @Test func selectApplicationKeepsTheExactOriginalIdentifierAndReturnsTrue() {
        var draft = TriggerDraft(calendar: Self.calendar)
        let app = AppReference(bundleIdentifier: "My.Custom-App-123", name: "Custom")
        let result = draft.selectApplication(app)
        #expect(result)
        #expect(draft.applicationBundleIdentifier == "My.Custom-App-123")
        draft.setWhen(.application(.starts))
        #expect(draft.event == .applicationPresence(bundleIdentifier: "My.Custom-App-123", edge: .starts))
    }

    @Test func selectApplicationAcceptsMixedCaseExactId() {
        var draft = TriggerDraft(calendar: Self.calendar)
        let app = AppReference(bundleIdentifier: "MY.APP", name: "Upper")
        let resultMixed = draft.selectApplication(app)
        #expect(resultMixed)
        #expect(draft.applicationBundleIdentifier == "MY.APP")
    }

    @Test func selectApplicationRejectsNonAppsAndPaths() {
        var draft = TriggerDraft(calendar: Self.calendar)
        let file = AppReference(bundleIdentifier: "/Users/me/notes.txt", name: "notes", path: "/Users/me/notes.txt")
        let folder = AppReference(fileURL: URL(fileURLWithPath: "/Users/me/Pictures/"), kind: .folder, name: "Pictures")
        let fileResult = draft.selectApplication(file)
        #expect(!fileResult)
        let folderResult = draft.selectApplication(folder)
        #expect(!folderResult)
        // Non-path identifiers the validator rejects.
        let badURL = AppReference(bundleIdentifier: "http://example.com", name: "url")
        let spaces = AppReference(bundleIdentifier: "foo bar", name: "space")
        let newline = AppReference(bundleIdentifier: "foo\nbar", name: "nl")
        let tab = AppReference(bundleIdentifier: "\tfoo", name: "tab")
        let badURLResult = draft.selectApplication(badURL)
        #expect(!badURLResult)
        let spacesResult = draft.selectApplication(spaces)
        #expect(!spacesResult)
        let newlineResult = draft.selectApplication(newline)
        #expect(!newlineResult)
        let tabResult = draft.selectApplication(tab)
        #expect(!tabResult)
        #expect(draft.applicationBundleIdentifier == "")
    }

    @Test func selectApplicationLeavesAPreviousSelectionOnFailure() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.applicationBundleIdentifier = "com.existing.App"
        let rejected = AppReference(websiteURL: URL(string: "http://bad")!, name: "bad")
        let rejectedResult = draft.selectApplication(rejected)
        #expect(!rejectedResult)
        #expect(draft.applicationBundleIdentifier == "com.existing.App")
    }
}
