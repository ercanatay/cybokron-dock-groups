import Combine
import Foundation
import OSLog

/// A problem the user should know about, such as a failed save.
public struct GroupStoreIssue: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// What merging a backup's groups into the current ones did.
public struct GroupMergeResult: Equatable, Sendable {
    /// The groups that were added, after the current ones, in the backup's order.
    public let addedGroups: [DockGroup]
    /// The copy of the previous groups file, `nil` when nothing was added or nothing had been saved.
    public let copyURL: URL?
}

/// The single source of truth for the user's groups.
///
/// Every change is written to disk shortly after it happens (changes arriving in quick succession,
/// such as dragging a color picker, are coalesced into one write). An empty store stays empty:
/// no sample groups are ever created.
@MainActor
public final class GroupStore: ObservableObject {
    @Published public private(set) var groups: [DockGroup] = []
    /// The most recent problem to show the user; cleared with `dismissIssue()`.
    @Published public private(set) var issue: GroupStoreIssue?
    /// `true` when the saved file couldn't be read *and* couldn't be moved aside. Saving is then
    /// disabled, because writing would destroy the user's existing data.
    public private(set) var isSavingSuspended = false

    private let persistence: GroupPersisting
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupStore")

    /// - Parameter saveDelay: How long to wait for further changes before writing. `.zero` writes
    ///   synchronously after every change.
    public init(persistence: GroupPersisting, saveDelay: Duration = .milliseconds(250)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        loadFromDisk()
    }

    public func group(withID id: DockGroup.ID) -> DockGroup? {
        groups.first { $0.id == id }
    }

    public func dismissIssue() {
        issue = nil
    }

    // MARK: - Groups

    /// Appends a new, empty group. Without a usable name it gets a unique default ("New Group 2" …).
    @discardableResult
    public func addGroup(named name: String? = nil, emoji: String = DockGroup.defaultEmoji) -> DockGroup {
        let group = DockGroup(
            name: name.flatMap(DockGroup.sanitizedName) ?? nextDefaultName(),
            emoji: DockGroup.sanitizedEmoji(emoji) ?? DockGroup.defaultEmoji
        )
        groups.append(group)
        scheduleSave()
        return group
    }

    /// Renames a group. Returns `false` (and changes nothing) for a blank name or an unknown group.
    @discardableResult
    public func renameGroup(_ id: DockGroup.ID, to newName: String) -> Bool {
        guard let name = DockGroup.sanitizedName(newName), let index = index(of: id) else { return false }
        if groups[index].name != name {
            groups[index].name = name
            scheduleSave()
        }
        return true
    }

    /// Removes the group and its app list. The apps themselves aren't touched.
    public func deleteGroup(_ id: DockGroup.ID) {
        guard let index = index(of: id) else { return }
        groups.remove(at: index)
        scheduleSave()
    }

    public func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = groups.map(\.id)
        groups.moveElements(fromOffsets: source, toOffset: destination)
        if groups.map(\.id) != before {
            scheduleSave()
        }
    }

    /// Applies `change` to a group. Blank names or emoji are rejected (the previous value is kept)
    /// and duplicate apps are dropped, so the group's invariants always hold.
    public func updateGroup(_ id: DockGroup.ID, _ change: (inout DockGroup) -> Void) {
        guard let index = index(of: id) else { return }
        let original = groups[index]
        var edited = original
        change(&edited)
        edited.name = DockGroup.sanitizedName(edited.name) ?? original.name
        edited.emoji = DockGroup.sanitizedEmoji(edited.emoji) ?? original.emoji
        edited.apps = Self.removingDuplicates(edited.apps)
        edited.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(edited.freeLayoutSlots, apps: edited.apps)
        guard edited != original else { return }
        groups[index] = edited
        scheduleSave()
    }

    // MARK: - Apps

    /// Appends the apps that aren't in the group yet, in order. Returns how many were added.
    @discardableResult
    public func addApps(_ apps: [AppReference], toGroup id: DockGroup.ID) -> Int {
        guard let index = index(of: id) else { return 0 }
        let combined = Self.removingDuplicates(groups[index].apps + apps)
        let addedCount = combined.count - groups[index].apps.count
        guard addedCount > 0 else { return 0 }
        groups[index].apps = combined
        scheduleSave()
        return addedCount
    }

    public func removeApp(bundleIdentifier: String, fromGroup id: DockGroup.ID) {
        guard let index = index(of: id) else { return }
        let target = bundleIdentifier.lowercased()
        let remaining = groups[index].apps.filter { $0.normalizedBundleIdentifier != target }
        guard remaining.count != groups[index].apps.count else { return }
        var group = groups[index]
        group.apps = remaining
        // In Free Layout the other apps keep their cells.
        group.freeLayoutSlots[target] = nil
        groups[index] = group
        scheduleSave()
    }

    /// Moves an app to another group, as "Move to" and dropping it on a group in the sidebar do:
    /// it leaves `source` — and its Free Layout cell there, the other apps keep theirs — and joins
    /// the end of `destination`'s list. When `destination` already has the app, it only leaves
    /// `source`, so no group lists it twice. Both groups change in one step and one save.
    /// - Returns: Whether anything changed; `false` when the groups are the same, either is
    ///   unknown, or `source` doesn't have the app.
    @discardableResult
    public func moveApp(bundleIdentifier: String, fromGroup source: DockGroup.ID, toGroup destination: DockGroup.ID) -> Bool {
        guard source != destination,
              let sourceIndex = index(of: source),
              let destinationIndex = index(of: destination)
        else { return false }
        let target = bundleIdentifier.lowercased()
        var updated = groups
        guard let app = updated[sourceIndex].apps.first(where: { $0.normalizedBundleIdentifier == target }) else {
            return false
        }
        updated[sourceIndex].apps.removeAll { $0.normalizedBundleIdentifier == target }
        updated[sourceIndex].freeLayoutSlots[target] = nil
        if !updated[destinationIndex].apps.contains(where: { $0.normalizedBundleIdentifier == target }) {
            // Without a Free Layout cell of its own, it takes the first free cell there.
            updated[destinationIndex].apps.append(app)
        }
        groups = updated
        scheduleSave()
        return true
    }

    /// Moves one app so it ends up at `index` of the group's list (clamped to the list), as
    /// dropping it on that slot of the popup grid does.
    public func moveApp(bundleIdentifier: String, inGroup id: DockGroup.ID, to index: Int) {
        guard let groupIndex = self.index(of: id) else { return }
        let target = bundleIdentifier.lowercased()
        var apps = groups[groupIndex].apps
        guard let source = apps.firstIndex(where: { $0.normalizedBundleIdentifier == target }) else { return }
        let app = apps.remove(at: source)
        apps.insert(app, at: min(max(index, 0), apps.count))
        reorderApps(inGroupAt: groupIndex, to: apps)
    }

    public func moveApps(inGroup id: DockGroup.ID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let index = index(of: id) else { return }
        var apps = groups[index].apps
        apps.moveElements(fromOffsets: source, toOffset: destination)
        reorderApps(inGroupAt: index, to: apps)
    }

    /// Sorts the group's apps by name, A to Z, the way Finder sorts names (ignoring case, with
    /// numbers in numeric order). Apps with the same name keep their order.
    public func sortAppsByName(inGroup id: DockGroup.ID) {
        guard let index = index(of: id) else { return }
        reorderApps(inGroupAt: index, to: DockGroup.sortedByName(groups[index].apps))
    }

    /// Puts the group's apps in the given Free Layout cells (keyed by normalized bundle
    /// identifier, as `FreeLayout.slots` has them) and orders the app list the way the cells read,
    /// row by row, so the Dock tile, Open All and the group window follow the popup.
    public func arrangeApps(inGroup id: DockGroup.ID, freeLayoutSlots slots: [String: Int]) {
        guard let index = index(of: id) else { return }
        let arranged = groups[index].arranged(inFreeLayoutSlots: slots)
        guard arranged != groups[index] else { return }
        groups[index] = arranged
        scheduleSave()
    }

    /// Puts the group's apps in the order of `apps` (the same apps, reordered). Apps arranged in
    /// Free Layout refill the cells they occupy in the new order, so the arrangement keeps its
    /// shape.
    private func reorderApps(inGroupAt index: Int, to apps: [AppReference]) {
        guard apps != groups[index].apps else { return }
        var group = groups[index]
        group.apps = apps
        group.refillFreeLayoutSlots(previousApps: groups[index].apps)
        groups[index] = group
        scheduleSave()
    }

    // MARK: - Restoring

    /// Replaces the whole group list, as restoring a backup does: groups of the same name are
    /// replaced by the new ones and groups not in `newGroups` are removed. The current file is
    /// first copied next to itself (`groups.pre-import-<timestamp>.json`), and the new list is
    /// written before it's shown, so if anything fails nothing changes. The groups are cleaned up
    /// the way edits are: blank names and emoji get defaults, duplicate apps are dropped, and of
    /// groups sharing an identifier only the first is kept.
    /// - Returns: The copy of the previous file, or `nil` when nothing had been saved.
    @discardableResult
    public func replaceGroups(with newGroups: [DockGroup]) throws -> URL? {
        try replaceGroups(with: newGroups, copyLabel: "pre-import")
    }

    /// `replaceGroups(with:)`; without a `copyLabel` the current file isn't copied first.
    @discardableResult
    func replaceGroups(with newGroups: [DockGroup], copyLabel: String?) throws -> URL? {
        // The copy should hold what's on screen, not an older write.
        if !isSavingSuspended {
            flushPendingSave()
        }
        let copyURL = try copyLabel.flatMap { try persistence.preserveCopy(label: $0) }
        let sanitized = Self.sanitizedForRestore(newGroups)
        try persistence.saveGroups(sanitized)
        groups = sanitized
        // The unreadable file that suspended saving was just copied aside and replaced.
        isSavingSuspended = false
        issue = nil
        return copyURL
    }

    /// Adds the groups of `incoming` that aren't here yet after the current ones, as merging a
    /// backup does; every current group stays as it is. A group is skipped when a current group has
    /// the same name (ignoring case and surrounding spaces) or the same identifier — and so are
    /// later groups of `incoming` repeating one already added. The added groups are cleaned up the
    /// way `replaceGroups(with:)` cleans them. When something is added, the current file is first
    /// copied next to itself (`groups.pre-import-<timestamp>.json`) and the new list is written
    /// before it's shown, so if anything fails nothing changes.
    @discardableResult
    public func mergeGroups(_ incoming: [DockGroup]) throws -> GroupMergeResult {
        let added = Self.sanitizedForRestore(Self.groupsAddedByMerging(incoming, into: groups))
        guard !added.isEmpty else { return GroupMergeResult(addedGroups: [], copyURL: nil) }
        let copyURL = try replaceGroups(with: groups + added, copyLabel: "pre-import")
        return GroupMergeResult(addedGroups: added, copyURL: copyURL)
    }

    /// The groups of `incoming` that merging adds to `current`, unchanged and in order: see
    /// `mergeGroups(_:)`.
    public nonisolated static func groupsAddedByMerging(_ incoming: [DockGroup], into current: [DockGroup]) -> [DockGroup] {
        var names = Set(current.map(mergeName(of:)))
        var ids = Set(current.map(\.id))
        return incoming.filter { group in
            let name = mergeName(of: group)
            guard !ids.contains(group.id), !names.contains(name) else { return false }
            names.insert(name)
            ids.insert(group.id)
            return true
        }
    }

    /// The name groups are matched by: as the store keeps it (trimmed, a blank one replaced by the
    /// default), ignoring case.
    nonisolated static func mergeName(of group: DockGroup) -> String {
        (DockGroup.sanitizedName(group.name) ?? DockGroup.defaultName).lowercased()
    }

    private static func sanitizedForRestore(_ groups: [DockGroup]) -> [DockGroup] {
        var seenIDs = Set<DockGroup.ID>()
        return groups.compactMap { group in
            guard seenIDs.insert(group.id).inserted else { return nil }
            var sanitized = group
            sanitized.name = DockGroup.sanitizedName(group.name) ?? DockGroup.defaultName
            sanitized.emoji = DockGroup.sanitizedEmoji(group.emoji) ?? DockGroup.defaultEmoji
            sanitized.apps = removingDuplicates(group.apps)
            sanitized.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(group.freeLayoutSlots, apps: sanitized.apps)
            return sanitized
        }
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
            groups = try persistence.loadGroups()
        } catch let loadError {
            logger.error("Loading groups failed: \(String(describing: loadError), privacy: .public)")
            groups = []
            do {
                let backupURL = try persistence.preserveUnreadableData()
                let reason = loadError.localizedDescription
                issue = GroupStoreIssue(
                    title: Localization.string("core.store.loadFailed.title", "Your groups couldn't be loaded"),
                    message: backupURL.map { backup in
                        Localization.format(
                            "core.store.loadFailed.kept",
                            "%1$@ Starting with an empty group list. A copy was kept at “%2$@”.",
                            reason, backup.path
                        )
                    } ?? Localization.format("core.store.loadFailed.empty", "%@ Starting with an empty group list.", reason)
                )
            } catch let moveError {
                logger.error("Preserving unreadable groups failed: \(String(describing: moveError), privacy: .public)")
                isSavingSuspended = true
                issue = GroupStoreIssue(
                    title: Localization.string("core.store.loadFailed.title", "Your groups couldn't be loaded"),
                    message: Localization.format(
                        "core.store.loadFailed.suspended",
                        "%@ To protect the existing file, changes won't be saved until the app is restarted.",
                        loadError.localizedDescription
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
            try persistence.saveGroups(groups)
        } catch {
            logger.error("Saving groups failed: \(String(describing: error), privacy: .public)")
            if issue == nil {
                issue = GroupStoreIssue(
                    title: Localization.string("core.store.saveFailed.title", "Your changes couldn't be saved"),
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Helpers

    private func index(of id: DockGroup.ID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    private func nextDefaultName() -> String {
        let existingNames = Set(groups.map(\.name))
        guard existingNames.contains(DockGroup.defaultName) else { return DockGroup.defaultName }
        var number = 2
        while existingNames.contains("\(DockGroup.defaultName) \(number)") {
            number += 1
        }
        return "\(DockGroup.defaultName) \(number)"
    }

    private static func removingDuplicates(_ apps: [AppReference]) -> [AppReference] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.normalizedBundleIdentifier).inserted }
    }
}
