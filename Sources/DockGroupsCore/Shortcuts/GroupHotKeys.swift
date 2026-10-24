import Carbon.HIToolbox
import Foundation

/// One key of the global group shortcuts as a system-wide hot key: a number-row or keypad key of
/// 1…9, registered together with the chosen modifiers.
public struct GroupHotKey: Hashable, Sendable {
    /// The virtual key code (a physical key, whatever the keyboard layout).
    public let keyCode: UInt16
    public let digit: Int

    /// The id the hot key is registered with (`EventHotKeyID.id`): its key code, which tells the
    /// pressed key apart.
    public var id: UInt32 { UInt32(keyCode) }
}

/// The global group shortcuts as hot keys (Carbon's `RegisterEventHotKey`). Unlike watching key
/// presses with event monitors, hot keys need no Accessibility access, and they take the key
/// press: the app in front doesn't receive it.
public enum GroupHotKeys {
    /// The `EventHotKeyID.signature` of the number shortcuts' hot keys, "CDGr".
    public static let signature: OSType = "CDGr".utf8.reduce(0) { $0 << 8 | OSType($1) }
    /// The `EventHotKeyID.signature` of the groups' own shortcuts, "CDGs": registered and let go
    /// apart from the number shortcuts.
    public static let groupSignature: OSType = "CDGs".utf8.reduce(0) { $0 << 8 | OSType($1) }

    /// A hot key for every key `GroupShortcuts` reads as a digit — the number row and the keypad,
    /// 18 in all — in key code order.
    public static let all: [GroupHotKey] = GroupShortcuts.digitsByKeyCode
        .map { GroupHotKey(keyCode: $0.key, digit: $0.value) }
        .sorted { $0.keyCode < $1.keyCode }

    /// The modifiers as Carbon's modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    public static func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        let flags = modifiers.flags
        var bits: UInt32 = 0
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        return bits
    }

    /// The digit of the app's hot key with this signature and id; `nil` for any other hot key.
    public static func digit(signature: OSType, id: UInt32) -> Int? {
        guard signature == Self.signature, let keyCode = UInt16(exactly: id) else { return nil }
        return GroupShortcuts.digit(forKeyCode: keyCode)
    }
}

/// Registers system-wide hot keys. The app's implementation calls Carbon; tests use a fake.
@MainActor
public protocol HotKeyRegistering: AnyObject {
    /// Called with the signature and id of a registered hot key when it's pressed; returns whether
    /// the press was used.
    var onPress: ((_ signature: OSType, _ id: UInt32) -> Bool)? { get set }
    /// Registers a hot key for the key code with exactly these Carbon modifier bits: `noErr`, or
    /// the status it failed with (`eventHotKeyExistsErr` when the process has it already).
    func register(keyCode: UInt32, carbonModifiers: UInt32, signature: OSType, id: UInt32) -> OSStatus
    /// Unregisters the hot keys registered through it with this signature; the others stay.
    func unregisterAll(signature: OSType)
}

/// How the global shortcuts are noticed.
public enum GlobalShortcutMode: Equatable, Sendable {
    /// The shortcuts are off.
    case off
    /// As hot keys: in every app, without Accessibility access; the app in front doesn't receive
    /// the key press.
    case hotKeys
    /// A hot key couldn't be registered (the status it failed with), so the key presses are
    /// watched with event monitors instead: in other apps only with Accessibility access, and the
    /// app in front receives the key press too.
    case eventMonitors(OSStatus)
}

/// Registers the global shortcuts as hot keys and turns their presses into actions: the number
/// shortcuts (digits) and the groups' own shortcuts. It only decides; `system` registers. One
/// registrar owns `system.onPress` and both sets, so neither can take the other's handler or let go
/// of the other's hot keys: each set is registered and let go under its own signature.
///
/// The number shortcuts are registered first and stay all or none (I6): applying them lets the
/// group shortcuts go, registers the digits, then registers the group shortcuts again, so a group
/// shortcut can never hold a number key and make the digits fall back to event monitors. Each group
/// shortcut is registered on its own: when macOS refuses one, only that one is off — never an event
/// monitor, never a prompt for Accessibility access.
@MainActor
public final class GroupHotKeyRegistrar {
    /// Presses of the same group shortcut closer together than this count once (key repeat,
    /// bouncing keys).
    public static let repeatInterval: TimeInterval = 0.4

    /// How the number shortcuts are noticed since the last `apply`.
    public private(set) var mode: GlobalShortcutMode = .off
    /// Called with the digit 1…9 of a pressed number shortcut.
    public var onShortcut: ((Int) -> Void)?
    /// Called with the group and action of a pressed group shortcut.
    public var onGroupShortcut: ((DockGroup.ID, GroupShortcutAction) -> Void)?
    /// The status of every group shortcut of the last plan: the plan's, with `.unavailable` for
    /// those macOS refused and `.paused` for those let go while suspended.
    public private(set) var groupStatuses: [DockGroup.ID: GroupShortcutStatus] = [:]
    /// Whether the hot keys are let go for a recording (`suspend`).
    public private(set) var isSuspended = false

    private let system: HotKeyRegistering
    private let clock: () -> Date
    /// The number shortcuts' settings of the last `apply`; `nil` before the first.
    private var numberSettings: (enabled: Bool, modifiers: ShortcutModifiers)?
    private var groupPlan = GroupShortcutPlan.empty
    /// The group shortcuts registered now, by hot key id.
    private var registeredGroups: [UInt32: GroupShortcutPlan.Registration] = [:]
    /// When each group's shortcut was last pressed.
    private var lastPresses: [DockGroup.ID: Date] = [:]

    /// - Parameter clock: The time of a press, for `repeatInterval`.
    public init(system: HotKeyRegistering, clock: @escaping () -> Date = Date.init) {
        self.system = system
        self.clock = clock
        system.onPress = { [weak self] signature, id in
            self?.handlePress(signature: signature, id: id) ?? false
        }
    }

    /// Registers the number shortcuts' hot keys for these settings in place of the earlier ones (a
    /// process can't register the same keys twice). All or none: when one fails, those registered
    /// are unregistered again and the mode says to watch with event monitors. A half-registered set
    /// would make some digits take the key press and others not, and need Accessibility access all
    /// the same. The group shortcuts are registered again afterwards. While suspended, the
    /// settings are kept for `resume` and nothing is registered.
    @discardableResult
    public func apply(enabled: Bool, modifiers: ShortcutModifiers) -> GlobalShortcutMode {
        numberSettings = (enabled, modifiers)
        guard !isSuspended else { return mode }
        registerAll()
        return mode
    }

    /// Registers the group shortcuts of `plan` in place of the earlier ones, each on its own, and
    /// leaves the number shortcuts as they are. While suspended, the plan is kept for `resume`.
    public func applyGroupShortcuts(_ plan: GroupShortcutPlan) {
        groupPlan = plan
        let planned = Set(plan.statuses.keys)
        lastPresses = lastPresses.filter { planned.contains($0.key) }
        guard !isSuspended else {
            groupStatuses = pausedStatuses()
            return
        }
        registerGroupShortcuts()
    }

    /// Lets go of every hot key — number and group shortcuts — so a shortcut recorder receives the
    /// keys they'd take. Presses do nothing until `resume`.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        system.unregisterAll(signature: GroupHotKeys.groupSignature)
        system.unregisterAll(signature: GroupHotKeys.signature)
        registeredGroups = [:]
        groupStatuses = pausedStatuses()
    }

    /// Registers the hot keys again after `suspend`, with the latest settings and plan.
    @discardableResult
    public func resume() -> GlobalShortcutMode {
        guard isSuspended else { return mode }
        isSuspended = false
        registerAll()
        return mode
    }

    /// A hot key was pressed: calls `onShortcut` with its digit when it's one of the number
    /// shortcuts registered now, or `onGroupShortcut` when it's a group shortcut registered now
    /// (once per `repeatInterval`). Returns whether the press was used.
    @discardableResult
    public func handlePress(signature: OSType, id: UInt32) -> Bool {
        guard !isSuspended else { return false }
        if signature == GroupHotKeys.groupSignature {
            guard let registration = registeredGroups[id] else { return false }
            let now = clock()
            if let last = lastPresses[registration.groupID] {
                let elapsed = now.timeIntervalSince(last)
                if elapsed >= 0, elapsed < Self.repeatInterval { return true }
            }
            lastPresses[registration.groupID] = now
            onGroupShortcut?(registration.groupID, registration.shortcut.action)
            return true
        }
        guard mode == .hotKeys, let digit = GroupHotKeys.digit(signature: signature, id: id) else { return false }
        onShortcut?(digit)
        return true
    }

    // MARK: - Registering

    /// The number shortcuts (when they're on), then the group shortcuts.
    private func registerAll() {
        system.unregisterAll(signature: GroupHotKeys.groupSignature)
        registeredGroups = [:]
        registerNumbers()
        registerGroupShortcuts()
    }

    private func registerNumbers() {
        system.unregisterAll(signature: GroupHotKeys.signature)
        guard let settings = numberSettings, settings.enabled else {
            mode = .off
            return
        }
        let bits = GroupHotKeys.carbonModifiers(for: settings.modifiers)
        for hotKey in GroupHotKeys.all {
            let status = system.register(keyCode: UInt32(hotKey.keyCode), carbonModifiers: bits, signature: GroupHotKeys.signature, id: hotKey.id)
            guard status == OSStatus(noErr) else {
                system.unregisterAll(signature: GroupHotKeys.signature)
                mode = .eventMonitors(status)
                return
            }
        }
        mode = .hotKeys
    }

    private func registerGroupShortcuts() {
        system.unregisterAll(signature: GroupHotKeys.groupSignature)
        registeredGroups = [:]
        var statuses = groupPlan.statuses
        for registration in groupPlan.registrations {
            let keys = registration.shortcut.keys
            let status = system.register(
                keyCode: UInt32(keys.keyCode),
                carbonModifiers: keys.modifiers.carbonBits,
                signature: GroupHotKeys.groupSignature,
                id: registration.id
            )
            if status == OSStatus(noErr) {
                registeredGroups[registration.id] = registration
                statuses[registration.groupID] = .on
            } else {
                statuses[registration.groupID] = .unavailable(status)
            }
        }
        groupStatuses = statuses
    }

    /// The plan's statuses, with the shortcuts it registers paused.
    private func pausedStatuses() -> [DockGroup.ID: GroupShortcutStatus] {
        var statuses = groupPlan.statuses
        for registration in groupPlan.registrations {
            statuses[registration.groupID] = .paused
        }
        return statuses
    }
}
