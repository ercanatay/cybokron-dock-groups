import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: keys and modifiers")
struct KeyCombinationTests {
    private static let everyModifierSet: [KeyModifiers] = (0..<16).map { KeyModifiers(rawValue: UInt8($0)) }

    @Test func modifiersSpellAndMapAsMenusAndCarbonDo() {
        let all: KeyModifiers = [.command, .shift, .option, .control]
        #expect(all.symbols == "⌃⌥⇧⌘")
        #expect(KeyModifiers([.command, .option]).symbols == "⌥⌘")
        // ⌘ 1 << 8, ⇧ 1 << 9, ⌥ 1 << 11, ⌃ 1 << 12 (Events.h).
        #expect(KeyModifiers.command.carbonBits == 0x0100)
        #expect(KeyModifiers.shift.carbonBits == 0x0200)
        #expect(KeyModifiers.option.carbonBits == 0x0800)
        #expect(KeyModifiers.control.carbonBits == 0x1000)
        for modifiers in Self.everyModifierSet {
            #expect(KeyModifiers(carbonBits: modifiers.carbonBits) == modifiers)
        }
        // Caps Lock and the right-hand keys' bits don't count.
        #expect(KeyModifiers(carbonBits: UInt32(alphaLock | rightShiftKey | controlKey | cmdKey)) == [.control, .command])
    }

    @Test(arguments: ShortcutModifiers.allCases)
    func numberShortcutModifiersAreTheSameKeys(modifiers: ShortcutModifiers) {
        let keyModifiers = KeyModifiers(modifiers)
        #expect(keyModifiers.carbonBits == GroupHotKeys.carbonModifiers(for: modifiers))
        #expect(keyModifiers.symbols == modifiers.symbols)
        #expect(keyModifiers.commandLikeCount >= 2, "every number shortcut set would pass rule K1 too")
    }

    @Test func shiftDoesntCountTowardsTheModifiers() {
        #expect(KeyModifiers([.shift]).commandLikeCount == 0)
        #expect(KeyModifiers([.command, .shift]).commandLikeCount == 1)
        #expect(KeyModifiers([.control, .option, .shift]).commandLikeCount == 2)
        #expect(KeyModifiers([.control, .option, .command]).commandLikeCount == 3)
    }

    @Test func titlesNameTheKeysAsMenusDo() {
        #expect(combo(kVK_ANSI_C, [.control, .option]).title == "⌃⌥C")
        #expect(combo(kVK_F5, [.option, .command]).title == "⌥⌘F5")
        #expect(combo(kVK_LeftArrow, [.control, .option, .shift]).title == "⌃⌥⇧←")
        #expect(combo(kVK_ANSI_Keypad3, [.control, .option]).title == "⌃⌥Keypad 3")
        #expect(combo(kVK_Space, [.control, .command]).title == "⌃⌘Space")
        #expect(combo(kVK_Escape, [.option, .command]).title == "⌥⌘⎋")
        #expect(combo(kVK_ANSI_Grave, [.option, .command]).title == "⌥⌘`")
        #expect(combo(0x7F, [.control, .option]).title == "⌃⌥Key 127")
    }

    @Test func modifiersAreSavedByNameInMenuOrder() throws {
        let saved = try JSONEncoder().encode(KeyModifiers([.command, .control]))
        #expect(String(decoding: saved, as: UTF8.self) == #"["control","command"]"#)
        #expect(try JSONDecoder().decode(KeyModifiers.self, from: Data(#"["option","shift","option"]"#.utf8)) == [.option, .shift])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KeyModifiers.self, from: Data(#"["control","hyper"]"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KeyModifiers.self, from: Data(#""control""#.utf8)) }
    }
}

@Suite("Group shortcuts: the static rules (K1–K3)")
struct GroupShortcutStaticRuleTests {
    @Test func atLeastTwoOfControlOptionAndCommand() {
        for raw in 0..<16 {
            let modifiers = KeyModifiers(rawValue: UInt8(raw))
            let keys = combo(kVK_ANSI_K, modifiers)
            let refusal = GroupShortcut.staticRefusal(for: keys)
            if modifiers.commandLikeCount >= 2 {
                #expect(refusal == nil, "\(keys.title)")
                #expect(GroupShortcut(keys: keys) != nil)
            } else {
                #expect(refusal == .tooFewModifiers, "\(keys.title)")
                #expect(GroupShortcut(keys: keys) == nil, "no shortcut can have \(keys.title)")
            }
        }
    }

    /// Copy, paste, quit, screenshots, typed characters and Cocoa's text-editing keys.
    private static let everyday: [(Int, KeyModifiers)] = [
        (kVK_ANSI_C, .command), (kVK_ANSI_V, .command), (kVK_ANSI_Q, .command), (kVK_ANSI_W, .command),
        (kVK_ANSI_Z, [.command, .shift]), (kVK_ANSI_3, [.command, .shift]), (kVK_ANSI_E, .option),
        (kVK_ANSI_A, .control), (kVK_ANSI_K, [.control, .shift]), (kVK_ANSI_A, .shift), (kVK_ANSI_A, []),
        (kVK_F5, []), (kVK_UpArrow, .control),
    ]

    @Test(arguments: everyday)
    func everydayShortcutsAreNeverTaken(keyCode: Int, modifiers: KeyModifiers) {
        #expect(GroupShortcut.staticRefusal(for: combo(keyCode, modifiers)) == .tooFewModifiers)
        #expect(GroupShortcut(keys: combo(keyCode, modifiers), action: .startOrFinish) == nil)
    }

    @Test(arguments: [
        kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Space, kVK_Delete, kVK_ForwardDelete,
        kVK_Help, kVK_CapsLock, kVK_Function, kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
        kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl, kVK_VolumeUp, kVK_VolumeDown,
        kVK_Mute, kVK_JIS_Eisu, kVK_JIS_Kana, 0x6E, 0x7F,
    ])
    func keysTypingNavigationAndMacOSNeedAreRefused(keyCode: Int) {
        for modifiers in [KeyModifiers([.control, .option]), [.control, .option, .shift, .command]] {
            #expect(GroupShortcut.staticRefusal(for: combo(keyCode, modifiers)) == .keyNotAllowed)
        }
    }

    @Test func lettersDigitsPunctuationTheKeypadFunctionKeysAndNavigationAreAllowed() {
        // 26 letters, 10 digits, 11 punctuation keys and 4 ISO and JIS ones, 17 keypad keys, F1–F20,
        // 4 arrows, Home, End, Page Up, Page Down.
        #expect(GroupShortcut.allowedKeyCodes.count == 26 + 10 + 15 + 17 + 20 + 8)
        for keyCode in KeyCombination.keyCodes {
            let refusal = GroupShortcut.staticRefusal(for: KeyCombination(keyCode: keyCode, modifiers: [.control, .option]))
            #expect(refusal == (GroupShortcut.allowedKeyCodes.contains(keyCode) ? nil : .keyNotAllowed), "key \(keyCode)")
        }
        for keyCode in [kVK_ANSI_C, kVK_ANSI_0, kVK_ANSI_Slash, kVK_ISO_Section, kVK_ANSI_Keypad9, kVK_F20, kVK_PageDown] {
            #expect(GroupShortcut(keys: combo(keyCode, [.control, .option, .shift])) != nil)
        }
    }

    @Test func macOSsOwnShortcutsAreReserved() {
        #expect(ReservedShortcuts.builtIn.count == ReservedShortcuts.named.count, "each entry once")
        for entry in ReservedShortcuts.named {
            // Every entry passes K1 and K2, or it wouldn't need listing.
            #expect(entry.keys.modifiers.commandLikeCount >= 2, "\(entry.name)")
            #expect(GroupShortcut.allowedKeyCodes.contains(entry.keys.keyCode), "\(entry.name)")
            #expect(GroupShortcut.staticRefusal(for: entry.keys) == .reserved, "\(entry.name)")
            #expect(GroupShortcut(keys: entry.keys) == nil)
        }
        #expect(ReservedShortcuts.builtIn.contains(combo(kVK_ANSI_Q, [.control, .command])), "Lock Screen")
        #expect(ReservedShortcuts.builtIn.contains(combo(kVK_ANSI_D, [.option, .command])), "the Dock")
        #expect(ReservedShortcuts.builtIn.contains(combo(kVK_ANSI_3, [.control, .shift, .command])), "screenshot")
        // Only those exact modifiers.
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_ANSI_Q, [.control, .option])) == nil)
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_ANSI_D, [.option, .shift, .command])) == nil)
    }

    @Test func rulesApplyInOrder() {
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_Space, .command)) == .tooFewModifiers)
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_Space, [.control, .command])) == .keyNotAllowed, "the Character Viewer: K2 first")
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_Escape, [.option, .command])) == .keyNotAllowed, "Force Quit: K2 first")
        #expect(GroupShortcut.staticRefusal(for: combo(kVK_ANSI_Q, [.control, .command])) == .reserved)
    }
}

@Suite("Group shortcuts: saved with the group")
struct GroupShortcutCodingTests {
    private static let id = "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B"

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func group(withShortcut value: String) throws -> DockGroup {
        let json = #"{ "id": "\#(Self.id)", "name": "Coding", "emoji": "💻", "apps": [ { "bundleIdentifier": "com.apple.dt.Xcode", "name": "Xcode" } ], "shortcut": \#(value) }"#
        return try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
    }

    @Test func savedAsKeyCodeModifierNamesAndAction() throws {
        let saved = try object(makeShortcut(kVK_ANSI_C, [.option, .control], .startOrFinish))
        #expect(saved.count == 3)
        #expect(saved["keyCode"] as? Int == 8)
        #expect(saved["modifiers"] as? [String] == ["control", "option"])
        #expect(saved["action"] as? String == "startOrFinish")
        #expect(GroupShortcutAction.allCases.map(\.rawValue) == ["showPopup", "openAll", "startOrFinish"])
    }

    @Test func aGroupWritesItsShortcutOnlyWhenItHasOne() throws {
        #expect(try object(DockGroup(name: "Work"))["shortcut"] == nil)
        let group = DockGroup(name: "Work", shortcut: makeShortcut(kVK_ANSI_W, [.control, .option], .openAll))
        #expect(try object(group)["shortcut"] != nil)
        #expect(try JSONDecoder().decode(DockGroup.self, from: JSONEncoder().encode(group)) == group)
        #expect(DockGroup(name: "Work").shortcut == nil)
    }

    @Test func backupsCarryTheShortcut() throws {
        let group = DockGroup(name: "Work", shortcut: makeShortcut(kVK_F13, [.control, .command]))
        let backup = SettingsBackup(appVersion: "0.9.0", groups: [group], preferences: PopupPreferences())
        #expect(try SettingsBackup.decode(from: backup.encoded()).groups == [group])
    }

    /// A crafted or damaged shortcut is dropped: the group loads without one, everything else kept.
    @Test(arguments: [
        #"{ "keyCode": 8, "modifiers": ["command"], "action": "openAll" }"#,                  // ⌘C
        #"{ "keyCode": 9, "modifiers": ["command"] }"#,                                        // ⌘V
        #"{ "keyCode": 12, "modifiers": ["command"], "action": "startOrFinish" }"#,           // ⌘Q
        #"{ "keyCode": 8, "modifiers": ["command", "shift"] }"#,                               // ⌘⇧C
        #"{ "keyCode": 14, "modifiers": ["option"] }"#,                                        // ⌥E
        #"{ "keyCode": 0, "modifiers": ["control"] }"#,                                        // ⌃A
        #"{ "keyCode": 0, "modifiers": [] }"#,                                                 // A
        #"{ "keyCode": 12, "modifiers": ["control", "command"] }"#,                            // ⌃⌘Q, Lock Screen
        #"{ "keyCode": 49, "modifiers": ["control", "option"] }"#,                             // ⌃⌥Space
        #"{ "keyCode": 53, "modifiers": ["option", "command"] }"#,                             // ⌥⌘⎋, Force Quit
        #"{ "keyCode": 300, "modifiers": ["control", "option"] }"#,
        #"{ "keyCode": -1, "modifiers": ["control", "option"] }"#,
        #"{ "keyCode": "8", "modifiers": ["control", "option"] }"#,
        #"{ "keyCode": 8.5, "modifiers": ["control", "option"] }"#,
        #"{ "keyCode": 8, "modifiers": ["control", "hyper"] }"#,
        #"{ "keyCode": 8, "modifiers": "control option" }"#,
        #"{ "keyCode": 8 }"#,
        #"{ "modifiers": ["control", "option"] }"#,
        #"42"#, #""⌃⌥C""#, #"[]"#, #"null"#,
    ])
    func unreadableShortcutsAreDropped(value: String) throws {
        let group = try group(withShortcut: value)
        #expect(group.shortcut == nil)
        #expect(group.name == "Coding" && group.emoji == "💻" && group.apps.count == 1)
    }

    @Test func anUnknownOrMissingActionShowsThePopup() throws {
        let expected = makeShortcut(kVK_ANSI_C, [.control, .option])
        for action in [#""teleport""#, "7", "null"] {
            #expect(try group(withShortcut: #"{ "keyCode": 8, "modifiers": ["control", "option"], "action": \#(action) }"#).shortcut == expected)
        }
        #expect(try group(withShortcut: #"{ "keyCode": 8, "modifiers": ["option", "control"], "later": true }"#).shortcut == expected)
    }
}

@Suite("Group shortcuts: texts")
struct GroupShortcutTextTests {
    @Test func actionNames() {
        #expect(GroupShortcutAction.showPopup.title == "Show the Popup")
        #expect(GroupShortcutAction.openAll.title == "Open All")
        #expect(GroupShortcutAction.startOrFinish.title == "Start (Finish when current)")
    }

    @Test func refusals() {
        let title = "⌃⌥C"
        #expect(GroupShortcutRefusal.tooFewModifiers.message(keyTitle: title)
            == "Use at least two of Control (⌃), Option (⌥) and Command (⌘), so the shortcut doesn't take keys that apps and typing need.")
        #expect(GroupShortcutRefusal.keyNotAllowed.message(keyTitle: title) == "Escape, Return, Tab, Space and Delete can't be part of a group shortcut.")
        #expect(GroupShortcutRefusal.reserved.message(keyTitle: "⌃⌘Q") == "macOS uses ⌃⌘Q. Choose another shortcut.")
        #expect(GroupShortcutRefusal.systemShortcut.message(keyTitle: title)
            == "macOS uses ⌃⌥C (System Settings → Keyboard → Keyboard Shortcuts). Choose another shortcut.")
        #expect(GroupShortcutRefusal.numberShortcut(digit: 3).message(keyTitle: "⌃⌥3")
            == "⌃⌥3 shows the popup of group number 3 in the list (Settings → Shortcuts & Siri). Choose another shortcut, or change the number shortcuts' keys.")
        #expect(GroupShortcutRefusal.takenByGroup(UUID()).message(keyTitle: "⌃⌥D", otherGroupName: "Design") == "“Design” already uses ⌃⌥D.")
        #expect(GroupShortcutRefusal.takenByGroup(UUID()).message(keyTitle: "⌃⌥D") == "Another group already uses ⌃⌥D.")
        #expect([GroupShortcutRefusal.tooFewModifiers, .keyNotAllowed, .reserved].allSatisfy { $0.isStatic })
        #expect(![GroupShortcutRefusal.systemShortcut, .numberShortcut(digit: 1), .takenByGroup(UUID())].contains { $0.isStatic })
    }

    @Test func statuses() {
        let title = "⌃⌥C"
        #expect(GroupShortcutStatus.on.message(keyTitle: title)
            == "Works in every app while Cybokron Dock Groups is running. The app in front doesn't receive ⌃⌥C.")
        #expect(GroupShortcutStatus.paused.message(keyTitle: title) == "Paused while a shortcut is being recorded.")
        #expect(GroupShortcutStatus.limitReached.message(keyTitle: title) == "Off: at most 100 group shortcuts can be on at once.")
        #expect(GroupShortcutStatus.unavailable(OSStatus(eventHotKeyExistsErr)).message(keyTitle: title)
            == "Off: macOS didn't accept these keys (error -9878). Another app may have reserved them.")
        #expect(GroupShortcutStatus.off(.numberShortcut(digit: 3)).message(keyTitle: "⌃⌥3") == "Off: ⌃⌥3 is also a number shortcut, which comes first.")
        #expect(GroupShortcutStatus.off(.takenByGroup(UUID())).message(keyTitle: title, otherGroupName: "Design")
            == "Off: “Design”, earlier in the list, uses the same keys.")
        #expect(GroupShortcutStatus.off(.takenByGroup(UUID())).message(keyTitle: title) == "Off: a group earlier in the list uses the same keys.")
        #expect(GroupShortcutStatus.off(.systemShortcut).message(keyTitle: title) == "Off: macOS uses these keys (System Settings → Keyboard → Keyboard Shortcuts).")
        #expect(GroupShortcutStatus.on.isOn && !GroupShortcutStatus.paused.isOn)
    }
}
