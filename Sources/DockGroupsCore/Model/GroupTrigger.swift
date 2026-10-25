import Foundation

/// What a trigger does to its group (triggers spec §1.6): only these four, through the same paths a
/// click takes. A trigger never quits, force quits or closes an app; Start and Finish run as
/// `TransitionTrigger.automation`, whose quitting settings act as hiding.
public enum TriggerAction: String, Codable, CaseIterable, Sendable {
    case showPopup
    case openAll
    case start
    /// Only when the group is the current group (`TriggerCoordinator`).
    case finish
}

/// How a trigger runs (spec §1.7): a 5-second notice with Not Now (the default for Open All, Start
/// and Finish), a question that waits for an answer, or right away (Show the Popup's only way: its
/// popup is its own notice).
public enum TriggerRunMode: String, Codable, CaseIterable, Sendable {
    case notice
    case askFirst
    case immediately

    /// How `action` runs unless the user chose otherwise.
    public static func defaultMode(for action: TriggerAction) -> TriggerRunMode {
        action == .showPopup ? .immediately : .notice
    }
}

/// A time of day on chosen days of the week, in the Mac's current time zone (spec §1.3).
public struct TriggerSchedule: Hashable, Sendable {
    public static let minutesPerDay = 24 * 60
    /// Every day: weekday numbers 1 (Sunday) … 7 (Saturday), as the Gregorian calendar numbers them.
    public static let everyDay: Set<Int> = Set(1...7)

    /// Minutes since midnight, 0…1439.
    public var minuteOfDay: Int
    /// Gregorian weekday numbers, 1 (Sunday) … 7 (Saturday); not empty.
    public var weekdays: Set<Int>

    public init(minuteOfDay: Int, weekdays: Set<Int>) {
        self.minuteOfDay = minuteOfDay
        self.weekdays = weekdays
    }

    public init(hour: Int, minute: Int, weekdays: Set<Int>) {
        self.init(minuteOfDay: hour * 60 + minute, weekdays: weekdays)
    }

    public var hour: Int { minuteOfDay / 60 }
    public var minute: Int { minuteOfDay % 60 }

    public var isValid: Bool {
        (0..<Self.minutesPerDay).contains(minuteOfDay) && !weekdays.isEmpty && weekdays.allSatisfy { Self.everyDay.contains($0) }
    }

    /// The days `calendar` (its locale) counts as the weekend, as Gregorian weekday numbers:
    /// Saturday and Sunday in most regions, Friday and Saturday or only Friday in others. What the
    /// Weekends button fills in; the stored set doesn't follow later region changes.
    public static func weekendDays(in calendar: Calendar) -> Set<Int> {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        // A Sunday at noon, then the six days after it.
        guard let sunday = gregorian.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 12)) else { return [1, 7] }
        var weekend = Set<Int>()
        for offset in 0..<7 {
            guard let day = gregorian.date(byAdding: .day, value: offset, to: sunday) else { continue }
            if calendar.isDateInWeekend(day) {
                weekend.insert(gregorian.component(.weekday, from: day))
            }
        }
        return weekend
    }

    /// The days that aren't the weekend in `calendar` (what the Weekdays button fills in); every day
    /// when the region has no weekend.
    public static func workingDays(in calendar: Calendar) -> Set<Int> {
        let days = everyDay.subtracting(weekendDays(in: calendar))
        return days.isEmpty ? everyDay : days
    }
}

/// The two ends of a condition: it starts holding (a display connects) or stops (it disconnects).
public enum TriggerEdge: String, Codable, CaseIterable, Sendable {
    case starts
    case ends
}

/// Something that holds for a while: a display is connected, the Mac is on a network (spec §1.4,
/// §1.5). Its trigger runs when it starts or ends.
public enum TriggerCondition: Hashable, Sendable {
    case display(DisplayMatch)
    case displays(DisplayArrangement)
    /// Needs Location Services: macOS shows network names only to apps allowed to use it.
    case wifi(WiFiNetworkName)
    case ethernet
    /// Offered only if TS-8 shows macOS reports it reliably.
    case vpn

    public var isValid: Bool {
        switch self {
        case .display(let match): return match.isValid
        case .displays(let arrangement): return arrangement.isValid
        case .wifi(let name): return name.isValid
        case .ethernet, .vpn: return true
        }
    }

    /// Whether the signal is about this condition: displays for display conditions, the network
    /// for the others.
    var isAboutDisplays: Bool {
        switch self {
        case .display, .displays: return true
        case .wifi, .ethernet, .vpn: return false
        }
    }
}

/// What a trigger waits for (spec §1.3–§1.5).
public enum TriggerEvent: Hashable, Sendable {
    case schedule(TriggerSchedule)
    case login
    /// Cybokron Dock Groups opening (not after an update or a language restart).
    case appOpens
    case screensWake
    case screensSleep
    case condition(TriggerCondition, edge: TriggerEdge)
    /// An event this version doesn't understand — a newer version's kind, or a known kind it can't
    /// read: kept as read and written back unchanged; it never runs.
    case unsupported(JSONValue)

    /// The actions this event allows (spec §1.6).
    public var allowedActions: [TriggerAction] {
        switch self {
        case .schedule, .condition: return TriggerAction.allCases
        case .login, .appOpens, .screensWake: return [.showPopup, .openAll, .start]
        case .screensSleep: return [.finish]
        case .unsupported: return []
        }
    }

    /// Whether its values can be waited for (a valid time, display or network name).
    public var isValid: Bool {
        switch self {
        case .schedule(let schedule): return schedule.isValid
        case .condition(let condition, _): return condition.isValid
        case .login, .appOpens, .screensWake, .screensSleep: return true
        case .unsupported: return false
        }
    }

    /// Whether it's a change that settles (a display or a network), which the echo window holds back.
    public var isEdge: Bool {
        if case .condition = self { return true }
        return false
    }

    public var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }

    /// A word for the event's kind, for logs and diagnostics: never a time, a name or a display.
    public var kindName: String {
        switch self {
        case .schedule: return "schedule"
        case .login: return "login"
        case .appOpens: return "appOpens"
        case .screensWake: return "screensWake"
        case .screensSleep: return "screensSleep"
        case .condition(let condition, _):
            switch condition {
            case .display: return "display"
            case .displays: return "displays"
            case .wifi: return "wifi"
            case .ethernet: return "ethernet"
            case .vpn: return "vpn"
            }
        case .unsupported: return "unsupported"
        }
    }
}

/// "When this happens, do that to this group" (spec §1.2). A trigger names its group by identifier
/// and holds only an event from a closed set and one of four actions: no app, path, link, script or
/// command, so a file can't make one run anything but its group's own items, through the checks a
/// click goes through (spec §4.2 T-S1, T-S2).
///
/// A trigger that can't run — an unsupported event, values out of range, an action its event
/// doesn't allow, one this version doesn't know — is kept as it was saved; `canRun` is false for it,
/// whatever `isEnabled` says.
public struct GroupTrigger: Identifiable, Hashable, Sendable {
    /// The most triggers of one group.
    public static let maximumPerGroup = 10
    /// The most triggers in all.
    public static let maximumCount = 100

    public let id: UUID
    public var groupID: DockGroup.ID
    public var event: TriggerEvent {
        didSet { normalize() }
    }
    /// Setting it replaces an action this version didn't know.
    public var action: TriggerAction {
        didSet {
            unrecognizedAction = nil
            normalize()
        }
    }
    public var runMode: TriggerRunMode {
        didSet { normalize() }
    }
    public var isEnabled: Bool
    /// After it ran, it waits for the next calendar day.
    public var oncePerDay: Bool
    /// A Start trigger on a condition's start also finishes the group — hiding only — when the
    /// condition ends, if the group is still current and this trigger started it (spec §1.6).
    public var finishesWhenEventEnds: Bool {
        didSet { normalize() }
    }
    /// An action a newer version wrote that this one doesn't know; then the trigger doesn't run.
    private(set) var unrecognizedAction: String?

    public init(
        id: UUID = UUID(),
        groupID: DockGroup.ID,
        event: TriggerEvent,
        action: TriggerAction,
        runMode: TriggerRunMode? = nil,
        isEnabled: Bool = true,
        oncePerDay: Bool = false,
        finishesWhenEventEnds: Bool = false
    ) {
        self.id = id
        self.groupID = groupID
        self.event = event
        self.action = action
        self.runMode = runMode ?? TriggerRunMode.defaultMode(for: action)
        self.isEnabled = isEnabled
        self.oncePerDay = oncePerDay
        self.finishesWhenEventEnds = finishesWhenEventEnds
        normalize()
    }

    /// Whether the rule can run at all: an event this version understands with valid values, and an
    /// action that event allows.
    public var isRunnable: Bool {
        unrecognizedAction == nil && event.isValid && event.allowedActions.contains(action)
    }

    /// Whether it runs when its event comes: turned on and runnable.
    public var canRun: Bool { isEnabled && isRunnable }

    /// Why it can't run, for its row; `nil` when it can.
    public var problem: String? {
        if event.isUnsupported || unrecognizedAction != nil {
            return Localization.string("core.trigger.unsupported", "Made by a newer version of Cybokron Dock Groups: it doesn't run here.")
        }
        guard isRunnable else {
            return Localization.string("core.trigger.unrunnable", "Can't run: fix or remove it.")
        }
        return nil
    }

    /// Whether "Finish when it ends" applies: Start on a condition's start.
    public var canFinishWhenEventEnds: Bool {
        guard action == .start, case .condition(_, edge: .starts) = event else { return false }
        return true
    }

    /// Show the Popup always runs right away; "Finish when it ends" only where it applies.
    private mutating func normalize() {
        guard unrecognizedAction == nil else { return }
        if action == .showPopup, runMode != .immediately { runMode = .immediately }
        if finishesWhenEventEnds, !canFinishWhenEventEnds { finishesWhenEventEnds = false }
    }

    /// `triggers` as a store keeps them: each identifier once (the first), at most `maximumPerGroup`
    /// per group and `maximumCount` in all, in their order.
    public static func sanitized(_ triggers: [GroupTrigger]) -> [GroupTrigger] {
        var seen = Set<UUID>()
        var perGroup: [DockGroup.ID: Int] = [:]
        var kept: [GroupTrigger] = []
        for trigger in triggers where kept.count < maximumCount && seen.insert(trigger.id).inserted {
            let count = perGroup[trigger.groupID, default: 0]
            guard count < maximumPerGroup else { continue }
            perGroup[trigger.groupID] = count + 1
            kept.append(trigger)
        }
        return kept
    }
}

// MARK: - Codable

extension GroupTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, groupID, enabled, event, action, runMode, oncePerDay, finishesWhenEventEnds
    }

    /// The identifier and the group are required (an entry without them is left out by the file);
    /// everything else is read leniently: `enabled` that isn't `true` is off, an unknown run mode is
    /// the notice, an event this version can't read is kept as it was (`TriggerEvent.unsupported`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        groupID = try container.decode(UUID.self, forKey: .groupID)
        let rawEvent = container.decodeLeniently(JSONValue.self, forKey: .event) ?? .null
        event = TriggerEvent(json: rawEvent)
        let rawAction = container.decodeLeniently(String.self, forKey: .action)
        if let rawAction, let known = TriggerAction(rawValue: rawAction) {
            action = known
            unrecognizedAction = nil
        } else {
            action = .showPopup
            unrecognizedAction = rawAction ?? ""
        }
        runMode = container.decodeLeniently(TriggerRunMode.self, forKey: .runMode) ?? .notice
        isEnabled = container.decodeLeniently(Bool.self, forKey: .enabled) ?? false
        oncePerDay = container.decodeLeniently(Bool.self, forKey: .oncePerDay) ?? false
        finishesWhenEventEnds = container.decodeLeniently(Bool.self, forKey: .finishesWhenEventEnds) ?? false
        normalize()
    }

    /// The options are written only when on.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(isEnabled, forKey: .enabled)
        try container.encode(event.json, forKey: .event)
        try container.encode(unrecognizedAction ?? action.rawValue, forKey: .action)
        try container.encode(runMode, forKey: .runMode)
        if oncePerDay {
            try container.encode(true, forKey: .oncePerDay)
        }
        if finishesWhenEventEnds {
            try container.encode(true, forKey: .finishesWhenEventEnds)
        }
    }
}

extension TriggerEvent {
    /// The event read from its JSON object; whatever this version can't read is `.unsupported`.
    init(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue else {
            self = .unsupported(json)
            return
        }
        switch kind {
        case "schedule":
            guard let minute = json["minute"]?.intValue,
                  let days = json["weekdays"]?.arrayValue,
                  case let weekdays = days.compactMap(\.intValue), weekdays.count == days.count
            else {
                self = .unsupported(json)
                return
            }
            self = .schedule(TriggerSchedule(minuteOfDay: minute, weekdays: Set(weekdays)))
        case "login": self = .login
        case "appOpens": self = .appOpens
        case "screensWake": self = .screensWake
        case "screensSleep": self = .screensSleep
        case "condition":
            guard let conditionJSON = json["condition"],
                  let condition = TriggerCondition(json: conditionJSON),
                  let edge = json["edge"]?.stringValue.flatMap(TriggerEdge.init(rawValue:))
            else {
                self = .unsupported(json)
                return
            }
            self = .condition(condition, edge: edge)
        default:
            self = .unsupported(json)
        }
    }

    /// The JSON object it's saved as; an unsupported event as it was read.
    var json: JSONValue {
        switch self {
        case .schedule(let schedule):
            return .object([
                "kind": .string("schedule"),
                "minute": .integer(Int64(schedule.minuteOfDay)),
                "weekdays": .array(schedule.weekdays.sorted().map { .integer(Int64($0)) }),
            ])
        case .login: return .object(["kind": .string("login")])
        case .appOpens: return .object(["kind": .string("appOpens")])
        case .screensWake: return .object(["kind": .string("screensWake")])
        case .screensSleep: return .object(["kind": .string("screensSleep")])
        case .condition(let condition, let edge):
            return .object(["kind": .string("condition"), "condition": condition.json, "edge": .string(edge.rawValue)])
        case .unsupported(let raw):
            return raw
        }
    }
}

extension TriggerCondition {
    /// `nil` for a kind this version doesn't know or values it can't read. A display condition
    /// without a display is "any external display"; one with a display that can't be read is
    /// unreadable — never widened to any display.
    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue else { return nil }
        switch kind {
        case "display":
            if let displayJSON = json["display"] {
                guard let identity = DisplayIdentity(json: displayJSON) else { return nil }
                self = .display(.display(identity))
            } else {
                self = .display(.anyExternal)
            }
        case "displays":
            guard let list = json["displays"]?.arrayValue else { return nil }
            let identities = list.compactMap(DisplayIdentity.init(json:))
            guard identities.count == list.count else { return nil }
            self = .displays(DisplayArrangement(displays: identities))
        case "wifi":
            guard let name = json["name"]?.stringValue else { return nil }
            self = .wifi(WiFiNetworkName(stored: name))
        case "ethernet": self = .ethernet
        case "vpn": self = .vpn
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .display(.anyExternal):
            return .object(["kind": .string("display")])
        case .display(.display(let identity)):
            return .object(["kind": .string("display"), "display": identity.json])
        case .displays(let arrangement):
            return .object(["kind": .string("displays"), "displays": .array(arrangement.displays.map(\.json))])
        case .wifi(let name):
            return .object(["kind": .string("wifi"), "name": .string(name.name)])
        case .ethernet:
            return .object(["kind": .string("ethernet")])
        case .vpn:
            return .object(["kind": .string("vpn")])
        }
    }
}

extension DisplayIdentity {
    init?(json: JSONValue) {
        guard let vendor = json["vendor"]?.intValue.flatMap(UInt32.init(exactly:)),
              let model = json["model"]?.intValue.flatMap(UInt32.init(exactly:))
        else { return nil }
        let serial: UInt32?
        if let rawSerial = json["serial"], rawSerial != .null {
            guard let value = rawSerial.intValue.flatMap(UInt32.init(exactly:)) else { return nil }
            serial = value
        } else {
            serial = nil
        }
        let name = json["name"]?.stringValue ?? ""
        let isBuiltIn = json["builtIn"]?.boolValue ?? false
        self.init(stored: vendor, model: model, serial: serial, name: name, isBuiltIn: isBuiltIn)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "vendor": .integer(Int64(vendor)),
            "model": .integer(Int64(model)),
            "name": .string(name),
            "builtIn": .bool(isBuiltIn),
        ]
        if let serial {
            object["serial"] = .integer(Int64(serial))
        }
        return .object(object)
    }
}
