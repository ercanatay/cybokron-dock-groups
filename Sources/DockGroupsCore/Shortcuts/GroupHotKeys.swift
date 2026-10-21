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
    /// The `EventHotKeyID.signature` of the app's hot keys, "CDGr".
    public static let signature: OSType = "CDGr".utf8.reduce(0) { $0 << 8 | OSType($1) }

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
    /// Unregisters every hot key registered through it.
    func unregisterAll()
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

/// Registers the global shortcuts as hot keys and turns their presses into digits. It only
/// decides; `system` registers.
@MainActor
public final class GroupHotKeyRegistrar {
    /// How the shortcuts are noticed since the last `apply`.
    public private(set) var mode: GlobalShortcutMode = .off
    /// Called with the digit 1…9 of a pressed shortcut.
    public var onShortcut: ((Int) -> Void)?

    private let system: HotKeyRegistering

    public init(system: HotKeyRegistering) {
        self.system = system
        system.onPress = { [weak self] signature, id in
            self?.handlePress(signature: signature, id: id) ?? false
        }
    }

    /// Registers the hot keys for these settings in place of the earlier ones (a process can't
    /// register the same keys twice). All or none: when one fails, those registered are
    /// unregistered again and the mode says to watch with event monitors. A half-registered set
    /// would make some digits take the key press and others not, and need Accessibility access
    /// all the same.
    @discardableResult
    public func apply(enabled: Bool, modifiers: ShortcutModifiers) -> GlobalShortcutMode {
        system.unregisterAll()
        guard enabled else {
            mode = .off
            return mode
        }
        let bits = GroupHotKeys.carbonModifiers(for: modifiers)
        for hotKey in GroupHotKeys.all {
            let status = system.register(keyCode: UInt32(hotKey.keyCode), carbonModifiers: bits, signature: GroupHotKeys.signature, id: hotKey.id)
            guard status == OSStatus(noErr) else {
                system.unregisterAll()
                mode = .eventMonitors(status)
                return mode
            }
        }
        mode = .hotKeys
        return mode
    }

    /// A hot key was pressed: calls `onShortcut` with its digit when it's one of the shortcuts
    /// registered now. Returns whether the press was used.
    @discardableResult
    public func handlePress(signature: OSType, id: UInt32) -> Bool {
        guard mode == .hotKeys, let digit = GroupHotKeys.digit(signature: signature, id: id) else { return false }
        onShortcut?(digit)
        return true
    }
}
