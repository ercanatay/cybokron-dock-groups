import Foundation

@MainActor
extension SettingsBackup {
    /// A backup of what the stores hold right now, archived groups included, with changes not
    /// written to disk yet.
    public init(groups: GroupStore, preferences: PreferencesStore, appVersion: String, exportedAt: Date = Date()) {
        self.init(
            appVersion: appVersion,
            exportedAt: exportedAt,
            groups: groups.groups,
            archivedGroups: groups.archivedGroups,
            preferences: preferences.preferences
        )
    }

    /// Replaces the stores' groups — active and archived — and preferences with the backup's. Each
    /// store's current file is copied next to it first (`*.pre-import-<timestamp>.json`). Both are
    /// restored or neither is: when the groups can't be written, the previous preferences are put
    /// back.
    /// - Returns: The copies of the previous files.
    @discardableResult
    public func restore(to groups: GroupStore, preferences: PreferencesStore) throws -> [URL] {
        let previousPreferences = preferences.preferences
        var copies: [URL] = []
        if let copy = try preferences.replacePreferences(with: self.preferences) {
            copies.append(copy)
        }
        do {
            if let copy = try groups.replaceGroups(with: StoredGroups(active: self.groups, archived: archivedGroups)) {
                copies.append(copy)
            }
        } catch {
            _ = try? preferences.replacePreferences(with: previousPreferences, copyLabel: nil)
            throw error
        }
        return copies
    }

    /// Adds the backup's groups, active and archived, that the store doesn't have yet (by name or
    /// identifier) after the current ones; current groups and all preferences stay as they are. An
    /// added group whose shortcut a current group has comes in without it. The groups file is
    /// copied next to itself first (`groups.pre-import-<timestamp>.json`) when anything is added.
    @discardableResult
    public func merge(into groups: GroupStore) throws -> GroupMergeResult {
        try groups.mergeGroups(self.groups, archived: archivedGroups)
    }
}
