import Carbon.HIToolbox
import DockGroupsCore

/// The app's system-wide hot keys, registered with Carbon's `RegisterEventHotKey` on the
/// application event target. They need no Accessibility access, and a press goes to this app
/// alone: the app in front doesn't receive it. Other apps may register the same keys (hot keys
/// aren't exclusive); all of them are then told of a press.
///
/// One instance serves the process, which gets the presses of all its hot keys through the one
/// handler installed here. The hot keys are kept by signature, so the number shortcuts and the
/// groups' own shortcuts are let go apart.
@MainActor
final class CarbonHotKeys: HotKeyRegistering {
    static let shared = CarbonHotKeys()

    var onPress: ((OSType, UInt32) -> Bool)?

    private var handler: EventHandlerRef?
    private var hotKeys: [OSType: [EventHotKeyRef]] = [:]

    private init() {}

    func register(keyCode: UInt32, carbonModifiers: UInt32, signature: OSType, id: UInt32) -> OSStatus {
        let installed = installHandlerIfNeeded()
        guard installed == OSStatus(noErr) else { return installed }
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard status == OSStatus(noErr) else { return status }
        guard let hotKey else { return OSStatus(eventInternalErr) }
        hotKeys[signature, default: []].append(hotKey)
        return status
    }

    func unregisterAll(signature: OSType) {
        for hotKey in hotKeys.removeValue(forKey: signature) ?? [] {
            UnregisterEventHotKey(hotKey)
        }
    }

    /// Installed with the first hot key and kept: it costs nothing while none is registered.
    private func installHandlerIfNeeded() -> OSStatus {
        guard handler == nil else { return OSStatus(noErr) }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), carbonHotKeyPressed, 1, &pressed, nil, &handler)
    }

    fileprivate func pressed(_ id: EventHotKeyID) -> Bool {
        onPress?(id.signature, id.id) ?? false
    }
}

/// Carbon's handler for a hot key press, called on the main thread: reads which hot key it was
/// and hands it to `CarbonHotKeys.shared`. Presses it doesn't use go on to the next handler.
private func carbonHotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == OSStatus(noErr) else { return OSStatus(eventNotHandledErr) }
    let used = MainActor.assumeIsolated { CarbonHotKeys.shared.pressed(id) }
    return used ? OSStatus(noErr) : OSStatus(eventNotHandledErr)
}
