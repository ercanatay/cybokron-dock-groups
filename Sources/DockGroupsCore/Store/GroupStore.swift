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
    /// The archived groups that were added, after the current archived ones.
    public let addedArchivedGroups: [ArchivedGroup]
    /// Added groups that came in without their keyboard shortcut, because a current group (or one
    /// added before them) has those keys.
    public let clearedShortcutCount: Int
    /// The copy of the previous groups file, `nil` when nothing was added or nothing had been saved.
    public let copyURL: URL?

    public init(addedGroups: [DockGroup], addedArchivedGroups: [ArchivedGroup] = [], clearedShortcutCount: Int = 0, copyURL: URL?) {
        self.addedGroups = addedGroups
        self.addedArchivedGroups = addedArchivedGroups
        self.clearedShortcutCount = clearedShortcutCount
        self.copyURL = copyURL
    }
}

/// What merging a backup's groups into the current ones would add (`GroupStore.merging`).
public struct GroupMergePlan: Equatable, Sendable {
    /// The groups added, in the backup's order, without the shortcuts other groups have.
    public let active: [DockGroup]
    /// The archived groups added, in the backup's order.
    public let archived: [ArchivedGroup]
    /// Added groups whose shortcut was taken off, because a current group (or one added before
    /// them) has those keys.
    public let clearedShortcutCount: Int

    public var isEmpty: Bool { active.isEmpty && archived.isEmpty }
}

/// What restoring an archived group did (`GroupStore.restoreGroup`).
public struct GroupRestoreResult: Equatable, Sendable {
    /// The group, active again at the end of the list.
    public let group: DockGroup
    /// The shortcut it had when archived, taken off because an active group has those keys now.
    public let removedShortcut: GroupShortcut?
    /// The active group with those keys.
    public let shortcutOwner: DockGroup.ID?
    /// It was standalone when archived. The store leaves Standalone off — its Dock tile has to be
    /// added first — so the app turns it on the way the group's Standalone toggle does.
    public let restoresStandalone: Bool

    /// The title of the note that the group came back without its shortcut.
    public var removedShortcutTitle: String {
        let name = group.name
        return Localization.format("core.archive.restore.noShortcut.title", "“%@” is back without its keyboard shortcut", name)
    }

    /// The note's text: who has the keys now. `keyTitle` is how the keys are shown.
    public func removedShortcutMessage(ownerName: String, keyTitle: String) -> String {
        let name = group.name
        return Localization.format(
            "core.archive.restore.noShortcut.message",
            "“%1$@” uses %2$@ now. Choose another shortcut in “%3$@”'s settings.",
            ownerName, keyTitle, name
        )
    }
}

/// What giving a group a keyboard shortcut did (`GroupStore.setShortcut`).
public enum GroupShortcutAssignment: Equatable, Sendable {
    /// The group has the shortcut now (or none, when it was removed).
    case assigned
    /// The group already had exactly this shortcut; nothing was saved.
    case unchanged
    /// Another group has these keys (rule K6); nothing changed.
    case refused(GroupShortcutRefusal)
    /// No group has this identifier.
    case unknownGroup
}

/// The single source of truth for the user's groups.
///
/// Every change is written to disk shortly after it happens (changes arriving in quick succession,
/// such as dragging a color picker, are coalesced into one write). An empty store stays empty:
/// no sample groups are ever created.
///
/// `groups` are the active groups only. Archived groups are kept apart, in `archivedGroups`, so
/// everything that reads `groups` — the popup, the menus, shortcuts, links, Siri, Focus filters,
/// standalone apps, delayed launches — never sees one. They can't be edited until restored.
@MainActor
public final class GroupStore: ObservableObject {
    /// The active groups, in list order.
    @Published public private(set) var groups: [DockGroup] = []
    /// The archived groups, in the order they were archived (`ArchivedGroup`).
    @Published public private(set) var archivedGroups: [ArchivedGroup] = []
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

    /// The active group with this identifier; never an archived one.
    public func group(withID id: DockGroup.ID) -> DockGroup? {
        groups.first { $0.id == id }
    }

    public func archivedGroup(withID id: DockGroup.ID) -> ArchivedGroup? {
        archivedGroups.first { $0.id == id }
    }

    public func dismissIssue() {
        issue = nil
    }

    // MARK: - Groups

    /// Appends a new, empty group. Without a usable name it gets a unique default ("New Group 2" …,
    /// unique among active and archived groups); a name given is kept as it is, as renaming keeps it.
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

    /// Appends a group made from `template` (`GroupTemplate.makeGroup`): a new identity, its items
    /// and settings, named as the template — or "name 2", "name 3" … when an active or archived
    /// group has that name. It isn't standalone and has no keyboard shortcut. Nothing is opened.
    @discardableResult
    public func addGroup(from template: GroupTemplate) -> DockGroup {
        var group = template.makeGroup(named: GroupNaming.uniqueName(template.name, taken: takenNames))
        group.emoji = DockGroup.sanitizedEmoji(group.emoji) ?? DockGroup.defaultEmoji
        group.apps = Self.removingDuplicates(group.apps)
        group.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(group.freeLayoutSlots, apps: group.apps)
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

    /// Removes the group and its app list, active or archived. The apps themselves aren't touched.
    public func deleteGroup(_ id: DockGroup.ID) {
        guard let index = index(of: id) else {
            deleteArchivedGroup(id)
            return
        }
        groups.remove(at: index)
        scheduleSave()
    }

    /// Makes a copy of an active group at the end of the list: a new identity (so Siri, Focus
    /// filters and links naming the original keep naming it), named "<name> copy" (`GroupNaming`),
    /// with the same items — their details and launch options — and settings, but neither
    /// standalone nor with a keyboard shortcut. At the end, not next to the original, so no
    /// group's number shortcut changes.
    /// - Returns: The copy; `nil` when no active group has this identifier.
    @discardableResult
    public func duplicateGroup(_ id: DockGroup.ID) -> DockGroup? {
        guard let source = group(withID: id) else { return nil }
        let copy = DockGroup(
            name: GroupNaming.copyName(of: source.name, taken: takenNames),
            emoji: source.emoji,
            apps: source.apps,
            tile: source.tile,
            isPinned: source.isPinned,
            isStandalone: false,
            popup: source.popup,
            freeLayoutSlots: source.freeLayoutSlots,
            switching: source.switching,
            shortcut: nil
        )
        groups.append(copy)
        scheduleSave()
        return copy
    }

    // MARK: - Archive

    /// Archives an active group: it leaves `groups` (and so every menu, shortcut, link and agent)
    /// and is kept, as it was, in `archivedGroups`. A standalone group is kept with Standalone off
    /// and `restoresStandalone` on. Running apps aren't touched.
    /// - Returns: The archived group; `nil` when no active group has this identifier.
    @discardableResult
    public func archiveGroup(_ id: DockGroup.ID, at date: Date = Date()) -> ArchivedGroup? {
        guard let index = index(of: id) else { return nil }
        let archived = ArchivedGroup(group: groups[index], archivedAt: date)
        groups.remove(at: index)
        archivedGroups.append(archived)
        scheduleSave()
        return archived
    }

    /// Makes an archived group active again, at the end of the list, with its settings and name. A
    /// shortcut whose keys an active group has now is taken off (`GroupRestoreResult.removedShortcut`).
    /// Standalone stays off (`GroupRestoreResult.restoresStandalone`).
    /// - Returns: What was restored; `nil` when no archived group has this identifier.
    @discardableResult
    public func restoreGroup(_ id: DockGroup.ID) -> GroupRestoreResult? {
        guard let index = archivedGroups.firstIndex(where: { $0.id == id }) else { return nil }
        let archived = archivedGroups[index]
        var group = archived.group
        var removedShortcut: GroupShortcut?
        var owner: DockGroup.ID?
        if let shortcut = group.shortcut, let other = shortcutOwner(of: shortcut.keys, except: id) {
            removedShortcut = shortcut
            owner = other
            group.shortcut = nil
        }
        archivedGroups.remove(at: index)
        groups.append(group)
        scheduleSave()
        return GroupRestoreResult(group: group, removedShortcut: removedShortcut, shortcutOwner: owner, restoresStandalone: archived.restoresStandalone)
    }

    /// Deletes an archived group for good.
    /// - Returns: Whether an archived group had this identifier.
    @discardableResult
    public func deleteArchivedGroup(_ id: DockGroup.ID) -> Bool {
        guard let index = archivedGroups.firstIndex(where: { $0.id == id }) else { return false }
        archivedGroups.remove(at: index)
        scheduleSave()
        return true
    }

    public func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = groups.map(\.id)
        groups.moveElements(fromOffsets: source, toOffset: destination)
        if groups.map(\.id) != before {
            scheduleSave()
        }
    }

    /// Applies `change` to a group. Blank names or emoji are rejected (the previous value is kept),
    /// duplicate apps are dropped, and keys another group's shortcut has aren't taken (the previous
    /// shortcut is kept), so the group's invariants always hold.
    public func updateGroup(_ id: DockGroup.ID, _ change: (inout DockGroup) -> Void) {
        guard let index = index(of: id) else { return }
        let original = groups[index]
        var edited = original
        change(&edited)
        edited.name = DockGroup.sanitizedName(edited.name) ?? original.name
        edited.emoji = DockGroup.sanitizedEmoji(edited.emoji) ?? original.emoji
        edited.apps = Self.removingDuplicates(edited.apps)
        edited.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(edited.freeLayoutSlots, apps: edited.apps)
        if let keys = edited.shortcut?.keys, keys != original.shortcut?.keys, shortcutOwner(of: keys, except: id) != nil {
            edited.shortcut = original.shortcut
        }
        guard edited != original else { return }
        groups[index] = edited
        scheduleSave()
    }

    // MARK: - Shortcuts

    /// Gives a group its own keyboard shortcut, or removes it (`nil`). Keys another group's shortcut
    /// has are refused (rule K6); the static rules (K1–K3) hold for every `GroupShortcut`. Rules
    /// that depend on the settings and macOS (K4, K5) aren't the store's: a shortcut they turn off
    /// is kept and shown as off (`GroupShortcutPlanner`). Keeping the keys and changing only the
    /// action is always taken.
    @discardableResult
    public func setShortcut(_ shortcut: GroupShortcut?, forGroup id: DockGroup.ID) -> GroupShortcutAssignment {
        guard let index = index(of: id) else { return .unknownGroup }
        let original = groups[index].shortcut
        guard shortcut != original else { return .unchanged }
        if let keys = shortcut?.keys, keys != original?.keys, let owner = shortcutOwner(of: keys, except: id) {
            return .refused(.takenByGroup(owner))
        }
        groups[index].shortcut = shortcut
        scheduleSave()
        return .assigned
    }

    /// The group other than `id` whose shortcut has `keys`.
    private func shortcutOwner(of keys: KeyCombination, except id: DockGroup.ID) -> DockGroup.ID? {
        groups.first { $0.id != id && $0.shortcut?.keys == keys }?.id
    }

    // MARK: - Items

    /// Appends the apps that aren't in the group yet, in order: `addItems(_:toGroup:)`.
    @discardableResult
    public func addApps(_ apps: [AppReference], toGroup id: DockGroup.ID) -> Int {
        addItems(apps, toGroup: id)
    }

    /// Appends the items (apps, websites, files, folders) that aren't in the group yet, in order.
    /// A file or folder whose location is invalid or whose name is refused
    /// (`FileItemPolicy.acceptsByIdentity`) is left out. Returns how many were added.
    @discardableResult
    public func addItems(_ items: [GroupItem], toGroup id: DockGroup.ID) -> Int {
        guard let index = index(of: id) else { return 0 }
        let combined = Self.removingDuplicates(groups[index].apps + items.filter(FileItemPolicy.acceptsByIdentity))
        let addedCount = combined.count - groups[index].apps.count
        guard addedCount > 0 else { return 0 }
        groups[index].apps = combined
        scheduleSave()
        return addedCount
    }

    /// Gives an item of the group new details (alias, tags, task notes). Nothing is saved when they
    /// are the same as before, so a standalone group's app isn't rebuilt for nothing.
    /// - Returns: Whether the details changed; `false` when they didn't or the group doesn't have
    ///   the item.
    @discardableResult
    public func updateDetails(_ details: ItemDetails, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        guard let groupIndex = index(of: id),
              let itemIndex = itemIndex(of: identity, inGroupAt: groupIndex),
              groups[groupIndex].apps[itemIndex].details != details
        else { return false }
        groups[groupIndex].apps[itemIndex].details = details
        scheduleSave()
        return true
    }

    /// Gives an item of the group new launch options (delay, the app that opens it); an app keeps
    /// no opener. Nothing is saved when they are the same as before.
    /// - Returns: Whether the options changed; `false` when they didn't or the group doesn't have
    ///   the item.
    @discardableResult
    public func updateLaunchOptions(_ options: ItemLaunchOptions, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        guard let groupIndex = index(of: id), let itemIndex = itemIndex(of: identity, inGroupAt: groupIndex) else { return false }
        let allowed = options.allowed(for: groups[groupIndex].apps[itemIndex].kind)
        guard groups[groupIndex].apps[itemIndex].launch != allowed else { return false }
        groups[groupIndex].apps[itemIndex].launch = allowed
        scheduleSave()
        return true
    }

    /// Gives an item of the group new details and launch options at once (`nil`: kept as they are),
    /// as one change of the group: one save, one notification of `groups`. An app keeps no opener.
    /// - Returns: Whether the item changed; `false` when it didn't or the group doesn't have it.
    @discardableResult
    public func updateItem(_ identity: String, inGroup id: DockGroup.ID, details: ItemDetails?, launch: ItemLaunchOptions?) -> Bool {
        guard let groupIndex = index(of: id), let itemIndex = itemIndex(of: identity, inGroupAt: groupIndex) else { return false }
        let original = groups[groupIndex].apps[itemIndex]
        var edited = original
        if let details { edited.details = details }
        if let launch { edited.launch = launch.allowed(for: edited.kind) }
        guard edited != original else { return false }
        groups[groupIndex].apps[itemIndex] = edited
        scheduleSave()
        return true
    }

    /// Points a file or folder item at its new location `url`, as "Locate…" does after it was moved
    /// or renamed. It keeps its kind, details, launch options, place in the list and Free Layout
    /// cell; its name becomes `name`, or the location's last component.
    /// - Returns: Whether the item now points at `url`; `false` when the group doesn't have the
    ///   item, it isn't a file or folder, `url` can't be one of its kind (`FileItemPolicy`), or
    ///   another item of the group is already there.
    @discardableResult
    public func relinkItem(_ identity: String, inGroup id: DockGroup.ID, to url: URL, name: String? = nil) -> Bool {
        guard let groupIndex = index(of: id), let itemIndex = itemIndex(of: identity, inGroupAt: groupIndex) else { return false }
        var group = groups[groupIndex]
        let original = group.apps[itemIndex]
        guard original.kind.isFileSystemItem else { return false }
        var relinked = GroupItem(fileURL: url, kind: original.kind, name: name)
        relinked.details = original.details
        relinked.launch = original.launch
        guard FileItemPolicy.acceptsByIdentity(relinked) else { return false }
        let oldKey = original.normalizedBundleIdentifier
        let newKey = relinked.normalizedBundleIdentifier
        if newKey != oldKey, group.apps.contains(where: { $0.normalizedBundleIdentifier == newKey }) {
            return false
        }
        group.apps[itemIndex] = relinked
        if let slot = group.freeLayoutSlots.removeValue(forKey: oldKey) {
            group.freeLayoutSlots[newKey] = slot
        }
        if group != groups[groupIndex] {
            groups[groupIndex] = group
            scheduleSave()
        }
        return true
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
    /// the way edits are: blank names and emoji get defaults, duplicate apps are dropped, of
    /// groups sharing an identifier only the first is kept, and of groups whose shortcuts share
    /// keys only the first keeps its shortcut.
    /// - Returns: The copy of the previous file, or `nil` when nothing had been saved.
    @discardableResult
    public func replaceGroups(with newGroups: [DockGroup]) throws -> URL? {
        try replaceGroups(with: StoredGroups(active: newGroups), copyLabel: "pre-import")
    }

    /// `replaceGroups(with:)` with archived groups too: both lists are replaced. Archived groups
    /// are cleaned up as active ones are, and keep their shortcuts (archived groups hold no keys).
    @discardableResult
    public func replaceGroups(with newGroups: StoredGroups) throws -> URL? {
        try replaceGroups(with: newGroups, copyLabel: "pre-import")
    }

    /// `replaceGroups(with:)`; without a `copyLabel` the current file isn't copied first.
    @discardableResult
    func replaceGroups(with newGroups: [DockGroup], copyLabel: String?) throws -> URL? {
        try replaceGroups(with: StoredGroups(active: newGroups), copyLabel: copyLabel)
    }

    @discardableResult
    func replaceGroups(with newGroups: StoredGroups, copyLabel: String?) throws -> URL? {
        // The copy should hold what's on screen, not an older write.
        if !isSavingSuspended {
            flushPendingSave()
        }
        let copyURL = try copyLabel.flatMap { try persistence.preserveCopy(label: $0) }
        let sanitized = Self.sanitizedForRestore(newGroups)
        try persistence.saveStoredGroups(sanitized)
        archivedGroups = sanitized.archived
        groups = sanitized.active
        // The unreadable file that suspended saving was just copied aside and replaced.
        isSavingSuspended = false
        issue = nil
        return copyURL
    }

    /// Copies the saved file next to itself (`groups.<label>-<timestamp>.json`; the last three
    /// copies with that label are kept), a pending change written first, so the copy holds what's
    /// on screen — as before installing an older version (`DowngradeProtection`).
    /// - Returns: The copy's location, or `nil` when nothing has been saved.
    @discardableResult
    public func preserveCopy(label: String) throws -> URL? {
        if !isSavingSuspended {
            flushPendingSave()
        }
        return try persistence.preserveCopy(label: label)
    }

    /// Adds the groups of `incoming` (and the archived groups of `archived`) that aren't here yet
    /// after the current ones, as merging a backup does; every current group stays as it is. A
    /// group is skipped when a current group, active or archived, has the same name (ignoring case
    /// and surrounding spaces) or the same identifier — and so are later groups repeating one
    /// already added. An added group whose shortcut a current group (or one added before it) has
    /// comes in without it (`GroupMergeResult.clearedShortcutCount`). The added groups are cleaned
    /// up the way `replaceGroups(with:)` cleans them. When something is added, the current file is
    /// first copied next to itself (`groups.pre-import-<timestamp>.json`) and the new list is
    /// written before it's shown, so if anything fails nothing changes.
    @discardableResult
    public func mergeGroups(_ incoming: [DockGroup], archived: [ArchivedGroup] = []) throws -> GroupMergeResult {
        let plan = Self.merging(StoredGroups(active: incoming, archived: archived), into: StoredGroups(active: groups, archived: archivedGroups))
        guard !plan.isEmpty else { return GroupMergeResult(addedGroups: [], copyURL: nil) }
        let merged = Self.sanitizedForRestore(StoredGroups(active: groups + plan.active, archived: archivedGroups + plan.archived))
        let addedIDs = Set(plan.active.map(\.id))
        let addedArchivedIDs = Set(plan.archived.map(\.id))
        let copyURL = try replaceGroups(with: merged, copyLabel: "pre-import")
        return GroupMergeResult(
            addedGroups: merged.active.filter { addedIDs.contains($0.id) },
            addedArchivedGroups: merged.archived.filter { addedArchivedIDs.contains($0.id) },
            clearedShortcutCount: plan.clearedShortcutCount,
            copyURL: copyURL
        )
    }

    /// The groups of `incoming` that merging adds to `current`, unchanged and in order: see
    /// `mergeGroups(_:archived:)`.
    public nonisolated static func groupsAddedByMerging(_ incoming: [DockGroup], into current: [DockGroup]) -> [DockGroup] {
        merging(StoredGroups(active: incoming), into: StoredGroups(active: current), clearingShortcuts: false).active
    }

    /// What merging `incoming` into `current` adds: see `mergeGroups(_:archived:)`. Names and
    /// identifiers are matched against active and archived groups alike; active groups come before
    /// archived ones.
    public nonisolated static func merging(_ incoming: StoredGroups, into current: StoredGroups) -> GroupMergePlan {
        merging(incoming, into: current, clearingShortcuts: true)
    }

    private nonisolated static func merging(_ incoming: StoredGroups, into current: StoredGroups, clearingShortcuts: Bool) -> GroupMergePlan {
        var names = Set((current.active + current.archived.map(\.group)).map(mergeName(of:)))
        var ids = Set(current.active.map(\.id) + current.archived.map(\.id))
        func isNew(_ group: DockGroup) -> Bool {
            let name = mergeName(of: group)
            guard !ids.contains(group.id), !names.contains(name) else { return false }
            names.insert(name)
            ids.insert(group.id)
            return true
        }
        // Archived groups hold no keys: only the active groups' shortcuts are kept apart.
        var keys = Set(current.active.compactMap(\.shortcut?.keys))
        var cleared = 0
        let active = incoming.active.filter(isNew).map { group -> DockGroup in
            guard clearingShortcuts, let shortcutKeys = group.shortcut?.keys, !keys.insert(shortcutKeys).inserted else { return group }
            cleared += 1
            var group = group
            group.shortcut = nil
            return group
        }
        let archived = incoming.archived.filter { isNew($0.group) }
        return GroupMergePlan(active: active, archived: archived, clearedShortcutCount: cleared)
    }

    /// The name groups are matched by: as the store keeps it (trimmed, a blank one replaced by the
    /// default), ignoring case.
    nonisolated static func mergeName(of group: DockGroup) -> String {
        GroupNaming.comparisonKey(group.name)
    }

    /// Both lists cleaned up for a restore: the active groups as `sanitizedForRestore(_:)` cleans
    /// them, the archived ones the same way but keeping their shortcuts (archived groups hold no
    /// keys), identifiers unique across both.
    private static func sanitizedForRestore(_ stored: StoredGroups) -> StoredGroups {
        let active = sanitizedForRestore(stored.active)
        var seenIDs = Set(active.map(\.id))
        let archived = stored.archived.compactMap { archived -> ArchivedGroup? in
            guard seenIDs.insert(archived.id).inserted else { return nil }
            return archived.replacingGroup(sanitizedGroup(archived.group))
        }
        return StoredGroups(active: active, archived: archived)
    }

    /// A group cleaned up as edits clean it: blank names and emoji get defaults, duplicate apps are
    /// dropped, Free Layout cells fit its apps.
    private static func sanitizedGroup(_ group: DockGroup) -> DockGroup {
        var sanitized = group
        sanitized.name = DockGroup.sanitizedName(group.name) ?? DockGroup.defaultName
        sanitized.emoji = DockGroup.sanitizedEmoji(group.emoji) ?? DockGroup.defaultEmoji
        sanitized.apps = removingDuplicates(group.apps)
        sanitized.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(group.freeLayoutSlots, apps: sanitized.apps)
        return sanitized
    }

    /// The groups cleaned up as edits clean them; of groups sharing an identifier only the first is
    /// kept, and of shortcuts sharing keys only the first group's.
    private static func sanitizedForRestore(_ groups: [DockGroup]) -> [DockGroup] {
        var seenIDs = Set<DockGroup.ID>()
        var seenKeys = Set<KeyCombination>()
        return groups.compactMap { group in
            guard seenIDs.insert(group.id).inserted else { return nil }
            var sanitized = sanitizedGroup(group)
            if let keys = group.shortcut?.keys, !seenKeys.insert(keys).inserted {
                sanitized.shortcut = nil
            }
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
            let stored = try persistence.loadStoredGroups()
            archivedGroups = stored.archived
            groups = stored.active
        } catch let loadError {
            logger.error("Loading groups failed: \(String(describing: loadError), privacy: .public)")
            groups = []
            archivedGroups = []
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
            try persistence.saveStoredGroups(StoredGroups(active: groups, archived: archivedGroups))
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

    private func itemIndex(of identity: String, inGroupAt groupIndex: Int) -> Int? {
        let target = identity.lowercased()
        return groups[groupIndex].apps.firstIndex { $0.normalizedBundleIdentifier == target }
    }

    /// The names of the active and archived groups, which names the store makes avoid.
    private var takenNames: [String] {
        groups.map(\.name) + archivedGroups.map(\.group.name)
    }

    private func nextDefaultName() -> String {
        GroupNaming.uniqueName(DockGroup.defaultName, taken: takenNames)
    }

    private static func removingDuplicates(_ apps: [AppReference]) -> [AppReference] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.normalizedBundleIdentifier).inserted }
    }
}
