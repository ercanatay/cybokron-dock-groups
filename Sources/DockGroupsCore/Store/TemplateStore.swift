import Combine
import Foundation
import OSLog

/// What saving a group as a template did (`TemplateStore.save`).
public enum TemplateSaveResult: Equatable, Sendable {
    /// The template is saved (or replaced the one of the same name).
    case saved(GroupTemplate)
    /// A template has that name already (ignoring case and surrounding spaces); nothing changed.
    /// Saving again with `replacing` replaces it.
    case nameTaken(GroupTemplate)
    /// `GroupTemplate.maximumCount` templates are kept already; nothing changed.
    case limitReached
}

/// The user's templates (spec I-3), kept in their own file, `templates.json`.
///
/// Like `GroupStore`: every change is written shortly after it happens; a file that can't be read is
/// moved aside (`templates.unreadable-<timestamp>.json`) and the store starts empty, saying so in
/// `issue`; when it can't be moved aside either, saving is suspended so the file isn't overwritten.
/// Names are unique (as groups' names are compared: trimmed, ignoring case), and at most
/// `GroupTemplate.maximumCount` templates are kept.
@MainActor
public final class TemplateStore: ObservableObject {
    @Published public private(set) var templates: [GroupTemplate] = []
    /// The most recent problem to show the user; cleared with `dismissIssue()`.
    @Published public private(set) var issue: GroupStoreIssue?
    /// `true` when the saved file couldn't be read *and* couldn't be moved aside.
    public private(set) var isSavingSuspended = false

    private let persistence: TemplatePersisting
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "TemplateStore")

    /// - Parameter saveDelay: How long to wait for further changes before writing. `.zero` writes
    ///   synchronously after every change.
    public init(persistence: TemplatePersisting, saveDelay: Duration = .milliseconds(250)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        loadFromDisk()
    }

    public func template(withID id: UUID) -> GroupTemplate? {
        templates.first { $0.id == id }
    }

    /// The template with this name, as groups' names are compared.
    public func template(named name: String) -> GroupTemplate? {
        let key = GroupNaming.comparisonKey(name)
        return templates.first { GroupNaming.comparisonKey($0.name) == key }
    }

    /// A free name for a template of `group`: its name, or "name 2", "name 3" …
    public func suggestedName(for group: DockGroup) -> String {
        GroupNaming.uniqueName(group.name, taken: templates.map(\.name))
    }

    public func dismissIssue() {
        issue = nil
    }

    // MARK: - Changes

    /// Saves a template of `group` named `name` (blank or `nil`: the group's name), at the end of
    /// the list. When a template has that name, it's replaced in place — same identifier, the new
    /// contents and date — only with `replacing`; otherwise nothing changes (`.nameTaken`).
    @discardableResult
    public func save(_ group: DockGroup, named name: String? = nil, replacing: Bool = false, at date: Date = Date()) -> TemplateSaveResult {
        let templateName = name.flatMap(DockGroup.sanitizedName) ?? DockGroup.sanitizedName(group.name) ?? DockGroup.defaultName
        if let existing = template(named: templateName) {
            guard replacing, let index = templates.firstIndex(where: { $0.id == existing.id }) else { return .nameTaken(existing) }
            let replacement = GroupTemplate(saving: group, named: templateName, id: existing.id, at: date)
            templates[index] = replacement
            scheduleSave()
            return .saved(replacement)
        }
        guard templates.count < GroupTemplate.maximumCount else { return .limitReached }
        let template = GroupTemplate(saving: group, named: templateName, at: date)
        templates.append(template)
        scheduleSave()
        return .saved(template)
    }

    /// Renames a template. Returns `false` (and changes nothing) for a blank name, a name another
    /// template has, or an unknown template.
    @discardableResult
    public func rename(_ id: UUID, to newName: String) -> Bool {
        guard let name = DockGroup.sanitizedName(newName), let index = templates.firstIndex(where: { $0.id == id }) else { return false }
        if let other = template(named: name), other.id != id { return false }
        guard templates[index].name != name else { return true }
        templates[index] = templates[index].renamed(name)
        scheduleSave()
        return true
    }

    /// Deletes a template. Groups made from it aren't affected.
    public func delete(_ id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates.remove(at: index)
        scheduleSave()
    }

    // MARK: - Restoring

    /// Replaces every template, as restoring a backup that has templates does. The current file is
    /// first copied next to itself (`templates.pre-import-<timestamp>.json`) and the new list is
    /// written before it's shown, so if anything fails nothing changes. Identifiers and names are
    /// kept once each, at most `GroupTemplate.maximumCount` templates.
    /// - Returns: The copy of the previous file, or `nil` when nothing had been saved.
    @discardableResult
    public func replaceTemplates(with newTemplates: [GroupTemplate]) throws -> URL? {
        try replaceTemplates(with: newTemplates, copyLabel: "pre-import")
    }

    @discardableResult
    func replaceTemplates(with newTemplates: [GroupTemplate], copyLabel: String?) throws -> URL? {
        if !isSavingSuspended {
            flushPendingSave()
        }
        let copyURL = try copyLabel.flatMap { try persistence.preserveCopy(label: $0) }
        let sanitized = GroupTemplate.sanitized(newTemplates)
        try persistence.saveTemplates(sanitized)
        templates = sanitized
        isSavingSuspended = false
        issue = nil
        return copyURL
    }

    /// Adds the templates of `incoming` that aren't here yet, as merging a backup does: a template
    /// is skipped when one here has its identifier or name, and the list keeps at most
    /// `GroupTemplate.maximumCount`. When something is added, the current file is copied first.
    /// - Returns: The templates added.
    @discardableResult
    public func mergeTemplates(_ incoming: [GroupTemplate]) throws -> [GroupTemplate] {
        let added = Self.templatesAddedByMerging(incoming, into: templates)
        guard !added.isEmpty else { return [] }
        try replaceTemplates(with: templates + added, copyLabel: "pre-import")
        return added
    }

    /// The templates of `incoming` that merging adds to `current`: see `mergeTemplates(_:)`.
    public nonisolated static func templatesAddedByMerging(_ incoming: [GroupTemplate], into current: [GroupTemplate]) -> [GroupTemplate] {
        let room = max(GroupTemplate.maximumCount - current.count, 0)
        let merged = GroupTemplate.sanitized(current + incoming)
        let currentIDs = Set(current.map(\.id))
        return Array(merged.filter { !currentIDs.contains($0.id) }.prefix(room))
    }

    // MARK: - Persistence

    /// Writes a pending change right away. Call before the app quits.
    public func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        writeToDisk()
    }

    private func loadFromDisk() {
        do {
            templates = GroupTemplate.sanitized(try persistence.loadTemplates())
        } catch let loadError {
            logger.error("Loading templates failed: \(String(describing: loadError), privacy: .public)")
            templates = []
            do {
                let backupURL = try persistence.preserveUnreadableData()
                let reason = loadError.localizedDescription
                issue = GroupStoreIssue(
                    title: Localization.string("core.templates.loadFailed.title", "Your templates couldn't be loaded"),
                    message: backupURL.map { backup in
                        let path = backup.path
                        return Localization.format("core.templates.loadFailed.kept", "%1$@ Starting without templates. A copy was kept at “%2$@”.", reason, path)
                    } ?? Localization.format("core.templates.loadFailed.empty", "%@ Starting without templates.", reason)
                )
            } catch let moveError {
                logger.error("Preserving unreadable templates failed: \(String(describing: moveError), privacy: .public)")
                isSavingSuspended = true
                let reason = loadError.localizedDescription
                issue = GroupStoreIssue(
                    title: Localization.string("core.templates.loadFailed.title", "Your templates couldn't be loaded"),
                    message: Localization.format(
                        "core.templates.loadFailed.suspended",
                        "%@ To protect the existing file, changes to templates won't be saved until the app is restarted.",
                        reason
                    )
                )
            }
        }
    }

    private func scheduleSave() {
        guard !isSavingSuspended else { return }
        pendingSave?.cancel()
        guard saveDelay > .zero else {
            writeToDisk()
            return
        }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    private func writeToDisk() {
        pendingSave = nil
        do {
            try persistence.saveTemplates(templates)
        } catch {
            logger.error("Saving templates failed: \(String(describing: error), privacy: .public)")
            if issue == nil {
                issue = GroupStoreIssue(
                    title: Localization.string("core.templates.saveFailed.title", "Your templates couldn't be saved"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
