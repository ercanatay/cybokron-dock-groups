import Foundation

/// The number shortcuts (I6) as the group shortcuts see them: the 18 keys they take while they're
/// on, which no group shortcut may take (rule K5).
public struct NumberShortcutSettings: Hashable, Sendable {
    public static let off = NumberShortcutSettings(enabled: false, modifiers: PopupPreferences().shortcutModifiers)

    public let enabled: Bool
    public let modifiers: ShortcutModifiers

    public init(enabled: Bool, modifiers: ShortcutModifiers) {
        self.enabled = enabled
        self.modifiers = modifiers
    }

    /// The number shortcuts these preferences turn on.
    public init(_ preferences: PopupPreferences) {
        self.init(enabled: preferences.shortcutsEnabled, modifiers: preferences.shortcutModifiers)
    }

    /// Each key combination of `GroupHotKeys.all` with these modifiers, and its digit; empty while
    /// the number shortcuts are off.
    public var combinations: [KeyCombination: Int] {
        guard enabled else { return [:] }
        let keyModifiers = KeyModifiers(modifiers)
        return Dictionary(uniqueKeysWithValues: GroupHotKeys.all.map { (KeyCombination(keyCode: $0.keyCode, modifiers: keyModifiers), $0.digit) })
    }

    /// The digit of the number shortcut with exactly these keys; `nil` when there's none (or
    /// they're off).
    public func digit(for keys: KeyCombination) -> Int? {
        guard enabled, keys.modifiers == KeyModifiers(modifiers) else { return nil }
        return GroupShortcuts.digit(forKeyCode: keys.keyCode)
    }
}

/// Whether a group's shortcut works now, and if not, why (spec §1.5).
public enum GroupShortcutStatus: Hashable, Sendable {
    /// Registered: pressing it works in every app.
    case on
    /// Not registered while a shortcut is being recorded (`GroupHotKeyRegistrar.suspend`).
    case paused
    /// More group shortcuts than `GroupShortcutPlanner.maximumRegistrations` come before it.
    case limitReached
    /// macOS refused to register it, with this status (`RegisterEventHotKey`).
    case unavailable(OSStatus)
    /// A rule turns it off: the number shortcuts, a macOS shortcut or another group has the keys.
    case off(GroupShortcutRefusal)

    public var isOn: Bool { self == .on }

    /// The status line under the group's shortcut. `keyTitle` is how the keys are shown;
    /// `otherGroupName` names the group that has them first (`.off(.takenByGroup)`).
    public func message(keyTitle: String, otherGroupName: String? = nil) -> String {
        switch self {
        case .on:
            return Localization.format(
                "core.shortcut.status.on",
                "Works in every app while Cybokron Dock Groups is running. The app in front doesn't receive %@.",
                keyTitle
            )
        case .paused:
            return Localization.string("core.shortcut.status.paused", "Paused while a shortcut is being recorded.")
        case .limitReached:
            let limit = GroupShortcutPlanner.maximumRegistrations
            return Localization.format("core.shortcut.status.limit", "Off: at most %ld group shortcuts can be on at once.", limit)
        case .unavailable(let status):
            // An error code, not a count: never grouped as numbers are ("-9878", not "-9.878").
            let code = String(status)
            return Localization.format(
                "core.shortcut.status.unavailable",
                "Off: macOS didn't accept these keys (error %@). Another app may have reserved them.",
                code
            )
        case .off(.numberShortcut):
            return Localization.format("core.shortcut.status.number", "Off: %@ is also a number shortcut, which comes first.", keyTitle)
        case .off(.takenByGroup):
            guard let otherGroupName else {
                return Localization.string("core.shortcut.status.taken", "Off: a group earlier in the list uses the same keys.")
            }
            return Localization.format("core.shortcut.status.takenByGroup", "Off: “%@”, earlier in the list, uses the same keys.", otherGroupName)
        case .off(.systemShortcut):
            return Localization.string("core.shortcut.status.system", "Off: macOS uses these keys (System Settings → Keyboard → Keyboard Shortcuts).")
        case .off(let refusal):
            return refusal.message(keyTitle: keyTitle, otherGroupName: otherGroupName)
        }
    }
}

/// Which group shortcuts to register, under which hot key ids, and the status of every group that
/// has one. Made by `GroupShortcutPlanner`, carried out by `GroupHotKeyRegistrar`.
public struct GroupShortcutPlan: Hashable, Sendable {
    public struct Registration: Hashable, Sendable {
        /// The hot key id (`EventHotKeyID.id`) it's registered with: 1…n in plan order.
        public let id: UInt32
        public let groupID: DockGroup.ID
        public let shortcut: GroupShortcut

        public init(id: UInt32, groupID: DockGroup.ID, shortcut: GroupShortcut) {
            self.id = id
            self.groupID = groupID
            self.shortcut = shortcut
        }
    }

    public static let empty = GroupShortcutPlan(registrations: [], statuses: [:])

    /// In the groups' order.
    public let registrations: [Registration]
    /// Every group with a shortcut: `.on` for those to register (the registrar replaces it with
    /// `.unavailable` when macOS refuses one), the reason for the others.
    public let statuses: [DockGroup.ID: GroupShortcutStatus]

    public init(registrations: [Registration], statuses: [DockGroup.ID: GroupShortcutStatus]) {
        self.registrations = registrations
        self.statuses = statuses
    }
}

/// Decides which group shortcuts can be on, from the groups, the number shortcuts and macOS's own
/// shortcuts (spec §2.4). Pure: it reads nothing and registers nothing, so every conflict rule is
/// tested here, and the recorder's refusal and the status after saving can't disagree (they use
/// the same rules).
///
/// The static rules (K1–K3) hold for every `GroupShortcut` by construction. The others, in order:
/// K4 a macOS shortcut turned on in System Settings, K5 a number shortcut while those are on
/// (they're registered first and stay all or none), K6 another group's shortcut — the group
/// earlier in the list keeps it.
public enum GroupShortcutPlanner {
    /// The most group shortcuts registered at once: a groups file with thousands of them (crafted
    /// or not) can't make registering costly.
    public static let maximumRegistrations = 100

    /// Why `keys` can't be `group`'s shortcut now; `nil` when they can. For the recorder: another
    /// group with the keys refuses them wherever it is in the list.
    /// - Parameters:
    ///   - groups: The active groups.
    ///   - system: macOS's shortcuts turned on in System Settings.
    public static func refusal(
        for keys: KeyCombination,
        group: DockGroup.ID,
        groups: [DockGroup],
        numbers: NumberShortcutSettings,
        system: Set<KeyCombination>
    ) -> GroupShortcutRefusal? {
        if let refusal = GroupShortcut.staticRefusal(for: keys) { return refusal }
        if system.contains(keys) { return .systemShortcut }
        if let digit = numbers.digit(for: keys) { return .numberShortcut(digit: digit) }
        if let other = groups.first(where: { $0.id != group && $0.shortcut?.keys == keys }) {
            return .takenByGroup(other.id)
        }
        return nil
    }

    /// The shortcuts of `groups` (the active groups, in list order) to register, and every
    /// shortcut's status.
    public static func plan(groups: [DockGroup], numbers: NumberShortcutSettings, system: Set<KeyCombination>) -> GroupShortcutPlan {
        var registrations: [GroupShortcutPlan.Registration] = []
        var statuses: [DockGroup.ID: GroupShortcutStatus] = [:]
        var owners: [KeyCombination: DockGroup.ID] = [:]
        for group in groups {
            // A repeated identifier (a damaged file) is planned once, as its first group.
            guard let shortcut = group.shortcut, statuses[group.id] == nil else { continue }
            let keys = shortcut.keys
            if system.contains(keys) {
                statuses[group.id] = .off(.systemShortcut)
            } else if let digit = numbers.digit(for: keys) {
                statuses[group.id] = .off(.numberShortcut(digit: digit))
            } else if let owner = owners[keys] {
                statuses[group.id] = .off(.takenByGroup(owner))
            } else {
                owners[keys] = group.id
                if registrations.count < maximumRegistrations {
                    registrations.append(.init(id: UInt32(registrations.count + 1), groupID: group.id, shortcut: shortcut))
                    statuses[group.id] = .on
                } else {
                    statuses[group.id] = .limitReached
                }
            }
        }
        return GroupShortcutPlan(registrations: registrations, statuses: statuses)
    }
}
