import AppKit
import Carbon.HIToolbox

extension KeyModifiers {
    /// The modifiers of a key event; Caps Lock, fn, the keypad and help flags don't count.
    public init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

extension KeyCodeNames {
    /// Whether the key's character depends on the keyboard layout: letters and punctuation, which
    /// the app names with the current layout's character. Digits keep their digit (the number
    /// shortcuts are digits too) and keys that print nothing keep their symbols.
    public static func dependsOnLayout(_ keyCode: UInt16) -> Bool {
        layoutKeyCodes.contains(Int(keyCode))
    }

    private static let layoutKeyCodes: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Quote,
        kVK_ANSI_Semicolon, kVK_ANSI_Backslash, kVK_ANSI_Comma, kVK_ANSI_Slash, kVK_ANSI_Period,
        kVK_ANSI_Grave, kVK_ISO_Section, kVK_JIS_Yen, kVK_JIS_Underscore,
    ]
}

/// What a key press means to the shortcut recorder (spec §1.2).
public enum ShortcutRecorderInput: Equatable, Sendable {
    /// Escape: recording ends, the shortcut stays as it was.
    case cancel
    /// Delete or Forward Delete without Control, Option or Command: the shortcut is removed.
    case clear
    /// Any other key: these keys, to check against the rules (`GroupShortcutPlanner.refusal`).
    case keys(KeyCombination)

    public static func interpret(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> ShortcutRecorderInput {
        let modifiers = KeyModifiers(eventFlags: modifierFlags)
        let code = Int(keyCode)
        if code == kVK_Escape { return .cancel }
        if code == kVK_Delete || code == kVK_ForwardDelete, modifiers.commandLikeCount == 0 { return .clear }
        return .keys(KeyCombination(keyCode: keyCode, modifiers: modifiers))
    }
}

/// macOS's own keyboard shortcuts as Carbon's `CopySymbolicHotKeys` lists them — the ones in System
/// Settings → Keyboard → Keyboard Shortcuts — for rule K4. The app reads the list; this decides what
/// it means. Checked on macOS 27 (`docs/design/shortcut-spike.md`): the modifiers are Carbon's
/// modifier bits (`cmdKey` 0x100 …), with the fn bit (`kEventKeyModifierFnMask`, 0x20000) on
/// function keys and arrows, which hot keys match without; key codes above 127 are keys of the
/// keyboard's top row that group shortcuts can't use.
public enum SystemShortcutList {
    /// One entry of the list.
    public struct Entry: Equatable, Sendable {
        public let keyCode: Int
        public let carbonModifiers: Int
        public let isEnabled: Bool

        public init(keyCode: Int, carbonModifiers: Int, isEnabled: Bool) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
            self.isEnabled = isEnabled
        }
    }

    /// The key combinations of the turned-on entries.
    public static func combinations(from entries: [Entry]) -> Set<KeyCombination> {
        Set(entries.compactMap { entry -> KeyCombination? in
            guard entry.isEnabled,
                  let keyCode = UInt16(exactly: entry.keyCode), KeyCombination.keyCodes.contains(keyCode),
                  let bits = UInt32(exactly: entry.carbonModifiers)
            else { return nil }
            return KeyCombination(keyCode: keyCode, modifiers: KeyModifiers(carbonBits: bits))
        })
    }
}
