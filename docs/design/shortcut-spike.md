# Spike: group shortcuts and the system (PR 4 of `group-shortcuts-and-templates-spec.md`)

- **Date:** 2026-10-25, on this Mac: macOS 27.0.1 (26A434), Turkish-QWERTY-PC keyboard layout,
  Xcode SDK headers (`HIToolbox/CarbonEvents.h`).
- **Method:** small Swift programs (not committed) calling Carbon, Text Input Sources and
  `CGEvent`: one listing `CopySymbolicHotKeys`, one registering hot keys, one AppKit app that
  registered hot keys, installed a local key monitor (as the recorder does) and posted key events
  at the HID event tap (`CGEventPost`, allowed because the shell's host app has Accessibility
  access), and one translating key codes with `UCKeyTranslate` in eight layouts.
- **Outcome:** nothing blocks PR 4. Spec §7 R1 and R7 are answered below; what needs a real
  keyboard is in the manual list at the end.

## 1. `CopySymbolicHotKeys` (rule K4)

- Returns 233 entries here; status `noErr`.
- **The modifiers are Carbon's modifier bits**, not `NSEvent` flags: `cmdKey` 0x100, `shiftKey`
  0x200, `optionKey` 0x800, `controlKey` 0x1000. Examples: key 53 with 0x900 is ⌥⌘⎋ (Force Quit),
  48 with 0x100 is ⌘⇥, 49 with 0x1100 is ⌃⌘Space (Character Viewer), 49 with 0x1800 is ⌃⌥Space
  (next input source), 2 with 0x900 is ⌥⌘D (Dock), 20 with 0x1300 is ⌃⇧⌘3.
  (`defaults read com.apple.symbolichotkeys` stores `NSEvent` flags instead — 262144 for ⌃ — so the
  plist isn't what to read.) `KeyModifiers(carbonBits:)` reads them as they are.
- Function keys and arrows carry the fn bit as well (`kEventKeyModifierFnMask`, 0x20000; e.g. 120
  with 0x21000 is ⌃F2). Hot keys match those keys without it (§3), so the bit is ignored.
- Some entries have key codes above 127 (129, 130, 144, 145: keys of the top row) or are turned
  off (`kHISymbolicHotKeyEnabled` false); both are skipped. `SystemShortcutList.combinations`
  does this and is tested with these entries.

## 2. Registering hot keys on keys macOS uses (R1)

- `RegisterEventHotKey` **succeeds** for combinations macOS's symbolic hotkeys use (⌥⌘D, ⌃⌘D,
  ⌃⇧⌘3, ⌥⌘`), without `kEventHotKeyExclusive`. A conflict therefore never shows up as a failed
  registration: rules K3 and K4 have to refuse those keys, as the spec does.
- Pressing ⌥⌘` with it registered: **the app's hot key fired** and the key press didn't reach the
  app's local monitor. Whether macOS's own action ran too couldn't be seen (that one has no visible
  effect); either way the user would get something unexpected — hence refusing them.
- Registering the same keys twice in the process fails with `eventHotKeyExistsErr` (-9878), as the
  registrar and its fake assume; unregistering and registering again works.

## 3. Hot keys, the recorder and key presses (R7)

Posted at the HID event tap, with the test app in front and a local `keyDown` monitor installed:

| Situation | Hot key handler | Local monitor (the recorder) |
| --- | --- | --- |
| ⌃⌥⇧K registered, pressed | fired once | nothing |
| ⌃⌥⇧K registered, held (a press and two key repeats) | **fired once** | nothing |
| ⌃⌥⇧K unregistered (the recorder's `suspend`), pressed | nothing | received it |
| ⌃⌥⇧K registered again (`resume`), pressed | fired once | nothing |
| ⌃⌥⇧F6 / F19 / ← registered without fn, pressed with fn (as keyboards send them) | fired | nothing |
| ⌃⌥ keypad 3 registered, pressed with the keypad flag | fired | nothing |
| ⌃⌥⇧K registered, pressed with Caps Lock on | fired | nothing |

- **A registered hot key takes the key press even from its own app in front**, so a recorder
  can't see keys that are a shortcut already unless every hot key is let go first — which is what
  `GroupHotKeyRegistrar.suspend()` does, and `resume()` brings back.
- **Hot keys don't repeat**: holding the keys gives one press. The registrar's 0.4 s debounce stays
  as a guard against bouncing keys; the 3-second rule covers a double Start.
- Function keys, arrows, Home/End/Page Up/Page Down and keypad keys need no extra modifier bits:
  registered with ⌃⌥… alone, they match the key presses keyboards send (which carry fn or keypad
  flags). Caps Lock doesn't get in the way.

## 4. Key names in other keyboard layouts

`UCKeyTranslate` (`kUCKeyActionDisplay`, no modifiers, dead keys off) per layout:

| Layout | A | C | I | Q | Y | Z | ; key | 3 | § key | F5 | ← | keypad 3 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| U.S. | a | c | i | q | y | z | ; | 3 | § | U+0010 | U+001C | 3 |
| Turkish-QWERTY-PC (current) | a | c | ı | q | y | z | ş | 3 | " | U+0010 | U+001C | 3 |
| Turkish (F) | u | v | n | f | d | j | y | 3 | § | U+0010 | U+001C | 3 |
| Dvorak | a | j | c | ' | f | ; | s | 3 | § | U+0010 | U+001C | 3 |
| German | a | c | i | q | z | y | ö | 3 | ^ | U+0010 | U+001C | 3 |
| French | q | c | i | a | y | w | m | " | @ | U+0010 | U+001C | 3 |
| Russian | ф | с | ш | й | н | я | ж | 3 | > | U+0010 | U+001C | 3 |

Decisions for `KeyNames` (app) and `KeyCodeNames` (core):

- Letters and punctuation are named with the **current ASCII-capable layout**
  (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`), as macOS names menu shortcuts — so a
  Russian layout shows Latin letters — and uppercased in the user's language ("ı" → "I").
- Digits keep their digit (French would say `"` for the 3 key; the number shortcuts are digits
  too), and keys that print nothing keep their symbols: `UCKeyTranslate` gives control characters
  for them (F5 → U+0010, ← → U+001C).
- The shortcut stays on the physical key (the virtual key code), as the number shortcuts do; its
  name follows the layout in use.

## 5. Not used

- `PushSymbolicHotKeyMode` (turning macOS's shortcuts off while recording): its header says it only
  works with assistive access enabled, which I6 set out to avoid. macOS's shortcuts therefore keep
  working while recording, and the recorder never sees them — they're refused anyway (K3, K4).

## Manual checks left for a real keyboard (PR 4 description)

1. A group shortcut in Safari, Terminal (with Secure Keyboard Entry on and off), a full-screen app
   and with a password field focused (Secure Event Input).
2. Holding the shortcut's keys: one action.
3. Recording: Escape, Delete, a click elsewhere, closing the window, switching apps — the number
   shortcuts and the other group shortcuts work again after each.
4. Turning on a macOS shortcut in System Settings → Keyboard → Keyboard Shortcuts with the same keys
   as a group shortcut, then opening the group window: the shortcut shows as off.
5. Dvorak and Turkish-Q layouts: the field and Settings show the layout's letter.
6. Start from a shortcut with "Quit the previous group's apps": the question shows (Hide Instead,
   Cancel); with hiding settings it doesn't.
