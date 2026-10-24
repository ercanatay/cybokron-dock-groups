import Foundation

/// Going back, from "Other Versions…", to a version older than `ReleaseHistory.firstGroupItemsVersion`.
///
/// Such a version reads the groups file as it is (its format version is unchanged): files and
/// folders show there as missing apps that open nothing, and the alias, tags and task notes of
/// items are ignored — but as soon as it saves the groups (any edit), it writes them without
/// their kind and details. So before it's installed, the groups file is copied next to itself as
/// `groups.pre-downgrade-<timestamp>.json` (the last three copies are kept), and when the groups
/// hold anything that version can't show, the install question says so first.
///
/// Going back to a version older than `ReleaseHistory.firstContextSwitchingVersion` is protected
/// the same way for what it ignores and then drops: the groups' Start and Finish settings and
/// launch options, and the protected apps in `preferences.json`. Both files are copied
/// (`preferences.pre-downgrade-<timestamp>.json` too), and the question warns when any of them is used.
///
/// Going back to a version older than `ReleaseHistory.firstGroupShortcutsVersion` is protected
/// likewise for what it ignores and then drops: group shortcuts and which groups are archived (it
/// shows them as ordinary groups). The same two files are copied, and the question warns when a
/// group has a shortcut, a group is archived or a template exists (templates stay in
/// `templates.json`, which that version never opens, so that file needs no copy).
///
/// `UpdateInstaller` replaces the app only and never reads the settings; this happens around it.
public enum DowngradeProtection {
    /// The label of the copies: `groups.pre-downgrade-<timestamp>.json`.
    public static let copyLabel = "pre-downgrade"

    /// Whether installing `target` while `current` runs goes back to a version without group items
    /// (`current` is `nil` when the running app has no version, as in development).
    public static func applies(installing target: SemanticVersion, over current: SemanticVersion?) -> Bool {
        guard ReleaseHistory.lacksGroupItems(target) else { return false }
        return current.map { target < $0 } ?? true
    }

    /// Whether `groups` hold what a version without group items can't show: a file or folder, or
    /// an item with an alias, tags or task notes.
    public static func usesGroupItems(_ groups: [DockGroup]) -> Bool {
        groups.contains { group in
            group.apps.contains { $0.kind.isFileSystemItem || !$0.details.isEmpty }
        }
    }

    /// Whether the install question warns that `target` can't show some of `groups`' items.
    public static func warns(installing target: SemanticVersion, over current: SemanticVersion?, groups: [DockGroup]) -> Bool {
        applies(installing: target, over: current) && usesGroupItems(groups)
    }

    /// Whether installing `target` while `current` runs goes back to a version without Start and
    /// Finish, launch options and protected apps.
    public static func appliesToContextSwitching(installing target: SemanticVersion, over current: SemanticVersion?) -> Bool {
        guard ReleaseHistory.lacksContextSwitching(target) else { return false }
        return current.map { target < $0 } ?? true
    }

    /// Whether installing `target` while `current` runs goes back to a version without group
    /// shortcuts, archived groups and templates.
    public static func appliesToGroupShortcuts(installing target: SemanticVersion, over current: SemanticVersion?) -> Bool {
        guard ReleaseHistory.lacksGroupShortcuts(target) else { return false }
        return current.map { target < $0 } ?? true
    }

    /// Whether an active group has a shortcut, any group is archived, or a template exists.
    public static func usesGroupLibrary(_ groups: [DockGroup], archivedCount: Int, templateCount: Int) -> Bool {
        archivedCount > 0 || templateCount > 0 || groups.contains { $0.shortcut != nil }
    }

    /// Whether the install question warns that `target` ignores (and, on a save, drops) group
    /// shortcuts and the archive.
    public static func warnsAboutGroupLibrary(
        installing target: SemanticVersion,
        over current: SemanticVersion?,
        groups: [DockGroup],
        archivedCount: Int,
        templateCount: Int
    ) -> Bool {
        appliesToGroupShortcuts(installing: target, over: current)
            && usesGroupLibrary(groups, archivedCount: archivedCount, templateCount: templateCount)
    }

    /// Whether the groups or preferences use what a version without Start and Finish drops: an
    /// item with a delay or opener, a group with Start or Finish settings other than the default,
    /// or protected apps.
    public static func usesContextSwitching(_ groups: [DockGroup], preferences: PopupPreferences) -> Bool {
        !preferences.protectedApps.isEmpty || groups.contains { group in
            !group.switching.isDefault || group.apps.contains { !$0.launch.isEmpty }
        }
    }

    /// Whether the install question warns that `target` ignores (and, on a save, drops) Start and
    /// Finish settings, launch options or protected apps.
    public static func warnsAboutContextSwitching(
        installing target: SemanticVersion,
        over current: SemanticVersion?,
        groups: [DockGroup],
        preferences: PopupPreferences
    ) -> Bool {
        appliesToContextSwitching(installing: target, over: current) && usesContextSwitching(groups, preferences: preferences)
    }

    /// Copies the groups file and the preferences file aside before `target` is installed over
    /// `current`, when that goes back to a version without group shortcuts or without Start and Finish
    /// (which also covers going back to one without group items). Either copy failing throws, and nothing is installed.
    /// - Returns: The copies' locations; none for a file that hasn't been saved yet.
    @MainActor
    @discardableResult
    public static func preserveCopies(
        of store: GroupStore,
        and preferences: PreferencesStore,
        installing target: SemanticVersion,
        over current: SemanticVersion?
    ) throws -> [URL] {
        guard appliesToContextSwitching(installing: target, over: current)
            || appliesToGroupShortcuts(installing: target, over: current) else { return [] }
        return try [store.preserveCopy(label: copyLabel), preferences.preserveCopy(label: copyLabel)].compactMap { $0 }
    }

    /// Copies the groups file aside before `target` is installed over `current`, when that goes back
    /// to a version without group items — whatever the groups hold, as that version may save them.
    /// - Returns: The copy's location; `nil` when no copy is needed or nothing has been saved yet.
    @MainActor
    @discardableResult
    public static func preserveGroups(of store: GroupStore, installing target: SemanticVersion, over current: SemanticVersion?) throws -> URL? {
        guard applies(installing: target, over: current) else { return nil }
        return try store.preserveCopy(label: copyLabel)
    }
}
