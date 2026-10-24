import Carbon.HIToolbox
import Testing
@testable import DockGroupsCore

@Suite("Global shortcuts as hot keys")
@MainActor
struct GroupHotKeysTests {
    /// Stands in for Carbon: records the hot keys registered, fails the key codes it's told to, and
    /// refuses to register a key and modifiers twice, as `RegisterEventHotKey` does in one process.
    private final class FakeHotKeySystem: HotKeyRegistering {
        struct Registration: Equatable {
            let keyCode: UInt32
            let modifiers: UInt32
            let signature: OSType
            let id: UInt32
        }

        var onPress: ((OSType, UInt32) -> Bool)?
        /// The status `register` returns for a key code instead of registering it.
        var failures: [UInt32: OSStatus] = [:]
        private(set) var registered: [Registration] = []

        func register(keyCode: UInt32, carbonModifiers: UInt32, signature: OSType, id: UInt32) -> OSStatus {
            if let status = failures[keyCode] { return status }
            guard !registered.contains(where: { $0.keyCode == keyCode && $0.modifiers == carbonModifiers }) else {
                return OSStatus(eventHotKeyExistsErr)
            }
            registered.append(Registration(keyCode: keyCode, modifiers: carbonModifiers, signature: signature, id: id))
            return OSStatus(noErr)
        }

        func unregisterAll(signature: OSType) {
            registered.removeAll { $0.signature == signature }
        }

        /// Carbon telling the app a hot key was pressed.
        @discardableResult
        func press(keyCode: UInt32, signature: OSType = GroupHotKeys.signature) -> Bool {
            onPress?(signature, keyCode) ?? false
        }
    }

    private func registrar(_ system: FakeHotKeySystem) -> (GroupHotKeyRegistrar, Recorder) {
        let registrar = GroupHotKeyRegistrar(system: system)
        let recorder = Recorder()
        registrar.onShortcut = { recorder.digits.append($0) }
        return (registrar, recorder)
    }

    private final class Recorder {
        var digits: [Int] = []
    }

    // MARK: - Keys and modifiers

    @Test func everyDigitKeyOfTheNumberRowAndKeypadIsAHotKey() {
        let hotKeys = GroupHotKeys.all
        #expect(hotKeys.count == 18)
        #expect(Set(hotKeys.map(\.id)).count == hotKeys.count, "ids tell the keys apart")
        for hotKey in hotKeys {
            #expect(GroupShortcuts.digit(forKeyCode: hotKey.keyCode) == hotKey.digit)
            #expect(hotKey.id == UInt32(hotKey.keyCode))
        }
        // Each digit on the number row (kVK_ANSI_1…9) and on the keypad (kVK_ANSI_Keypad1…9).
        let byDigit = Dictionary(grouping: hotKeys, by: \.digit).mapValues { Set($0.map(\.keyCode)) }
        #expect(byDigit[1] == [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_Keypad1)])
        #expect(byDigit[5] == [UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_Keypad5)])
        #expect(byDigit[9] == [UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_Keypad9)])
        #expect(Set(byDigit.keys) == Set(GroupShortcuts.digits))
        #expect(!hotKeys.contains { [kVK_ANSI_0, kVK_ANSI_Keypad0].contains(Int($0.keyCode)) }, "0 has no group")
    }

    @Test(arguments: [
        (ShortcutModifiers.controlOption, controlKey | optionKey),
        (.optionCommand, optionKey | cmdKey),
        (.controlCommand, controlKey | cmdKey),
        (.controlOptionCommand, controlKey | optionKey | cmdKey),
    ])
    func modifiersBecomeCarbonModifierBits(modifiers: ShortcutModifiers, bits: Int) {
        #expect(GroupHotKeys.carbonModifiers(for: modifiers) == UInt32(bits))
        #expect(GroupHotKeys.carbonModifiers(for: modifiers) & UInt32(shiftKey) == 0)
    }

    @Test func carbonModifierBitsAreTheDocumentedValues() {
        // ⌘ 1 << 8, ⇧ 1 << 9, ⌥ 1 << 11, ⌃ 1 << 12 (Events.h).
        #expect(GroupHotKeys.carbonModifiers(for: .controlOption) == 0x1800)
        #expect(GroupHotKeys.carbonModifiers(for: .optionCommand) == 0x0900)
        #expect(GroupHotKeys.carbonModifiers(for: .controlCommand) == 0x1100)
        #expect(GroupHotKeys.carbonModifiers(for: .controlOptionCommand) == 0x1900)
    }

    @Test func signatureSpellsTheAppsCode() {
        #expect(GroupHotKeys.signature == 0x4344_4772) // "CDGr"
    }

    @Test func onlyTheAppsHotKeysAreDigits() {
        #expect(GroupHotKeys.digit(signature: GroupHotKeys.signature, id: UInt32(kVK_ANSI_3)) == 3)
        #expect(GroupHotKeys.digit(signature: GroupHotKeys.signature, id: UInt32(kVK_ANSI_Keypad7)) == 7)
        #expect(GroupHotKeys.digit(signature: GroupHotKeys.signature, id: UInt32(kVK_ANSI_0)) == nil)
        #expect(GroupHotKeys.digit(signature: GroupHotKeys.signature, id: 0x1_0000 + UInt32(kVK_ANSI_3)) == nil)
        #expect(GroupHotKeys.digit(signature: 0x4142_4344, id: UInt32(kVK_ANSI_3)) == nil)
    }

    // MARK: - Registering

    @Test func registeredHotKeysNeedNoEventMonitors() {
        let system = FakeHotKeySystem()
        let (registrar, _) = registrar(system)

        #expect(registrar.apply(enabled: true, modifiers: .controlOption) == .hotKeys)

        #expect(registrar.mode == .hotKeys)
        #expect(system.registered.count == 18)
        #expect(system.registered.allSatisfy { $0.modifiers == UInt32(controlKey | optionKey) && $0.signature == GroupHotKeys.signature })
        #expect(system.registered.map(\.id) == GroupHotKeys.all.map(\.id))
        #expect(system.registered.map(\.keyCode) == GroupHotKeys.all.map { UInt32($0.keyCode) })
    }

    @Test func aKeyTakenFallsBackToEventMonitorsWithNoHotKeyLeft() {
        let system = FakeHotKeySystem()
        system.failures[UInt32(kVK_ANSI_4)] = OSStatus(eventHotKeyExistsErr)
        let (registrar, recorder) = registrar(system)

        let mode = registrar.apply(enabled: true, modifiers: .controlOption)

        #expect(mode == .eventMonitors(OSStatus(eventHotKeyExistsErr)))
        #expect(registrar.mode == mode)
        #expect(system.registered.isEmpty, "all or none: the keys registered before the failure are let go")
        // The monitors notice key presses then; a stray hot key press does nothing.
        #expect(!system.press(keyCode: UInt32(kVK_ANSI_1)))
        #expect(recorder.digits.isEmpty)
    }

    @Test func anyFailureFallsBack() {
        let system = FakeHotKeySystem()
        system.failures[UInt32(kVK_ANSI_Keypad9)] = OSStatus(eventInternalErr)
        let (registrar, _) = registrar(system)

        #expect(registrar.apply(enabled: true, modifiers: .optionCommand) == .eventMonitors(OSStatus(eventInternalErr)))
        #expect(system.registered.isEmpty)
    }

    @Test func turnedOffRegistersNothingAndLetsGoOfTheHotKeys() {
        let system = FakeHotKeySystem()
        let (registrar, _) = registrar(system)
        registrar.apply(enabled: true, modifiers: .controlOption)

        #expect(registrar.apply(enabled: false, modifiers: .controlOption) == .off)

        #expect(system.registered.isEmpty)
        #expect(!system.press(keyCode: UInt32(kVK_ANSI_1)))
    }

    @Test func otherModifiersReplaceTheHotKeys() {
        let system = FakeHotKeySystem()
        let (registrar, _) = registrar(system)
        registrar.apply(enabled: true, modifiers: .controlOption)

        // The same keys again would be refused (eventHotKeyExistsErr) if the old ones stayed.
        #expect(registrar.apply(enabled: true, modifiers: .controlOption) == .hotKeys)
        #expect(registrar.apply(enabled: true, modifiers: .controlOptionCommand) == .hotKeys)

        #expect(system.registered.count == 18)
        #expect(system.registered.allSatisfy { $0.modifiers == UInt32(controlKey | optionKey | cmdKey) })
    }

    @Test func hotKeysAreTriedAgainWithTheNextSettings() {
        let system = FakeHotKeySystem()
        system.failures[UInt32(kVK_ANSI_1)] = OSStatus(eventHotKeyExistsErr)
        let (registrar, recorder) = registrar(system)
        #expect(registrar.apply(enabled: true, modifiers: .controlOption) == .eventMonitors(OSStatus(eventHotKeyExistsErr)))

        system.failures = [:]
        #expect(registrar.apply(enabled: true, modifiers: .controlCommand) == .hotKeys)
        system.press(keyCode: UInt32(kVK_ANSI_1))
        #expect(recorder.digits == [1])
    }

    // MARK: - Pressing

    @Test func pressingAHotKeyOpensItsDigit() {
        let system = FakeHotKeySystem()
        let (registrar, recorder) = registrar(system)
        registrar.apply(enabled: true, modifiers: .controlOption)

        #expect(system.press(keyCode: UInt32(kVK_ANSI_3)))
        #expect(system.press(keyCode: UInt32(kVK_ANSI_Keypad3)))
        #expect(system.press(keyCode: UInt32(kVK_ANSI_9)))

        #expect(recorder.digits == [3, 3, 9])
    }

    @Test func otherHotKeysAreLeftToTheirHandlers() {
        let system = FakeHotKeySystem()
        let (registrar, recorder) = registrar(system)
        registrar.apply(enabled: true, modifiers: .controlOption)

        #expect(!system.press(keyCode: UInt32(kVK_ANSI_3), signature: 0x4142_4344))
        #expect(!system.press(keyCode: UInt32(kVK_ANSI_0)))
        #expect(recorder.digits.isEmpty)
    }
}
