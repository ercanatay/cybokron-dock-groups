import AppKit

/// Modifier keys held together with a digit for the global group shortcuts.
public enum ShortcutModifiers: String, Codable, CaseIterable, Sendable {
    case controlOption
    case optionCommand
    case controlCommand
    case controlOptionCommand

    public var flags: NSEvent.ModifierFlags {
        switch self {
        case .controlOption: return [.control, .option]
        case .optionCommand: return [.option, .command]
        case .controlCommand: return [.control, .command]
        case .controlOptionCommand: return [.control, .option, .command]
        }
    }

    /// The keys in the order macOS writes them in menus, e.g. "⌃⌥".
    public var symbols: String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// Whether exactly these modifiers are held. Caps Lock, Fn and the keypad flag don't count.
    public func matches(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection([.control, .option, .shift, .command]) == flags
    }
}

/// The global group shortcuts: the modifiers plus 1…9 open the popups of the first nine groups,
/// in the order of the group list.
public enum GroupShortcuts {
    public static let digits = 1...9

    /// Digits of the number-row and keypad keys, by virtual key code. Key codes name physical keys,
    /// so the shortcuts stay on the same keys whatever the keyboard layout.
    static let digitsByKeyCode: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// The digit 1…9 on the key with this virtual key code, `nil` for any other key (including 0).
    public static func digit(forKeyCode keyCode: UInt16) -> Int? {
        digitsByKeyCode[keyCode]
    }

    /// The digit of a key press that is a group shortcut, or `nil` when the key isn't 1…9 or other
    /// modifiers than `modifiers` are held.
    public static func digit(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, modifiers: ShortcutModifiers) -> Int? {
        guard modifiers.matches(modifierFlags) else { return nil }
        return digit(forKeyCode: keyCode)
    }

    /// The group whose popup the digit opens: digit *n* is the *n*-th group.
    public static func group(forDigit digit: Int, in groups: [DockGroup]) -> DockGroup? {
        guard digits.contains(digit), digit <= groups.count else { return nil }
        return groups[digit - 1]
    }

    /// The digit of the group's shortcut; `nil` from the tenth group on.
    public static func digit(forGroup id: DockGroup.ID, in groups: [DockGroup]) -> Int? {
        guard let index = groups.firstIndex(where: { $0.id == id }), digits.contains(index + 1) else { return nil }
        return index + 1
    }

    /// The shortcut as macOS writes it, e.g. "⌃⌥3".
    public static func title(digit: Int, modifiers: ShortcutModifiers) -> String {
        "\(modifiers.symbols)\(digit)"
    }
}
