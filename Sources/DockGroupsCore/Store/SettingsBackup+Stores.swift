import Foundation

/// What merging a backup into the stores did (`SettingsBackup.merge(into:templates:triggers:)`).
public struct SettingsMergeResult: Equatable, Sendable {
    public let groups: GroupMergeResult
    /// The templates added, after the current ones.
    public let addedTemplates: [GroupTemplate]
    /// The triggers added — of the groups the merge added — all turned off.
    public let addedTriggers: [GroupTrigger]

    init(groups: GroupMergeResult, addedTemplates: [GroupTemplate], addedTriggers: [GroupTrigger] = []) {
        self.groups = groups
        self.addedTemplates = addedTemplates
        self.addedTriggers = addedTriggers
    }
}

@MainActor
extension SettingsBackup {
    /// A backup of what the stores hold right now — archived groups and, when given, templates and
    /// triggers included — with changes not written to disk yet.
    public init(
        groups: GroupStore,
        preferences: PreferencesStore,
        templates: TemplateStore? = nil,
        triggers: TriggerStore? = nil,
        appVersion: String,
        exportedAt: Date = Date()
    ) {
        self.init(
            appVersion: appVersion,
            exportedAt: exportedAt,
            groups: groups.groups,
            archivedGroups: groups.archivedGroups,
            templates: templates?.templates ?? [],
            triggers: triggers?.triggers ?? [],
            preferences: preferences.preferences
        )
    }

    /// Replaces the stores' groups — active and archived — and preferences with the backup's, the
    /// templates when the backup has some (a backup without templates leaves them as they are), and
    /// the triggers when it has some, all turned off; without triggers in the backup, the current
    /// triggers of groups that are still there stay and the others go. Each store's current file is
    /// copied next to it first (`*.pre-import-<timestamp>.json`). All are restored or none is: when
    /// the groups, the templates or the triggers can't be written, what was replaced before is put
    /// back.
    /// - Returns: The copies of the previous files.
    @discardableResult
    public func restore(to groups: GroupStore, preferences: PreferencesStore, templates: TemplateStore? = nil, triggers: TriggerStore? = nil) throws -> [URL] {
        let previousPreferences = preferences.preferences
        let previousGroups = StoredGroups(active: groups.groups, archived: groups.archivedGroups)
        let previousTemplates = templates?.templates
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
        var replacedTemplates = false
        if let templates, !self.templates.isEmpty {
            do {
                if let copy = try templates.replaceTemplates(with: self.templates) {
                    copies.append(copy)
                }
                replacedTemplates = true
            } catch {
                _ = try? groups.replaceGroups(with: previousGroups, copyLabel: nil)
                _ = try? preferences.replacePreferences(with: previousPreferences, copyLabel: nil)
                throw error
            }
        }
        guard let triggers else { return copies }
        guard !self.triggers.isEmpty else {
            triggers.pruneTriggers(for: groups)
            return copies
        }
        do {
            if let copy = try triggers.replaceTriggers(with: self.triggers.map(\.turnedOff)) {
                copies.append(copy)
            }
        } catch {
            if replacedTemplates, let templates, let previousTemplates {
                _ = try? templates.replaceTemplates(with: previousTemplates, copyLabel: nil)
            }
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
    /// added after the current ones (`TemplateStore.mergeTemplates`), and, with `triggers`, the
    /// backup's triggers of the groups the merge added, turned off. Merging only adds: when the
    /// templates or triggers can't be written, the groups merged stay.
    @discardableResult
    public func merge(into groups: GroupStore, templates: TemplateStore, triggers: TriggerStore? = nil) throws -> SettingsMergeResult {
        let merged = try merge(into: groups)
        let added = try templates.mergeTemplates(self.templates)
        guard let triggers else { return SettingsMergeResult(groups: merged, addedTemplates: added) }
        let addedGroupIDs = Set(merged.addedGroups.map(\.id) + merged.addedArchivedGroups.map(\.id))
        let incoming = self.triggers.filter { addedGroupIDs.contains($0.groupID) }.map(\.turnedOff)
        let addedTriggers = try triggers.mergeTriggers(incoming)
        return SettingsMergeResult(groups: merged, addedTemplates: added, addedTriggers: addedTriggers)
    }
}

extension GroupTrigger {
    /// The trigger turned off, as a backup's triggers come in (spec §4.2 T-S4).
    var turnedOff: GroupTrigger {
        var trigger = self
        trigger.isEnabled = false
        return trigger
    }
}
