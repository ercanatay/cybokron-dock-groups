import Carbon.HIToolbox
import Foundation

/// Shortcuts of macOS itself that a group shortcut never takes (rule K3), whether or not System
/// Settings lists them as turned on (that list is rule K4, read by the app). From Apple's "Mac
/// keyboard shortcuts" (support.apple.com/102650, checked 2026-10-25), the system-wide ones that
/// pass rules K1 and K2 — those with Escape or Space (Force Quit ⌥⌘⎋, the Character Viewer ⌃⌘Space,
/// Finder search ⌥⌘Space, the next input source ⌃⌥Space) are already refused by K2, and those with
/// one modifier (⌘⇧3, ⌃↑…) by K1.
public enum ReservedShortcuts {
    /// Each reserved combination and what macOS does with it.
    public static let named: [(keys: KeyCombination, name: String)] = [
        (combination(kVK_ANSI_Q, [.control, .command]), "Lock Screen"),
        (combination(kVK_ANSI_Q, [.option, .shift, .command]), "Log Out without asking"),
        (combination(kVK_ANSI_F, [.control, .command]), "Full Screen"),
        (combination(kVK_ANSI_D, [.option, .command]), "Show or hide the Dock"),
        (combination(kVK_ANSI_H, [.option, .command]), "Hide Others"),
        (combination(kVK_ANSI_M, [.option, .command]), "Minimize All"),
        (combination(kVK_ANSI_W, [.option, .command]), "Close All"),
        (combination(kVK_ANSI_D, [.control, .command]), "Look Up"),
        (combination(kVK_ANSI_3, [.control, .shift, .command]), "Copy a screenshot of the screen"),
        (combination(kVK_ANSI_4, [.control, .shift, .command]), "Copy a screenshot of an area"),
        (combination(kVK_ANSI_8, [.option, .command]), "Zoom on or off"),
        (combination(kVK_ANSI_Equal, [.option, .command]), "Zoom in"),
        (combination(kVK_ANSI_Minus, [.option, .command]), "Zoom out"),
        (combination(kVK_ANSI_8, [.control, .option, .command]), "Invert Colors"),
        (combination(kVK_ANSI_Comma, [.control, .option, .command]), "Reduce Contrast"),
        (combination(kVK_ANSI_Period, [.control, .option, .command]), "Increase Contrast"),
        (combination(kVK_F5, [.option, .command]), "Accessibility Shortcuts"),
        (combination(kVK_ANSI_Grave, [.option, .command]), "Move focus to the window drawer"),
    ]

    /// The reserved combinations.
    public static let builtIn: Set<KeyCombination> = Set(named.map(\.keys))

    private static func combination(_ keyCode: Int, _ modifiers: KeyModifiers) -> KeyCombination {
        KeyCombination(keyCode: UInt16(keyCode), modifiers: modifiers)
    }
}
