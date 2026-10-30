import Foundation
import Testing
@testable import DockGroupsCore

@Suite("TriggerApplicationEventCodingTests")
struct TriggerApplicationEventCodingTests {
    private static let group = UUID(uuidString: "0C0D1E00-0000-4000-8000-000000000080")!
    private static let id = UUID(uuidString: "7A1660E0-0000-4000-8000-000000000011")!

    private func decodeEvent(_ text: String) throws -> TriggerEvent {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return TriggerEvent(json: raw)
    }

    private func encodeEvent(_ event: TriggerEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(event.json), as: UTF8.self)
    }

    @Test func validStartsEncodesAndDecodes() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"com.example.app","edge":"starts"}"#
        let event = try decodeEvent(json)
        #expect(event == .applicationPresence(bundleIdentifier: "com.example.app", edge: .starts))
        #expect(!event.isValid)
        #expect(event.isEdge)
        #expect(event.kindName == "applicationPresence")
        #expect(event.allowedActions == TriggerAction.allCases)
        #expect(event.isUnsupported == false)
        let encoded = try encodeEvent(event)
        #expect(encoded.contains(#""bundleIdentifier" : "com.example.app""#))
        #expect(encoded.contains(#""edge" : "starts""#))
        #expect(encoded.contains(#""kind" : "applicationPresence""#))
    }

    @Test func validEndsEncodesAndDecodesExactSpelling() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"My.Custom-App-123","edge":"ends"}"#
        let event = try decodeEvent(json)
        #expect(event == .applicationPresence(bundleIdentifier: "My.Custom-App-123", edge: .ends))
        let encoded = try encodeEvent(event)
        #expect(encoded.contains(#""bundleIdentifier" : "My.Custom-App-123""#))
        let round = try decodeEvent(encoded)
        #expect(round == event)
    }

    @Test func invalidExtraKeyPreservesRawUnsupported() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"com.example.app","edge":"starts","extra":1}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
        let raw = if case .unsupported(let r) = event { r } else { JSONValue.null }
        #expect(raw["extra"] == .integer(1))
        #expect(raw["bundleIdentifier"] == .string("com.example.app"))
    }

    @Test func missingBundlePreservesRaw() throws {
        let json = #"{"kind":"applicationPresence","edge":"starts"}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
    }

    @Test func unknownEdgePreservesRaw() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"com.example.app","edge":"sideways"}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
    }

    @Test func invalidIdentifierPreservesRaw() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"bad id!","edge":"starts"}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
    }

    @Test func emptyBundlePreservesRaw() throws {
        let json = #"{"kind":"applicationPresence","bundleIdentifier":"","edge":"starts"}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
    }

    @Test func noRunningOrEditingForValidFutureEvent() throws {
        let trigger = GroupTrigger(groupID: Self.group, event: .applicationPresence(bundleIdentifier: "com.apple.Safari", edge: .starts), action: .start)
        #expect(!trigger.canRun)
        #expect(!trigger.isRunnable)
        #expect(trigger.isEnabled)
        #expect(trigger.event.isValid == false)
        #expect(trigger.event.allowedActions.contains(.finish))
        #expect(TriggerDraft(editing: trigger, calendar: Calendar(identifier: .gregorian)) == nil)
    }

    @Test func existingUnknownBehaviorUnchanged() throws {
        let json = #"{"kind":"calendarEvent","title":"Work"}"#
        let event = try decodeEvent(json)
        #expect(event.isUnsupported)
        #expect(!event.isValid)
        #expect(event.allowedActions == [])
    }

    @Test func fullRuleRoundTripsWhileRemainingUnrunnable() throws {
        let original = GroupTrigger(id: Self.id, groupID: Self.group,
            event: .applicationPresence(bundleIdentifier: "My.Custom-App-123", edge: .ends),
            action: .start, isEnabled: true)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GroupTrigger.self, from: data)
        #expect(restored == original)
        #expect(!restored.canRun)
    }

    @Test func fullRulePreservesUnknownEventFieldsAcrossRoundTrip() throws {
        let rawEvent: JSONValue = .object([
            "kind": .string("applicationPresence"),
            "bundleIdentifier": .string("com.example.App"),
            "edge": .string("starts"),
            "future": .object(["values": .array([.integer(7), .string("x")])]),
        ])
        let original = GroupTrigger(id: Self.id, groupID: Self.group,
            event: .unsupported(rawEvent), action: .start, isEnabled: true)
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GroupTrigger.self, from: encoded)
        #expect(restored.event == .unsupported(rawEvent))
        #expect(!restored.canRun)
        let reencoded = try JSONEncoder().encode(restored)
        let json = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(json["event"] == rawEvent)
    }
}
