import Carbon.HIToolbox
import DockGroupsCore

/// Lists macOS's own keyboard shortcuts that are turned on, for rule K4 (spec §2.6).
@MainActor
protocol SystemShortcutListing {
    func enabledCombinations() -> Set<KeyCombination>
}

/// macOS's shortcuts from Carbon's `CopySymbolicHotKeys`: the ones in System Settings → Keyboard →
/// Keyboard Shortcuts. The list can't tell which shortcut an entry is, and reading it costs a
/// little per shortcut, so it's read at launch, when a recording starts and when the group window
/// or the Shortcuts pane shows — never per key press. `PushSymbolicHotKeyMode`, which could turn
/// these off while recording, isn't used: it needs assistive access.
struct SystemShortcuts: SystemShortcutListing {
    func enabledCombinations() -> Set<KeyCombination> {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let entries = array.map { entry in
            SystemShortcutList.Entry(
                keyCode: entry[kHISymbolicHotKeyCode as String] as? Int ?? -1,
                carbonModifiers: entry[kHISymbolicHotKeyModifiers as String] as? Int ?? 0,
                isEnabled: entry[kHISymbolicHotKeyEnabled as String] as? Bool ?? false
            )
        }
        return SystemShortcutList.combinations(from: entries)
    }
}
