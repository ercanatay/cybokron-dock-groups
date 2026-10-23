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
