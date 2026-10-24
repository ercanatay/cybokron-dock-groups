import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: hot keys")
@MainActor
struct GroupShortcutRegistrarTests {
    private static let controlOption: KeyModifiers = [.control, .option]

    @MainActor
    private final class Presses {
        var digits: [Int] = []
        var groups: [String] = []
    }

    @MainActor
    private struct Rig {
        let system = FakeHotKeys()
        let clock = TestClock()
        let presses = Presses()
        let registrar: GroupHotKeyRegistrar

        init() {
            let clock = clock
            registrar = GroupHotKeyRegistrar(system: system, clock: { clock.now })
            let presses = presses
            registrar.onShortcut = { presses.digits.append($0) }
            registrar.onGroupShortcut = { id, action in presses.groups.append("\(id.uuidString.suffix(2)):\(action.rawValue)") }
        }
    }

    private static let coding = DockGroup.numbered(1, shortcut: makeShortcut(kVK_ANSI_C, controlOption, .startOrFinish))
    private static let design = DockGroup.numbered(2, shortcut: makeShortcut(kVK_F13, [.control, .command]))

    private func plan(_ groups: [DockGroup], numbers: NumberShortcutSettings = .off, system: Set<KeyCombination> = []) -> GroupShortcutPlan {
        GroupShortcutPlanner.plan(groups: groups, numbers: numbers, system: system)
    }

    @Test func groupShortcutsAreRegisteredUnderTheirOwnSignature() {
        let rig = Rig()
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        #expect(rig.system.registered == [
            .init(keys: Self.coding.shortcut!.keys, signature: GroupHotKeys.groupSignature, id: 1),
            .init(keys: Self.design.shortcut!.keys, signature: GroupHotKeys.groupSignature, id: 2),
        ])
        #expect(rig.registrar.groupStatuses == [Self.coding.id: .on, Self.design.id: .on])
        #expect(rig.registrar.mode == .off, "the number shortcuts aren't touched")
        #expect(GroupHotKeys.groupSignature == 0x4344_4773) // "CDGs"
        #expect(GroupHotKeys.groupSignature != GroupHotKeys.signature)
    }

    @Test func pressingAGroupShortcutReportsItsGroupAndAction() {
        let rig = Rig()
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        #expect(rig.system.press(Self.coding.shortcut!.keys))
        rig.clock.advance(1)
        #expect(rig.system.press(Self.design.shortcut!.keys))

        #expect(rig.presses.groups == ["01:startOrFinish", "02:showPopup"])
        #expect(rig.presses.digits.isEmpty)
        // An id of no registration, and the number shortcuts' signature with a group's id, do nothing.
        #expect(!rig.system.press(signature: GroupHotKeys.groupSignature, id: 9))
        #expect(!rig.system.press(signature: GroupHotKeys.signature, id: 1))
        #expect(!rig.system.press(signature: 0x4142_4344, id: 1))
    }

    @Test func pressesCloserThanTheRepeatIntervalCountOnce() {
        let rig = Rig()
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))
        let keys = Self.coding.shortcut!.keys

        #expect(rig.system.press(keys))
        rig.clock.advance(0.2)
        #expect(rig.system.press(keys), "still taken, but not acted on")
        rig.clock.advance(0.1)
        #expect(rig.system.press(Self.design.shortcut!.keys), "another group's isn't held back")
        rig.clock.advance(0.15)
        #expect(rig.system.press(keys))

        #expect(rig.presses.groups == ["01:startOrFinish", "02:showPopup", "01:startOrFinish"])
        #expect(GroupHotKeyRegistrar.repeatInterval == 0.4)
    }

    @Test func aRefusedGroupShortcutIsOffAloneAndNothingFallsBack() {
        let rig = Rig()
        rig.system.failures[Self.coding.shortcut!.keys] = OSStatus(eventHotKeyExistsErr)
        rig.registrar.apply(enabled: true, modifiers: .controlOption)

        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design], numbers: NumberShortcutSettings(enabled: true, modifiers: .controlOption)))

        #expect(rig.registrar.groupStatuses == [Self.coding.id: .unavailable(OSStatus(eventHotKeyExistsErr)), Self.design.id: .on])
        #expect(rig.registrar.mode == .hotKeys, "the number shortcuts stay hot keys")
        #expect(rig.system.registered(signature: GroupHotKeys.signature).count == 18)
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).map(\.keys) == [Self.design.shortcut!.keys])
        #expect(!rig.system.press(signature: GroupHotKeys.groupSignature, id: 1), "the refused one isn't pressed")
    }

    @Test func applyingTheNumberShortcutsKeepsTheGroupShortcuts() {
        let rig = Rig()
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        #expect(rig.registrar.apply(enabled: true, modifiers: .controlOption) == .hotKeys)
        #expect(rig.registrar.apply(enabled: true, modifiers: .controlCommand) == .hotKeys)

        #expect(rig.system.registered(signature: GroupHotKeys.signature).count == 18)
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).map(\.keys) == [Self.coding.shortcut!.keys, Self.design.shortcut!.keys])
        #expect(rig.registrar.groupStatuses.values.allSatisfy { $0.isOn })

        #expect(rig.registrar.apply(enabled: false, modifiers: .controlCommand) == .off)
        #expect(rig.system.registered(signature: GroupHotKeys.signature).isEmpty)
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).count == 2, "turning the number shortcuts off leaves the groups' on")
        #expect(rig.system.press(Self.coding.shortcut!.keys))
    }

    /// A plan made while the number shortcuts were off, then the numbers turned on with the same
    /// keys: the digits are registered first and get all 18 keys, and the group shortcut on a
    /// number key is the one that's off.
    @Test func numberShortcutsAreRegisteredBeforeGroupShortcuts() {
        let rig = Rig()
        let onThree = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_3, Self.controlOption))
        rig.registrar.applyGroupShortcuts(plan([onThree, Self.design]))
        #expect(rig.registrar.groupStatuses[onThree.id] == .on)

        let mode = rig.registrar.apply(enabled: true, modifiers: .controlOption)

        #expect(mode == .hotKeys, "a group shortcut never makes the digits fall back to event monitors")
        #expect(rig.system.registered(signature: GroupHotKeys.signature).count == 18)
        #expect(rig.registrar.groupStatuses[onThree.id] == .unavailable(OSStatus(eventHotKeyExistsErr)))
        #expect(rig.registrar.groupStatuses[Self.design.id] == .on)
        // The order of the calls: groups let go, the digits, then the groups again.
        let calls = rig.system.calls.drop(while: { $0.hasPrefix("CDGs") }).map { String($0.prefix(4)) }
        #expect(calls == Array(repeating: "CDGr", count: 18) + ["CDGs", "CDGs"])
        // The digit is pressed as a number shortcut.
        #expect(rig.system.press(signature: GroupHotKeys.signature, id: UInt32(kVK_ANSI_3)))
        #expect(rig.presses.digits == [3] && rig.presses.groups.isEmpty)
    }

    @Test func aNumberShortcutFallbackLeavesTheGroupShortcutsRegistered() {
        let rig = Rig()
        rig.system.failures[combo(kVK_ANSI_4, Self.controlOption)] = OSStatus(eventInternalErr)
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        #expect(rig.registrar.apply(enabled: true, modifiers: .controlOption) == .eventMonitors(OSStatus(eventInternalErr)))

        #expect(rig.system.registered(signature: GroupHotKeys.signature).isEmpty, "the digits stay all or none")
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).count == 2)
        #expect(rig.system.press(Self.design.shortcut!.keys))
        #expect(rig.presses.groups == ["02:showPopup"])
    }

    @Test func aNewPlanReplacesTheRegistrationsAndTheirIds() {
        let rig = Rig()
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        rig.registrar.applyGroupShortcuts(plan([Self.design]))

        #expect(rig.system.registered == [.init(keys: Self.design.shortcut!.keys, signature: GroupHotKeys.groupSignature, id: 1)])
        #expect(rig.registrar.groupStatuses == [Self.design.id: .on])
        #expect(rig.system.press(signature: GroupHotKeys.groupSignature, id: 1))
        #expect(!rig.system.press(signature: GroupHotKeys.groupSignature, id: 2))
        #expect(rig.presses.groups == ["02:showPopup"])

        rig.registrar.applyGroupShortcuts(.empty)
        #expect(rig.system.registered.isEmpty)
        #expect(rig.registrar.groupStatuses.isEmpty)
    }

    @Test func thePlansOffStatusesAreKept() {
        let rig = Rig()
        let onThree = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_3, Self.controlOption))
        rig.registrar.applyGroupShortcuts(plan([onThree, Self.design], numbers: NumberShortcutSettings(enabled: true, modifiers: .controlOption)))
        #expect(rig.registrar.groupStatuses == [onThree.id: .off(.numberShortcut(digit: 3)), Self.design.id: .on])
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).count == 1)
    }

    @Test func suspendingLetsGoOfEveryHotKeyUntilResumed() {
        let rig = Rig()
        rig.registrar.apply(enabled: true, modifiers: .controlOption)
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))
        let before = rig.system.registered

        rig.registrar.suspend()

        #expect(rig.registrar.isSuspended)
        #expect(rig.system.registered.isEmpty, "the recorder gets every key")
        #expect(rig.registrar.groupStatuses == [Self.coding.id: .paused, Self.design.id: .paused])
        #expect(!rig.registrar.handlePress(signature: GroupHotKeys.groupSignature, id: 1))
        #expect(!rig.registrar.handlePress(signature: GroupHotKeys.signature, id: UInt32(kVK_ANSI_1)))
        #expect(rig.presses.groups.isEmpty && rig.presses.digits.isEmpty)
        rig.registrar.suspend()

        #expect(rig.registrar.resume() == .hotKeys)

        #expect(!rig.registrar.isSuspended)
        #expect(rig.system.registered == before)
        #expect(rig.registrar.groupStatuses == [Self.coding.id: .on, Self.design.id: .on])
        #expect(rig.system.press(Self.coding.shortcut!.keys))
        #expect(rig.registrar.resume() == .hotKeys, "resuming twice changes nothing")
        #expect(rig.system.registered == before)
    }

    @Test func changesWhileSuspendedApplyOnResume() {
        let rig = Rig()
        rig.registrar.apply(enabled: true, modifiers: .controlOption)
        rig.registrar.applyGroupShortcuts(plan([Self.coding]))
        rig.registrar.suspend()

        rig.registrar.apply(enabled: true, modifiers: .optionCommand)
        rig.registrar.applyGroupShortcuts(plan([Self.coding, Self.design]))

        #expect(rig.system.registered.isEmpty, "nothing is registered while suspended")
        #expect(rig.registrar.groupStatuses == [Self.coding.id: .paused, Self.design.id: .paused])

        rig.registrar.resume()

        #expect(rig.system.registered(signature: GroupHotKeys.signature).allSatisfy { $0.keys.modifiers == [.option, .command] })
        #expect(rig.system.registered(signature: GroupHotKeys.signature).count == 18)
        #expect(rig.system.registered(signature: GroupHotKeys.groupSignature).count == 2)
    }

    @Test func resumingWithoutNumberSettingsRegistersTheGroupShortcutsOnly() {
        let rig = Rig()
        rig.registrar.suspend()
        rig.registrar.applyGroupShortcuts(plan([Self.design]))

        #expect(rig.registrar.resume() == .off)

        #expect(rig.system.registered == [.init(keys: Self.design.shortcut!.keys, signature: GroupHotKeys.groupSignature, id: 1)])
    }

    @Test func eachSignatureIsLetGoOnItsOwn() {
        let system = FakeHotKeys()
        _ = system.register(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: 0x1800, signature: GroupHotKeys.signature, id: 1)
        _ = system.register(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: 0x1800, signature: GroupHotKeys.groupSignature, id: 1)

        system.unregisterAll(signature: GroupHotKeys.groupSignature)

        #expect(system.registered.map(\.signature) == [GroupHotKeys.signature])
    }
}
