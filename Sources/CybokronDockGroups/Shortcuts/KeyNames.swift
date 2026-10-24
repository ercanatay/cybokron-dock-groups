import Carbon.HIToolbox
import DockGroupsCore
import Foundation

/// Key combinations as the user's keyboard shows them: letters and punctuation with the character
/// of the current keyboard layout able to type ASCII (the one macOS names menu shortcuts with, so a
/// Russian layout shows Latin letters), uppercased in the user's language ("ı" → "I" on a Turkish
/// keyboard). Digits and keys that print nothing keep the core's names (`KeyCodeNames`).
@MainActor
enum KeyNames {
    /// "⌃⌥C", "⌥⌘F5", "⌃⌥Ş" …
    static func title(for keys: KeyCombination) -> String {
        keys.modifiers.symbols + name(forKeyCode: keys.keyCode)
    }

    static func name(forKeyCode keyCode: UInt16) -> String {
        guard KeyCodeNames.dependsOnLayout(keyCode), let character = layoutCharacter(forKeyCode: keyCode) else {
            return KeyCodeNames.name(forKeyCode: keyCode)
        }
        return character.uppercased(with: .current)
    }

    /// The character the key types without modifiers in the current ASCII-capable layout; `nil` when
    /// it types nothing printable (or the layout has no Unicode key layout data).
    private static func layoutCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }) else {
                return nil
            }
            return text
        }
    }
}
