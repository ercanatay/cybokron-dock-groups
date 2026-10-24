import Carbon.HIToolbox
import Foundation

/// Modifier keys held with a key. Caps Lock, fn and the keypad flag never count: Carbon matches hot
/// keys by these four only.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Each modifier with the name it's saved with, in the order macOS writes them in menus.
    static let named: [(modifier: KeyModifiers, name: String, symbol: String, carbonBit: Int)] = [
        (.control, "control", "⌃", controlKey),
        (.option, "option", "⌥", optionKey),
        (.shift, "shift", "⇧", shiftKey),
        (.command, "command", "⌘", cmdKey),
    ]

    /// The modifiers of a set of the number shortcuts.
    public init(_ modifiers: ShortcutModifiers) {
        self.init(carbonBits: GroupHotKeys.carbonModifiers(for: modifiers))
    }

    /// The modifiers among Carbon's modifier bits; other bits (Caps Lock, the right-hand keys'
    /// flags…) are ignored.
    public init(carbonBits: UInt32) {
        var modifiers: KeyModifiers = []
        for entry in Self.named where carbonBits & UInt32(entry.carbonBit) != 0 {
            modifiers.insert(entry.modifier)
        }
        self = modifiers
    }

    /// The modifiers as Carbon's modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    public var carbonBits: UInt32 {
        Self.named.reduce(0) { bits, entry in contains(entry.modifier) ? bits | UInt32(entry.carbonBit) : bits }
    }

    /// The keys in the order macOS writes them in menus, e.g. "⌃⌥⇧".
    public var symbols: String {
        Self.named.filter { contains($0.modifier) }.map(\.symbol).joined()
    }

    /// How many of Control, Option and Command are held; Shift doesn't count (rule K1).
    public var commandLikeCount: Int {
        [KeyModifiers.control, .option, .command].filter(contains).count
    }
}

extension KeyModifiers: Codable {
    /// Saved as their names, in menu order: `["control", "option"]`. An unknown name makes the
    /// whole value unreadable, so a shortcut from another version is never read as something else.
    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var modifiers: KeyModifiers = []
        for name in names {
            guard let entry = Self.named.first(where: { $0.name == name }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown modifier “\(name)”"))
            }
            modifiers.insert(entry.modifier)
        }
        self = modifiers
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.named.filter { contains($0.modifier) }.map(\.name))
    }
}

/// A physical key (its virtual key code, whatever the keyboard layout) with exactly these
/// modifiers, as Carbon matches hot keys: ⌃⌥⇧3 isn't ⌃⌥3, and the keypad's 3 isn't the number
/// row's.
public struct KeyCombination: Hashable, Sendable {
    /// Virtual key codes go up to 127 (`kVK_UpArrow` is 126).
    public static let keyCodes: ClosedRange<UInt16> = 0...127

    public let keyCode: UInt16
    public let modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The combination as macOS writes it, e.g. "⌃⌥C", with the key's name on a US keyboard
    /// (`KeyCodeNames`). The app shows the current layout's character instead where it can.
    public var title: String {
        modifiers.symbols + KeyCodeNames.name(forKeyCode: keyCode)
    }
}

/// What pressing a group's own shortcut does.
public enum GroupShortcutAction: String, Codable, CaseIterable, Sendable {
    /// Shows the group's popup, or closes it when it's showing (as a number shortcut does).
    case showPopup
    /// Opens the group's items (Open All).
    case openAll
    /// Starts the group, or finishes it when it's the current group (`ShortcutTransition`).
    case startOrFinish

    /// How the group window names the choice.
    public var title: String {
        switch self {
        case .showPopup: Localization.string("core.shortcut.action.showPopup", "Show the Popup")
        case .openAll: Localization.string("core.shortcut.action.openAll", "Open All")
        case .startOrFinish: Localization.string("core.shortcut.action.startOrFinish", "Start (Finish when current)")
        }
    }
}

/// Why keys can't be a group's shortcut (spec §1.3). The static rules (K1–K3) never change, so a
/// shortcut breaking them can't exist at all (`GroupShortcut.init`) and is dropped when data is
/// read; the others (K4–K6) depend on the moment and turn a saved shortcut off
/// (`GroupShortcutStatus.off`).
public enum GroupShortcutRefusal: Hashable, Sendable {
    /// K1: fewer than two of Control, Option and Command, so it would take keys typing, editing
    /// and apps' menus need (⌘C, ⌥E, ⌃A…).
    case tooFewModifiers
    /// K2: a key that typing, navigating or macOS needs (Escape, Return, Tab, Space, Delete, fn…).
    case keyNotAllowed
    /// K3: one of macOS's own shortcuts (`ReservedShortcuts`).
    case reserved
    /// K4: a shortcut turned on in System Settings → Keyboard → Keyboard Shortcuts.
    case systemShortcut
    /// K5: the keys of the number shortcut with this digit, while those are on.
    case numberShortcut(digit: Int)
    /// K6: another group's shortcut.
    case takenByGroup(DockGroup.ID)

    /// Whether the refusal comes from a rule that never changes (K1–K3).
    public var isStatic: Bool {
        switch self {
        case .tooFewModifiers, .keyNotAllowed, .reserved: true
        case .systemShortcut, .numberShortcut, .takenByGroup: false
        }
    }

    /// Why the keys weren't taken, for the recorder. `keyTitle` is how the keys are shown;
    /// `otherGroupName` names the group that has them (`takenByGroup`).
    public func message(keyTitle: String, otherGroupName: String? = nil) -> String {
        switch self {
        case .tooFewModifiers:
            return Localization.string(
                "core.shortcut.refusal.tooFewModifiers",
                "Use at least two of Control (⌃), Option (⌥) and Command (⌘), so the shortcut doesn't take keys that apps and typing need."
            )
        case .keyNotAllowed:
            return Localization.string("core.shortcut.refusal.keyNotAllowed", "Escape, Return, Tab, Space and Delete can't be part of a group shortcut.")
        case .reserved:
            return Localization.format("core.shortcut.refusal.reserved", "macOS uses %@. Choose another shortcut.", keyTitle)
        case .systemShortcut:
            return Localization.format(
                "core.shortcut.refusal.system",
                "macOS uses %@ (System Settings → Keyboard → Keyboard Shortcuts). Choose another shortcut.",
                keyTitle
            )
        case .numberShortcut(let digit):
            return Localization.format(
                "core.shortcut.refusal.number",
                "%1$@ shows the popup of group number %2$ld in the list (Settings → Shortcuts & Siri). Choose another shortcut, or change the number shortcuts' keys.",
                keyTitle, digit
            )
        case .takenByGroup:
            guard let otherGroupName else {
                return Localization.format("core.shortcut.refusal.taken", "Another group already uses %@.", keyTitle)
            }
            return Localization.format("core.shortcut.refusal.takenByGroup", "“%1$@” already uses %2$@.", otherGroupName, keyTitle)
        }
    }
}

/// A group's own global keyboard shortcut: keys and what they do (spec G). Its keys always pass
/// the static rules K1–K3 — there's no way to make one that doesn't, from the recorder or from a
/// file — so a crafted `groups.json` or backup can't take ⌘C, ⌥E or ⌃⌘Q.
public struct GroupShortcut: Hashable, Sendable {
    public let keys: KeyCombination
    public var action: GroupShortcutAction

    /// `nil` when the keys break a static rule (`staticRefusal`).
    public init?(keys: KeyCombination, action: GroupShortcutAction = .showPopup) {
        guard Self.staticRefusal(for: keys) == nil else { return nil }
        self.keys = keys
        self.action = action
    }

    /// The static rule the keys break, in order K1, K2, K3; `nil` when they may be a group's
    /// shortcut as far as those rules go.
    public static func staticRefusal(for keys: KeyCombination) -> GroupShortcutRefusal? {
        if keys.modifiers.commandLikeCount < 2 { return .tooFewModifiers }
        if !allowedKeyCodes.contains(keys.keyCode) { return .keyNotAllowed }
        if ReservedShortcuts.builtIn.contains(keys) { return .reserved }
        return nil
    }

    /// Rule K2: letters, digits and punctuation, the keypad's digits and operators (not Enter),
    /// F1–F20, the arrows, Home, End, Page Up and Page Down. Not Escape, Return, Tab, Space,
    /// Delete, Forward Delete, Help, Caps Lock, fn, the modifiers, the volume keys or the JIS
    /// input-source keys.
    public static let allowedKeyCodes: Set<UInt16> = Set([
        // Letters.
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
        // The number row.
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9,
        // Punctuation, and the keys ISO and JIS keyboards add.
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Quote,
        kVK_ANSI_Semicolon, kVK_ANSI_Backslash, kVK_ANSI_Comma, kVK_ANSI_Slash, kVK_ANSI_Period,
        kVK_ANSI_Grave, kVK_ISO_Section, kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma,
        // The keypad.
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
        // Function keys.
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        // Navigation.
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ].map { UInt16($0) })
}

extension GroupShortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, action
    }

    /// The keys are required and must pass K1–K3, or the shortcut is unreadable (and the group,
    /// decoding it leniently, has none). An unknown or missing action reads as Show the Popup,
    /// the least a press can do.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(Int.self, forKey: .keyCode)
        guard let code = UInt16(exactly: keyCode), KeyCombination.keyCodes.contains(code) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container, debugDescription: "Key code \(keyCode) out of range")
        }
        let keys = KeyCombination(keyCode: code, modifiers: try container.decode(KeyModifiers.self, forKey: .modifiers))
        if let refusal = Self.staticRefusal(for: keys) {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container, debugDescription: "Keys refused: \(refusal)")
        }
        self.keys = keys
        action = container.decodeLeniently(GroupShortcutAction.self, forKey: .action) ?? .showPopup
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(keys.keyCode), forKey: .keyCode)
        try container.encode(keys.modifiers, forKey: .modifiers)
        try container.encode(action, forKey: .action)
    }
}

/// What a press of a group's Start shortcut (`GroupShortcutAction.startOrFinish`) does: Start,
/// or Finish when the group is current — unless it was started less than
/// `ContextSession.repeatInterval` ago, so a double press doesn't start and finish it at once.
public enum ShortcutTransition: Equatable, Sendable {
    case start, finish, nothing

    @MainActor
    public static func forGroup(_ id: DockGroup.ID, in session: ContextSession, at date: Date) -> ShortcutTransition {
        guard session.current == id else { return .start }
        return session.isRepeatedStart(of: id, at: date) ? .nothing : .finish
    }
}
