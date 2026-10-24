import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: the number shortcuts' keys")
struct NumberShortcutSettingsTests {
    @Test(arguments: ShortcutModifiers.allCases)
    func theEighteenKeysWithTheirModifiers(modifiers: ShortcutModifiers) {
        let numbers = NumberShortcutSettings(enabled: true, modifiers: modifiers)
        let combinations = numbers.combinations
        #expect(combinations.count == 18)
        let keyModifiers = KeyModifiers(modifiers)
        #expect(combinations.keys.allSatisfy { $0.modifiers == keyModifiers })
        #expect(combinations[combo(kVK_ANSI_3, keyModifiers)] == 3)
        #expect(combinations[combo(kVK_ANSI_Keypad3, keyModifiers)] == 3)
        #expect(numbers.digit(for: combo(kVK_ANSI_9, keyModifiers)) == 9)
        #expect(numbers.digit(for: combo(kVK_ANSI_Keypad7, keyModifiers)) == 7)
        #expect(numbers.digit(for: combo(kVK_ANSI_0, keyModifiers)) == nil, "0 has no group")
        #expect(numbers.digit(for: combo(kVK_ANSI_3, keyModifiers.union(.shift))) == nil, "exactly these modifiers")
        for key in combinations.keys {
            #expect(numbers.digit(for: key) == combinations[key])
        }
    }

    @Test func offTakesNoKeys() {
        let numbers = NumberShortcutSettings(enabled: false, modifiers: .controlOption)
        #expect(numbers.combinations.isEmpty)
        #expect(numbers.digit(for: combo(kVK_ANSI_3, [.control, .option])) == nil)
        #expect(NumberShortcutSettings.off.combinations.isEmpty)
    }

    @Test func readFromThePreferences() {
        let numbers = NumberShortcutSettings(PopupPreferences(shortcutsEnabled: true, shortcutModifiers: .optionCommand))
        #expect(numbers == NumberShortcutSettings(enabled: true, modifiers: .optionCommand))
        #expect(NumberShortcutSettings(PopupPreferences()) == NumberShortcutSettings(enabled: true, modifiers: .controlOption))
    }
}

@Suite("Group shortcuts: planning")
struct GroupShortcutPlannerTests {
    private static let controlOption: KeyModifiers = [.control, .option]
    private static let numbers = NumberShortcutSettings(enabled: true, modifiers: .controlOption)

    private func plan(_ groups: [DockGroup], numbers: NumberShortcutSettings = Self.numbers, system: Set<KeyCombination> = []) -> GroupShortcutPlan {
        GroupShortcutPlanner.plan(groups: groups, numbers: numbers, system: system)
    }

    @Test func eachShortcutIsRegisteredInListOrder() {
        let coding = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_C, Self.controlOption, .startOrFinish))
        let plain = DockGroup.numbered(2, shortcut: nil)
        let design = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_D, Self.controlOption))

        let result = plan([coding, plain, design])

        #expect(result.registrations == [
            .init(id: 1, groupID: coding.id, shortcut: coding.shortcut!),
            .init(id: 2, groupID: design.id, shortcut: design.shortcut!),
        ])
        #expect(result.statuses == [coding.id: .on, design.id: .on], "groups without a shortcut have no status")
        #expect(plan([]) == .empty)
    }

    @Test(arguments: ShortcutModifiers.allCases)
    func numberShortcutsComeFirst(modifiers: ShortcutModifiers) {
        let keyModifiers = KeyModifiers(modifiers)
        let numbers = NumberShortcutSettings(enabled: true, modifiers: modifiers)
        let row = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_3, keyModifiers))
        let keypad = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_Keypad8, keyModifiers))
        // ⌃⇧⌘3 is reserved (a screenshot), so 5.
        let shifted = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_5, keyModifiers.union(.shift)))
        let zero = DockGroup.numbered(4, shortcut: makeShortcut(kVK_ANSI_0, keyModifiers))

        let result = plan([row, keypad, shifted, zero], numbers: numbers)

        #expect(result.statuses[row.id] == .off(.numberShortcut(digit: 3)))
        #expect(result.statuses[keypad.id] == .off(.numberShortcut(digit: 8)))
        #expect(result.statuses[shifted.id] == .on, "⇧ added: other keys")
        #expect(result.statuses[zero.id] == .on, "0 isn't a number shortcut")
        #expect(result.registrations.map(\.groupID) == [shifted.id, zero.id])
        #expect(result.registrations.map(\.id) == [1, 2])
    }

    @Test func numberKeysAreFreeWhileTheNumberShortcutsAreOffOrUseOtherModifiers() {
        let group = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_3, Self.controlOption))
        #expect(plan([group], numbers: NumberShortcutSettings(enabled: false, modifiers: .controlOption)).statuses[group.id] == .on)
        #expect(plan([group], numbers: NumberShortcutSettings(enabled: true, modifiers: .controlCommand)).statuses[group.id] == .on)
    }

    @Test func macOSsShortcutsTurnThemOff() {
        let spotlightLike = combo(kVK_ANSI_K, [.control, .option, .command])
        let group = DockGroup.numbered(1, shortcut: GroupShortcut(keys: spotlightLike)!)
        let other = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_K, Self.controlOption))

        let result = plan([group, other], system: [spotlightLike, combo(kVK_Space, .command)])

        #expect(result.statuses[group.id] == .off(.systemShortcut))
        #expect(result.statuses[other.id] == .on)
        #expect(result.registrations.map(\.groupID) == [other.id])
    }

    @Test func theGroupEarlierInTheListKeepsSharedKeys() {
        let first = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption))
        let second = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption, .openAll))
        let third = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption, .startOrFinish))

        let result = plan([first, second, third])

        #expect(result.statuses[first.id] == .on)
        #expect(result.statuses[second.id] == .off(.takenByGroup(first.id)))
        #expect(result.statuses[third.id] == .off(.takenByGroup(first.id)))
        #expect(result.registrations.map(\.groupID) == [first.id])
        // Reordered, the other group keeps them.
        #expect(plan([second, first]).statuses[first.id] == .off(.takenByGroup(second.id)))
    }

    @Test func onlyGroupsThatGotPastTheOtherRulesClaimKeys() {
        let keys = combo(kVK_ANSI_X, Self.controlOption)
        let first = DockGroup.numbered(1, shortcut: GroupShortcut(keys: keys)!)
        let second = DockGroup.numbered(2, shortcut: GroupShortcut(keys: keys)!)
        let result = plan([first, second], system: [keys])
        #expect(result.statuses[first.id] == .off(.systemShortcut))
        #expect(result.statuses[second.id] == .off(.systemShortcut), "macOS's, not the first group's")
    }

    @Test func aRepeatedGroupIsPlannedOnce() {
        let group = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption))
        let result = plan([group, group])
        #expect(result.registrations.count == 1)
        #expect(result.statuses == [group.id: .on])
    }

    @Test func atMostAHundredAreRegistered() {
        // 150 groups with different keys: letters, digits and F-keys with several modifier sets.
        let keyCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_E, kVK_ANSI_G, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_N,
                        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
                        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11]
        let modifierSets: [KeyModifiers] = [[.control, .option], [.control, .command], [.control, .option, .shift], [.control, .shift, .command], [.control, .option, .command]]
        var groups: [DockGroup] = []
        for modifiers in modifierSets {
            for keyCode in keyCodes {
                groups.append(.numbered(groups.count + 1, shortcut: makeShortcut(keyCode, modifiers)))
            }
        }
        #expect(groups.count == 150)

        let result = plan(groups, numbers: .off)

        #expect(result.registrations.count == GroupShortcutPlanner.maximumRegistrations)
        #expect(result.registrations.map(\.id) == Array(1...100).map(UInt32.init))
        #expect(result.registrations.map(\.groupID) == groups.prefix(100).map(\.id))
        #expect(groups.dropFirst(100).allSatisfy { result.statuses[$0.id] == .limitReached })
    }

    @Test func theRecordersRefusalAgreesWithThePlan() {
        let keyModifiers = Self.controlOption
        let design = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_D, keyModifiers))
        let coding = DockGroup.numbered(2, shortcut: nil)
        let groups = [design, coding]
        let system: Set<KeyCombination> = [combo(kVK_ANSI_K, [.control, .option, .command])]
        let candidates = [
            combo(kVK_ANSI_C, keyModifiers),                     // free
            combo(kVK_ANSI_D, keyModifiers),                     // Design's
            combo(kVK_ANSI_4, keyModifiers),                     // a number shortcut
            combo(kVK_ANSI_K, [.control, .option, .command]),    // macOS's
        ]
        for keys in candidates {
            let refusal = GroupShortcutPlanner.refusal(for: keys, group: coding.id, groups: groups, numbers: Self.numbers, system: system)
            var withIt = coding
            withIt.shortcut = GroupShortcut(keys: keys)
            let status = plan([design, withIt], system: system).statuses[coding.id]
            #expect(status == (refusal.map(GroupShortcutStatus.off) ?? .on), "\(keys.title)")
        }
        #expect(GroupShortcutPlanner.refusal(for: combo(kVK_ANSI_D, keyModifiers), group: coding.id, groups: groups, numbers: Self.numbers, system: system) == .takenByGroup(design.id))
        #expect(GroupShortcutPlanner.refusal(for: combo(kVK_ANSI_D, keyModifiers), group: design.id, groups: groups, numbers: Self.numbers, system: system) == nil, "its own keys")
        // Static rules first.
        #expect(GroupShortcutPlanner.refusal(for: combo(kVK_ANSI_C, .command), group: coding.id, groups: groups, numbers: Self.numbers, system: system) == .tooFewModifiers)
        #expect(GroupShortcutPlanner.refusal(for: combo(kVK_ANSI_Q, [.control, .command]), group: coding.id, groups: groups, numbers: Self.numbers, system: system) == .reserved)
    }

    @Test func theRecorderRefusesKeysAnyOtherGroupHasWhereverItIs() {
        let later = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_D, Self.controlOption))
        let earlier = DockGroup.numbered(1, shortcut: nil)
        #expect(GroupShortcutPlanner.refusal(for: later.shortcut!.keys, group: earlier.id, groups: [earlier, later], numbers: Self.numbers, system: []) == .takenByGroup(later.id))
    }
}
