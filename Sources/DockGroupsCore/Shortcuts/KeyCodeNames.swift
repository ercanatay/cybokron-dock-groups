import Carbon.HIToolbox
import Foundation

/// The names of keys by virtual key code as a US (ANSI) keyboard prints them, and symbols for keys
/// that print nothing, as macOS writes them in menus. The app shows the current keyboard layout's
/// character where it can; these are the fallback, and what the core's texts use.
public enum KeyCodeNames {
    /// The name of the key with this virtual key code, e.g. "C", "3", "F5", "←", "Keypad 3".
    public static func name(forKeyCode keyCode: UInt16) -> String {
        let code = Int(keyCode)
        if let name = printed[code] { return name }
        if let symbol = symbols[code] { return symbol }
        if let key = keypad[code] {
            return Localization.format("core.shortcut.key.keypad", "Keypad %@", key)
        }
        if code == kVK_Space {
            return Localization.string("core.shortcut.key.space", "Space")
        }
        return Localization.format("core.shortcut.key.code", "Key %ld", code)
    }

    /// Letters, digits and punctuation of the US layout, and the keys ISO and JIS keyboards add.
    private static let printed: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
        kVK_ISO_Section: "§", kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_",
    ]

    /// Keys that print nothing, by their menu symbols.
    private static let symbols: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝",
    ]

    /// The keypad's keys, which `core.shortcut.key.keypad` names ("Keypad 3").
    private static let keypad: [Int: String] = [
        kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9",
        kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadMinus: "-",
        kVK_ANSI_KeypadEquals: "=", kVK_JIS_KeypadComma: ",",
    ]
}
