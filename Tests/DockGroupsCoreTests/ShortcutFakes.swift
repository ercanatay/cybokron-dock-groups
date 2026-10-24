import Carbon.HIToolbox
import Foundation
@testable import DockGroupsCore

/// Stands in for Carbon in the group shortcut tests: records the hot keys registered, by signature,
/// fails the combinations it's told to, and refuses a key and modifiers registered twice in the
/// process, as `RegisterEventHotKey` does.
@MainActor
final class FakeHotKeys: HotKeyRegistering {
    struct Registration: Equatable {
        let keys: KeyCombination
        let signature: OSType
        let id: UInt32
    }

    var onPress: ((OSType, UInt32) -> Bool)?
    /// The status `register` returns for a combination instead of registering it.
    var failures: [KeyCombination: OSStatus] = [:]
    private(set) var registered: [Registration] = []
    /// Every `register` call, in order, as "<signature>:<title>".
    private(set) var calls: [String] = []

    func register(keyCode: UInt32, carbonModifiers: UInt32, signature: OSType, id: UInt32) -> OSStatus {
        let keys = KeyCombination(keyCode: UInt16(keyCode), modifiers: KeyModifiers(carbonBits: carbonModifiers))
        calls.append("\(Self.name(of: signature)):\(keys.title)")
        if let status = failures[keys] { return status }
        guard !registered.contains(where: { $0.keys == keys }) else { return OSStatus(eventHotKeyExistsErr) }
        registered.append(Registration(keys: keys, signature: signature, id: id))
        return OSStatus(noErr)
    }

    func unregisterAll(signature: OSType) {
        registered.removeAll { $0.signature == signature }
    }

    /// The hot keys registered with this signature.
    func registered(signature: OSType) -> [Registration] {
        registered.filter { $0.signature == signature }
    }

    /// Carbon telling the app a hot key was pressed.
    @discardableResult
    func press(signature: OSType, id: UInt32) -> Bool {
        onPress?(signature, id) ?? false
    }

    /// Carbon telling the app the registered hot key with these keys was pressed.
    @discardableResult
    func press(_ keys: KeyCombination) -> Bool {
        guard let registration = registered.first(where: { $0.keys == keys }) else { return false }
        return press(signature: registration.signature, id: registration.id)
    }

    static func name(of signature: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((signature >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }
}

/// Keys with these modifiers.
func combo(_ keyCode: Int, _ modifiers: KeyModifiers) -> KeyCombination {
    KeyCombination(keyCode: UInt16(keyCode), modifiers: modifiers)
}

/// A shortcut the static rules take; the test fails at once otherwise.
func makeShortcut(_ keyCode: Int, _ modifiers: KeyModifiers, _ action: GroupShortcutAction = .showPopup) -> GroupShortcut {
    guard let shortcut = GroupShortcut(keys: combo(keyCode, modifiers), action: action) else {
        preconditionFailure("\(combo(keyCode, modifiers).title) isn't a valid group shortcut")
    }
    return shortcut
}

extension DockGroup {
    /// An empty group with this shortcut and a fixed identifier from `number`.
    static func numbered(_ number: Int, shortcut: GroupShortcut?) -> DockGroup {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
        return DockGroup(id: id, name: "Group \(number)", shortcut: shortcut)
    }
}
