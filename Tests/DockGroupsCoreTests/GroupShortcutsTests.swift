import AppKit
import Testing
@testable import DockGroupsCore

@Suite("Global group shortcuts")
struct GroupShortcutsTests {
    private static let groups = (1...11).map { DockGroup(name: "Group \($0)") }

    @Test(arguments: [
        (UInt16(18), 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9),
        (83, 1), (84, 2), (85, 3), (86, 4), (87, 5), (88, 6), (89, 7), (91, 8), (92, 9),
    ])
    func numberRowAndKeypadKeysMapToDigits(keyCode: UInt16, digit: Int) {
        #expect(GroupShortcuts.digit(forKeyCode: keyCode) == digit)
    }

    @Test(arguments: [UInt16(29), 82, 0, 12, 53, 36])
    func otherKeysAreNoDigits(keyCode: UInt16) {
        // 29 and 82 are the zero keys; the rest are letters, Escape and Return.
        #expect(GroupShortcuts.digit(forKeyCode: keyCode) == nil)
    }

    @Test func requiresExactlyTheChosenModifiers() {
        let modifiers = ShortcutModifiers.controlOption
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [.control, .option], modifiers: modifiers) == 2)
        // Caps Lock and the keypad flag are ignored.
        #expect(GroupShortcuts.digit(keyCode: 84, modifierFlags: [.control, .option, .capsLock, .numericPad], modifiers: modifiers) == 2)
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [], modifiers: modifiers) == nil)
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [.control], modifiers: modifiers) == nil)
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [.control, .option, .shift], modifiers: modifiers) == nil)
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [.control, .option, .command], modifiers: modifiers) == nil)
        #expect(GroupShortcuts.digit(keyCode: 19, modifierFlags: [.control, .option, .command], modifiers: .controlOptionCommand) == 2)
    }

    @Test func modifierSymbolsFollowMenuOrder() {
        #expect(ShortcutModifiers.controlOption.symbols == "⌃⌥")
        #expect(ShortcutModifiers.optionCommand.symbols == "⌥⌘")
        #expect(ShortcutModifiers.controlCommand.symbols == "⌃⌘")
        #expect(ShortcutModifiers.controlOptionCommand.symbols == "⌃⌥⌘")
        #expect(GroupShortcuts.title(digit: 3, modifiers: .controlOption) == "⌃⌥3")
    }

    @Test func digitNOpensTheNthGroup() {
        let groups = Self.groups
        #expect(GroupShortcuts.group(forDigit: 1, in: groups)?.id == groups[0].id)
        #expect(GroupShortcuts.group(forDigit: 9, in: groups)?.id == groups[8].id)
        #expect(GroupShortcuts.group(forDigit: 0, in: groups) == nil)
        #expect(GroupShortcuts.group(forDigit: 10, in: groups) == nil)
        #expect(GroupShortcuts.group(forDigit: 3, in: Array(groups.prefix(2))) == nil)
    }

    @Test func onlyTheFirstNineGroupsHaveShortcuts() {
        let groups = Self.groups
        #expect(GroupShortcuts.digit(forGroup: groups[0].id, in: groups) == 1)
        #expect(GroupShortcuts.digit(forGroup: groups[8].id, in: groups) == 9)
        #expect(GroupShortcuts.digit(forGroup: groups[9].id, in: groups) == nil)
        #expect(GroupShortcuts.digit(forGroup: UUID(), in: groups) == nil)
    }
}

@Suite("Shortcut preferences")
@MainActor
struct ShortcutPreferencesTests {
    private func persistence(in directory: TemporaryDirectory) -> JSONFilePreferencesPersistence {
        JSONFilePreferencesPersistence(fileURL: directory.url.appending(path: "preferences.json"))
    }

    @Test func shortcutsAreOnWithControlOptionByDefault() {
        let defaults = PopupPreferences()
        #expect(defaults.shortcutsEnabled)
        #expect(defaults.shortcutModifiers == .controlOption)
    }

    @Test func turningShortcutsOffIsSavedInPreferencesFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)

        let store = PreferencesStore(persistence: persistence, saveDelay: .zero)
        store.update {
            $0.shortcutsEnabled = false
            $0.shortcutModifiers = .optionCommand
        }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["globalShortcutsEnabled"] as? Bool == false)
        #expect(object?["globalShortcutModifiers"] as? String == "optionCommand")
        let reloaded = PreferencesStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.preferences.shortcutsEnabled == false)
        #expect(reloaded.preferences.shortcutModifiers == .optionCommand)
    }

    @Test func invalidShortcutValuesFallBackToDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data(#"{ "globalShortcutsEnabled": "no", "globalShortcutModifiers": "hyper", "popupShowsTitles": false }"#.utf8)
            .write(to: persistence.fileURL)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences.shortcutsEnabled == true)
        #expect(preferences.shortcutModifiers == .controlOption)
        #expect(preferences.showsTitles == false)
    }

    @Test func filesWithoutShortcutKeysKeepShortcutsOn() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data(#"{ "formatVersion": 1, "panelTheme": "light" }"#.utf8).write(to: persistence.fileURL)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences.theme == .light)
        #expect(preferences.shortcutsEnabled)
    }
}
