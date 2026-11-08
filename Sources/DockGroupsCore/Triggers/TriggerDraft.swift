import Foundation

/// What the trigger editor shows and changes (triggers spec §3.2): when — a moment (a time, login,
/// the app opening, the screens waking or sleeping, the screen locking or unlocking) or a change (a display connecting or
/// disconnecting, a set of displays being connected or no longer, the Mac joining or leaving a
/// Wi-Fi network, Ethernet connecting or disconnecting) —, the action that event allows (§1.6),
/// how it runs, At most once a day, how long it waits before its action (0 to 3600 seconds) and,
/// for a Start on a change's start, Finish when it ends. Show the Popup runs without a notice.
///
/// VPNs aren't offered: macOS doesn't say reliably when one connects (TS-8).
public struct TriggerDraft: Equatable, Sendable {
    /// Events that happen at a moment.
    public enum Kind: String, CaseIterable, Sendable {
        case time
        case login
        case appOpens
        case screensWake
        case screensSleep
        /// Best effort: macOS doesn't document its lock signal (TS-11).
        case screenLocks
        case screenUnlocks
    }

    /// Events that are the start or the end of a condition.
    public enum Change: String, CaseIterable, Sendable {
        /// A display (any external one, or a chosen one) connects; its end is `displayDisconnects`.
        case displayConnects
        case displayDisconnects
        /// The connected displays become exactly the chosen ones; its end is `displaysDisconnected`.
        case displaysConnected
        case displaysDisconnected
        /// The Mac joins the named Wi-Fi network; its end is `wifiLeaves`.
        case wifiJoins
        case wifiLeaves
        /// A wired connection gets a network; its end is `ethernetDisconnects`.
        case ethernetConnects
        case ethernetDisconnects

        /// The condition it starts or ends.
        public var edge: TriggerEdge {
            switch self {
            case .displayConnects, .displaysConnected, .wifiJoins, .ethernetConnects: return .starts
            case .displayDisconnects, .displaysDisconnected, .wifiLeaves, .ethernetDisconnects: return .ends
            }
        }

        /// Whether it's about the displays (otherwise the network).
        public var isAboutDisplays: Bool {
            switch self {
            case .displayConnects, .displayDisconnects, .displaysConnected, .displaysDisconnected: return true
            case .wifiJoins, .wifiLeaves, .ethernetConnects, .ethernetDisconnects: return false
            }
        }

        /// Whether it waits for a Wi-Fi network's name (Location access, spec §1.5).
        public var needsLocation: Bool { self == .wifiJoins || self == .wifiLeaves }
    }

    /// The editor's When pop-up: a moment or a change.
    public enum When: Hashable, Sendable {
        case moment(Kind)
        case change(Change)
        case application(TriggerEdge)

        /// Every event the editor offers, in the pop-up's order: the moments, the application's
        /// starts/ends, the displays' changes, the network's changes.
        public static var offered: [When] {
            Kind.allCases.map(When.moment) + [.application(.starts), .application(.ends)] + Change.allCases.map(When.change)
        }

        /// The change, when it's one.
        public var change: Change? {
            if case .change(let change) = self { return change }
            return nil
        }
    }

    public private(set) var when: When
    /// Minutes since midnight, for a time.
    public var minuteOfDay: Int
    /// Gregorian weekday numbers, for a time.
    public var weekdays: Set<Int>
    /// The display a display trigger waits for.
    public var display: DisplayMatch
    /// The displays a These Displays trigger waits for (Use Current Displays fills them in).
    public var displays: [DisplayIdentity]
    /// The Wi-Fi network a Wi-Fi trigger waits for, as typed or as Use Current Network filled it
    /// in: matched exactly, so it's kept as it is (`isWiFiNameValid`).
    public var wifiName: String
    public var applicationBundleIdentifier: String = ""
    public private(set) var action: TriggerAction
    public private(set) var runMode: TriggerRunMode
    public var oncePerDay: Bool
    /// Finish when it ends: only for a Start on a change's start (`canFinishWhenEventEnds`).
    public var finishesWhenEventEnds: Bool
    /// The delay as typed, in seconds (`delaySeconds` reads it).
    public var delayText: String
    /// "Run what was missed" (`GroupTrigger.catchUp`, the editor's Run It After the Mac Wakes):
    /// application triggers only; any other event turns it off (`normalize`).
    public var catchUp = false

    /// A new trigger: at 9:00 on the calendar's working days, Start, with a notice.
    public init(calendar: Calendar) {
        when = .moment(.time)
        minuteOfDay = 9 * 60
        weekdays = TriggerSchedule.workingDays(in: calendar)
        display = .anyExternal
        displays = []
        wifiName = ""
        action = .start
        runMode = .notice
        oncePerDay = false
        finishesWhenEventEnds = false
        delayText = "0"
    }

    /// The draft of `trigger`; `nil` for an event this editor doesn't offer (a VPN, or one it
    /// can't read) and for an action a newer version wrote.
    public init?(editing trigger: GroupTrigger, calendar: Calendar) {
        // An action a newer version wrote: editing would replace it.
        guard trigger.unrecognizedAction == nil else { return nil }
        self.init(calendar: calendar)
        switch trigger.event {
        case .schedule(let schedule):
            when = .moment(.time)
            minuteOfDay = schedule.minuteOfDay
            weekdays = schedule.weekdays
        case .login: when = .moment(.login)
        case .appOpens: when = .moment(.appOpens)
        case .screensWake: when = .moment(.screensWake)
        case .screensSleep: when = .moment(.screensSleep)
        case .screenLocks: when = .moment(.screenLocks)
        case .screenUnlocks: when = .moment(.screenUnlocks)
        case .condition(.display(let match), let edge):
            when = .change(edge == .starts ? .displayConnects : .displayDisconnects)
            display = match
        case .condition(.displays(let arrangement), let edge):
            when = .change(edge == .starts ? .displaysConnected : .displaysDisconnected)
            displays = arrangement.displays
        case .condition(.wifi(let network), let edge):
            when = .change(edge == .starts ? .wifiJoins : .wifiLeaves)
            wifiName = network.name
        case .condition(.ethernet, let edge):
            when = .change(edge == .starts ? .ethernetConnects : .ethernetDisconnects)
        // VPN and unsupported events are not offered by this editor.
        case .condition(.vpn, _), .unsupported:
            return nil
        case .applicationPresence(let bundleIdentifier, let edge):
            when = .application(edge)
            applicationBundleIdentifier = bundleIdentifier
        }
        action = trigger.action
        runMode = trigger.runMode
        oncePerDay = trigger.oncePerDay
        finishesWhenEventEnds = trigger.finishesWhenEventEnds
        // A delay this version can't read shows empty: it must be typed again before saving.
        delayText = trigger.unreadableDelay == nil ? String(trigger.delaySeconds) : ""
        catchUp = trigger.catchUp
        normalize()
    }

    /// The moment, when the event is one.
    public var kind: Kind? {
        if case .moment(let kind) = when { return kind }
        return nil
    }

    /// The change, when the event is one.
    public var change: Change? {
        if case .change(let change) = when { return change }
        return nil
    }

    /// The event the draft describes.
    public var event: TriggerEvent {
        switch when {
        case .moment(.time): return .schedule(TriggerSchedule(minuteOfDay: minuteOfDay, weekdays: weekdays))
        case .moment(.login): return .login
        case .moment(.appOpens): return .appOpens
        case .moment(.screensWake): return .screensWake
        case .moment(.screensSleep): return .screensSleep
        case .moment(.screenLocks): return .screenLocks
        case .moment(.screenUnlocks): return .screenUnlocks
        case .change(let change): return .condition(condition(of: change), edge: change.edge)
        case .application(let edge): return .applicationPresence(bundleIdentifier: applicationBundleIdentifier, edge: edge)
        }
    }

    private func condition(of change: Change) -> TriggerCondition {
        switch change {
        case .displayConnects, .displayDisconnects: return .display(display)
        case .displaysConnected, .displaysDisconnected: return .displays(DisplayArrangement(displays: displays))
        case .wifiJoins, .wifiLeaves: return .wifi(WiFiNetworkName(stored: wifiName))
        case .ethernetConnects, .ethernetDisconnects: return .ethernet
        }
    }

    /// Whether the Wi-Fi network's name can be one: 1 to 32 bytes in UTF-8, no control characters.
    public var isWiFiNameValid: Bool { WiFiNetworkName.isValid(wifiName) }

    public var allowedActions: [TriggerAction] { event.allowedActions }

    /// Show the Popup runs right away only (its popup is its own notice).
    public var allowedRunModes: [TriggerRunMode] {
        action == .showPopup ? [.immediately] : TriggerRunMode.allCases
    }

    /// Whether "run what was missed" applies: an application trigger.
    public var canCatchUp: Bool {
        if case .application = when { return true }
        return false
    }

    /// Whether Finish when it ends applies: a Start on a change's start.
    public var canFinishWhenEventEnds: Bool {
        action == .start && change?.edge == .starts
    }

    /// The delay typed: a whole number of seconds in `GroupTrigger.delayRange` (spaces around it
    /// allowed); `nil` for anything else, which can't be saved.
    public var delaySeconds: Int? {
        let text = delayText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), text.count <= 4, let seconds = Int(text),
              GroupTrigger.delayRange.contains(seconds)
        else { return nil }
        return seconds
    }

    /// Whether it can be saved: a time needs at least one day, These Displays one to eight
    /// displays, a chosen display can't be the built-in one, a Wi-Fi network a valid name, the
    /// delay 0 to 3600 seconds.
    public var isValid: Bool {
        guard let delaySeconds else { return false }
        return GroupTrigger(groupID: UUID(), event: event, action: action, runMode: runMode, delaySeconds: delaySeconds).isRunnable
    }

    public mutating func setWhen(_ when: When) {
        let previous = action
        self.when = when
        normalize()
        if previous == .showPopup, action != .showPopup {
            runMode = .notice
        }
    }

    public mutating func setKind(_ kind: Kind) {
        setWhen(.moment(kind))
    }

    public mutating func setChange(_ change: Change) {
        setWhen(.change(change))
    }

    public mutating func setAction(_ action: TriggerAction) {
        let wasPopup = self.action == .showPopup
        self.action = action
        if wasPopup, action != .showPopup {
            runMode = .notice
        }
        normalize()
    }

    public mutating func setRunMode(_ runMode: TriggerRunMode) {
        guard allowedRunModes.contains(runMode) else { return }
        self.runMode = runMode
    }

    /// Select an application for the application-presence event. Only `.application` kinds,
    /// with non-path bundle identifiers accepted by `TriggerApplicationIdentifier`, are taken;
    /// the exact original identifier is kept.
    public mutating func selectApplication(_ app: AppReference) -> Bool {
        guard app.kind == .application, !app.isIdentifiedByPath, TriggerApplicationIdentifier(app.bundleIdentifier) != nil else {
            return false
        }
        applicationBundleIdentifier = app.bundleIdentifier
        return true
    }

    /// Use Current Displays: the displays connected now, at most `DisplayArrangement.maximumCount`.
    public mutating func useDisplays(_ connected: [DisplayIdentity]) {
        displays = Array(connected.prefix(DisplayArrangement.maximumCount))
    }

    /// The trigger: a new one, or `existing` changed (its identifier and switch kept). An application
    /// trigger keeps `existing`'s authorization only for the same application; a new one, or one
    /// whose application changed, matches by bundle identifier only (unverified) and starts turned
    /// off: that weak mode is never on by default.
    public func trigger(groupID: DockGroup.ID, replacing existing: GroupTrigger? = nil) -> GroupTrigger {
        var isEnabled = existing?.isEnabled ?? true
        var identity: ApplicationIdentityAuthorization?
        if case .applicationPresence(let bundleIdentifier, _) = event {
            if let existing, case .applicationPresence(let existingIdentifier, _) = existing.event, existingIdentifier == bundleIdentifier {
                identity = existing.applicationIdentity
            } else {
                identity = .unverified
                isEnabled = false
            }
        }
        var trigger = GroupTrigger(
            id: existing?.id ?? UUID(),
            groupID: existing?.groupID ?? groupID,
            event: event,
            action: action,
            runMode: runMode,
            isEnabled: isEnabled,
            oncePerDay: oncePerDay,
            finishesWhenEventEnds: finishesWhenEventEnds && canFinishWhenEventEnds,
            // A delay that can't be read makes an unrunnable trigger (the editor doesn't save it).
            delaySeconds: delaySeconds ?? -1,
            catchUp: catchUp && canCatchUp
        )
        if let identity {
            trigger.applicationIdentity = identity
        }
        return trigger
    }

    private mutating func normalize() {
        if !allowedActions.contains(action) {
            action = allowedActions.contains(.start) ? .start : (allowedActions.first ?? .start)
        }
        if !allowedRunModes.contains(runMode) {
            runMode = allowedRunModes.first ?? .notice
        }
        if !canFinishWhenEventEnds {
            finishesWhenEventEnds = false
        }
        if !canCatchUp {
            catchUp = false
        }
    }
}

/// The displays a display trigger's chooser offers (triggers spec §1.4, §3.2): any external
/// display, each external display connected now — two identical ones without serial numbers are
/// one choice, since they can't be told apart — and the saved display when it isn't connected.
public enum DisplayChoices {
    public struct Option: Hashable, Sendable {
        public let match: DisplayMatch
        /// Whether a display it matches is connected now (always true for any external display).
        public let isConnected: Bool
    }

    public static func options(connected: [DisplayIdentity], saved: DisplayMatch) -> [Option] {
        var options = [Option(match: .anyExternal, isConnected: true)]
        var seen: [DisplayIdentity] = []
        for display in connected where !display.isBuiltIn && !seen.contains(where: display.matches) {
            seen.append(display)
            options.append(Option(match: .display(display), isConnected: true))
        }
        if case .display(let identity) = saved, !seen.contains(where: identity.matches) {
            options.append(Option(match: saved, isConnected: false))
        }
        return options
    }

    /// The choice `saved` is among `options`: the connected display it matches, so the pop-up shows
    /// it chosen even when its name changed.
    public static func selection(for saved: DisplayMatch, in options: [Option]) -> DisplayMatch {
        guard case .display(let identity) = saved else { return saved }
        for option in options {
            if case .display(let candidate) = option.match, candidate.matches(identity) {
                return option.match
            }
        }
        return saved
    }

    /// Whether `display` of a These Displays trigger is connected now.
    public static func isConnected(_ display: DisplayIdentity, in connected: [DisplayIdentity]) -> Bool {
        connected.contains(where: display.matches)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
