import Foundation

/// What merging a backup into the stores did (`SettingsBackup.merge(into:templates:)`).
public struct SettingsMergeResult: Equatable, Sendable {
    public let groups: GroupMergeResult
    /// The templates added, after the current ones.
    public let addedTemplates: [GroupTemplate]
}

@MainActor
extension SettingsBackup {
    /// A backup of what the stores hold right now — archived groups and, when given, templates
    /// included — with changes not written to disk yet.
    public init(groups: GroupStore, preferences: PreferencesStore, templates: TemplateStore? = nil, appVersion: String, exportedAt: Date = Date()) {
        self.init(
            appVersion: appVersion,
            exportedAt: exportedAt,
            groups: groups.groups,
            archivedGroups: groups.archivedGroups,
            templates: templates?.templates ?? [],
            preferences: preferences.preferences
        )
    }

    /// Replaces the stores' groups — active and archived — and preferences with the backup's, and
    /// the templates when the backup has some (a backup without templates leaves them as they are).
    /// Each store's current file is copied next to it first (`*.pre-import-<timestamp>.json`). All
    /// are restored or none is: when the groups or the templates can't be written, what was
    /// replaced before is put back.
    /// - Returns: The copies of the previous files.
    @discardableResult
    public func restore(to groups: GroupStore, preferences: PreferencesStore, templates: TemplateStore? = nil) throws -> [URL] {
        let previousPreferences = preferences.preferences
        let previousGroups = StoredGroups(active: groups.groups, archived: groups.archivedGroups)
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
        guard let templates, !self.templates.isEmpty else { return copies }
        do {
            if let copy = try templates.replaceTemplates(with: self.templates) {
                copies.append(copy)
            }
        } catch {
            _ = try? groups.replaceGroups(with: previousGroups, copyLabel: nil)
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

    /// `merge(into:)`, then the backup's templates that aren't here yet (by name or identifier) are
    /// added after the current ones (`TemplateStore.mergeTemplates`). Merging only adds: when the
    /// templates can't be written, the groups merged stay.
    @discardableResult
    public func merge(into groups: GroupStore, templates: TemplateStore) throws -> SettingsMergeResult {
        let merged = try merge(into: groups)
        let added = try templates.mergeTemplates(self.templates)
        return SettingsMergeResult(groups: merged, addedTemplates: added)
    }
}
