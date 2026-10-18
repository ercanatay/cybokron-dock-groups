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
        groups[index].apps = remaining
        scheduleSave()
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

    /// Puts the group's apps in the order of `apps` (the same apps, reordered).
    private func reorderApps(inGroupAt index: Int, to apps: [AppReference]) {
        guard apps != groups[index].apps else { return }
        groups[index].apps = apps
        scheduleSave()
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
                let kept = backupURL.map { " A copy was kept at “\($0.path)”." } ?? ""
                issue = GroupStoreIssue(
                    title: "Your groups couldn't be loaded",
                    message: "\(loadError.localizedDescription) Starting with an empty group list.\(kept)"
                )
            } catch let moveError {
                logger.error("Preserving unreadable groups failed: \(String(describing: moveError), privacy: .public)")
                isSavingSuspended = true
                issue = GroupStoreIssue(
                    title: "Your groups couldn't be loaded",
                    message: "\(loadError.localizedDescription) To protect the existing file, changes won't be saved until the app is restarted."
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
                    title: "Your changes couldn't be saved",
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
