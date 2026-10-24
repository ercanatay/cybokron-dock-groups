import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: the recorder's key presses")
struct ShortcutRecorderInputTests {
    @Test func eventModifiersCountTheFourModifierKeysOnly() {
        #expect(KeyModifiers(eventFlags: [.control, .option, .shift, .command]) == [.control, .option, .shift, .command])
        #expect(KeyModifiers(eventFlags: [.capsLock, .function, .numericPad, .help]) == [])
        #expect(KeyModifiers(eventFlags: [.control, .function, .numericPad]) == [.control], "arrows and F-keys carry fn")
        #expect(KeyModifiers(eventFlags: [.option, .command, .capsLock]) == [.option, .command])
    }

    @Test func escapeCancelsWhateverIsHeld() {
        #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(kVK_Escape), modifierFlags: []) == .cancel)
        #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(kVK_Escape), modifierFlags: [.control, .option]) == .cancel)
    }

    @Test func deleteRemovesTheShortcutUnlessModifiersAreHeld() {
        for keyCode in [kVK_Delete, kVK_ForwardDelete] {
            #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(keyCode), modifierFlags: []) == .clear)
            #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(keyCode), modifierFlags: [.shift, .function]) == .clear)
            // Held with ⌃⌥ it's keys — which rule K2 refuses, with a message.
            let keys = combo(keyCode, [.control, .option])
            #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(keyCode), modifierFlags: [.control, .option]) == .keys(keys))
            #expect(GroupShortcut.staticRefusal(for: keys) == .keyNotAllowed)
        }
    }

    @Test func anyOtherKeyIsKeysToCheck() {
        #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.control, .option, .capsLock])
            == .keys(combo(kVK_ANSI_C, [.control, .option])))
        #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(kVK_F5), modifierFlags: [.option, .command, .function])
            == .keys(combo(kVK_F5, [.option, .command])))
        #expect(ShortcutRecorderInput.interpret(keyCode: UInt16(kVK_ANSI_C), modifierFlags: .command) == .keys(combo(kVK_ANSI_C, .command)),
                "⌘C is recorded as keys, then refused by K1")
    }
}

@Suite("Group shortcuts: macOS's own shortcuts")
struct SystemShortcutListTests {
    /// Entries as `CopySymbolicHotKeys` returned them on macOS 27 (`docs/design/shortcut-spike.md`).
    private static let spikeEntries: [SystemShortcutList.Entry] = [
        .init(keyCode: 53, carbonModifiers: 0x900, isEnabled: true),       // ⌥⌘⎋ Force Quit
        .init(keyCode: 48, carbonModifiers: 0x100, isEnabled: true),       // ⌘⇥
        .init(keyCode: 49, carbonModifiers: 0x1100, isEnabled: true),      // ⌃⌘Space Character Viewer
        .init(keyCode: 49, carbonModifiers: 0x1800, isEnabled: true),      // ⌃⌥Space next input source
        .init(keyCode: 2, carbonModifiers: 0x900, isEnabled: true),        // ⌥⌘D Dock
        .init(keyCode: 1, carbonModifiers: 0x1100, isEnabled: true),       // ⌃⌘S
        .init(keyCode: 20, carbonModifiers: 0x1300, isEnabled: true),      // ⌃⇧⌘3
        .init(keyCode: 120, carbonModifiers: 0x21000, isEnabled: true),    // ⌃F2 with the fn bit
        .init(keyCode: 28, carbonModifiers: 0x900, isEnabled: false),      // ⌥⌘8, off
        .init(keyCode: 129, carbonModifiers: 0x20000, isEnabled: true),    // a top-row key
        .init(keyCode: 65535, carbonModifiers: 0, isEnabled: true),
        .init(keyCode: -1, carbonModifiers: 0x900, isEnabled: true),
    ]

    @Test func turnedOnEntriesWithCarbonModifierBits() {
        let combinations = SystemShortcutList.combinations(from: Self.spikeEntries)

        #expect(combinations == [
            combo(kVK_Escape, [.option, .command]),
            combo(kVK_Tab, .command),
            combo(kVK_Space, [.control, .command]),
            combo(kVK_Space, [.control, .option]),
            combo(kVK_ANSI_D, [.option, .command]),
            combo(kVK_ANSI_S, [.control, .command]),
            combo(kVK_ANSI_3, [.control, .shift, .command]),
            combo(kVK_F2, .control),
        ])
    }

    @Test func aGroupShortcutOnOneIsOff() {
        let system = SystemShortcutList.combinations(from: Self.spikeEntries)
        let group = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_S, [.control, .command]))
        let other = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_8, [.option, .command, .shift]))

        let plan = GroupShortcutPlanner.plan(groups: [group, other], numbers: .off, system: system)

        #expect(plan.statuses[group.id] == .off(.systemShortcut))
        #expect(plan.statuses[other.id] == .on)
        #expect(GroupShortcutPlanner.refusal(for: combo(kVK_ANSI_S, [.control, .command]), group: other.id, groups: [other], numbers: .off, system: system) == .systemShortcut)
    }
}

@Suite("Group shortcuts: key names")
struct KeyCodeNamesLayoutTests {
    @Test func lettersAndPunctuationDependOnTheLayout() {
        for keyCode in [kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_I, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Grave, kVK_ISO_Section] {
            #expect(KeyCodeNames.dependsOnLayout(UInt16(keyCode)), "key \(keyCode)")
        }
        for keyCode in [kVK_ANSI_3, kVK_ANSI_0, kVK_ANSI_Keypad3, kVK_F5, kVK_LeftArrow, kVK_Space, kVK_Escape] {
            #expect(!KeyCodeNames.dependsOnLayout(UInt16(keyCode)), "key \(keyCode)")
        }
    }
}

@Suite("Group shortcuts: diagnostics")
struct GroupShortcutDiagnosticsTests {
    private func report(groups: [DockGroup], statuses: [DockGroup.ID: GroupShortcutStatus]) -> String {
        DiagnosticsReport.text(for: DiagnosticsInfo(
            app: .init(version: "0.9.0", build: "900", path: "/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "27.0.1", hardwareModel: "Mac15,6", architecture: "arm64"),
            isAccessibilityTrusted: false,
            isStatusItemShown: true,
            preferences: PopupPreferences(),
            updates: .init(lastCheckDate: nil, lastResult: "not checked"),
            groups: groups,
            groupShortcutStatuses: statuses,
            recentErrors: []
        ))
    }

    @Test func onlyCountsAreReported() {
        let groups = [
            DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_C, [.control, .option])),
            DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_3, [.control, .option])),
            DockGroup.numbered(3, shortcut: makeShortcut(kVK_F13, [.control, .command], .startOrFinish)),
            DockGroup.numbered(4, shortcut: nil),
        ]
        let statuses: [DockGroup.ID: GroupShortcutStatus] = [
            groups[0].id: .on, groups[1].id: .off(.numberShortcut(digit: 3)), groups[2].id: .on,
        ]

        let text = report(groups: groups, statuses: statuses)

        #expect(text.contains("Group shortcuts: 3 (2 on, 1 off)"))
        #expect(!text.contains("⌃⌥C") && !text.contains("⌃⌘F13"), "no keys")
        #expect(report(groups: [DockGroup.numbered(1, shortcut: nil)], statuses: [:]).contains("Group shortcuts: none"))
    }
}
