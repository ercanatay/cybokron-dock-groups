import Foundation
import OSLog

/// A standalone group's tile as the Dock's app list should have it.
public struct AgentTile: Equatable, Sendable {
    public let groupID: UUID
    public let bundleIdentifier: String
    /// The group's name, shown under the tile.
    public let label: String
    /// The agent's bundle; `nil` while it isn't installed: a tile already in the list is kept as
    /// it is, and none is added.
    public let bundleURL: URL?

    public init(groupID: UUID, bundleIdentifier: String, label: String, bundleURL: URL?) {
        self.groupID = groupID
        self.bundleIdentifier = bundleIdentifier
        self.label = label
        self.bundleURL = bundleURL
    }
}

/// The standalone groups' tiles in the Dock's app list (`persistent-apps`): which groups get a tile
/// added on the next pass, which lost theirs, and the edits that bring the list in line with the
/// agents. When the list can't be read nothing is decided from it and nothing is written; before
/// every change the list as it was is copied aside (`DockTileBackups`).
public final class AgentDockTiles {
    /// What `apply` did.
    public enum Outcome: Equatable, Sendable {
        /// The Dock's list couldn't be read: nothing was changed and the pending additions wait.
        case unreadable
        /// The list already matched.
        case unchanged
        /// The list was written; the Dock needs a restart to show it.
        case saved(previousCount: Int, count: Int)
        /// Writing the list failed. `groupIDs` are the groups whose tile was to be added or updated;
        /// the pending additions are kept for the next pass.
        case saveFailed(message: String, groupIDs: Set<UUID>)
    }

    /// Groups whose tile the next pass adds (just turned on). Other
    /// passes only update tiles that are there: a tile the user removed doesn't come back.
    public private(set) var pendingAdditions: Set<UUID> = []

    private let store: DockTileStoring
    private let backups: DockTileBackups?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Standalone")

    /// - Parameter backups: Where the list is copied before each change; `nil` keeps no copies.
    public init(store: DockTileStoring, backups: DockTileBackups? = DockTileBackups()) {
        self.store = store
        self.backups = backups
    }

    /// The group was turned on: its tile is added on the next pass.
    public func requestAddition(of groupID: UUID) {
        pendingAdditions.insert(groupID)
    }

    /// The group was turned off before its tile was added.
    public func cancelAddition(of groupID: UUID) {
        pendingAdditions.remove(groupID)
    }

    /// Standalone groups among `groups` whose tile isn't in the Dock any more (the user dragged it
    /// out), leaving out those waiting for their tile. `nil` when the Dock's list can't be read:
    /// then no group may be turned off.
    public func groupsRemovedFromDock(among groups: [DockGroup]) -> [UUID]? {
        let candidates = groups.filter { $0.isStandalone && !pendingAdditions.contains($0.id) }.map(\.id)
        guard !candidates.isEmpty else { return [] }
        guard let entries = store.loadPersistentApps() else { return nil }
        return AgentPlanner.groupsRemovedFromDock(
            standaloneGroupIDs: candidates,
            dockBundleIdentifiers: DockTileList.bundleIdentifiers(in: entries)
        )
    }

    /// Bundle identifiers of the agents' tiles in the Dock, lowercased; `nil` when the list can't
    /// be read.
    public func agentBundleIdentifiersInDock() -> Set<String>? {
        store.loadPersistentApps().map { Set(DockTileList.agentBundleIdentifiers(in: $0).map { $0.lowercased() }) }
    }

    /// Brings the Dock's list in line with `tiles`, the agents that should have one: tiles of other
    /// agents are removed, pending groups get theirs added (or updated in place), the others' are
    /// updated when their bundle moved or the group was renamed. Tiles of other apps stay as they
    /// are.
    ///
    /// - Parameter standaloneGroupIDs: The groups that are standalone now; pending additions of
    ///   other groups are dropped.
    public func apply(_ tiles: [AgentTile], standaloneGroupIDs: Set<UUID>) -> Outcome {
        guard let original = store.loadPersistentApps() else {
            pendingAdditions.formIntersection(standaloneGroupIDs)
            return .unreadable
        }
        var entries = original
        var changed = false
        var changedGroups: Set<UUID> = []
        let wanted = Set(tiles.map { $0.bundleIdentifier.lowercased() })
        let unwanted = DockTileList.agentBundleIdentifiers(in: entries).filter { !wanted.contains($0.lowercased()) }
        if let updated = DockTileList.removing(bundleIdentifiers: unwanted, from: entries) {
            entries = updated
            changed = true
        }
        for tile in tiles {
            guard let bundleURL = tile.bundleURL else { continue }
            let updated = pendingAdditions.contains(tile.groupID)
                ? DockTileList.upserting(bundleIdentifier: tile.bundleIdentifier, bundleURL: bundleURL, label: tile.label, in: entries)
                : DockTileList.updating(bundleIdentifier: tile.bundleIdentifier, bundleURL: bundleURL, label: tile.label, in: entries)
            if let updated {
                entries = updated
                changed = true
                changedGroups.insert(tile.groupID)
            }
        }

        if changed {
            if let backups {
                do {
                    let copy = try backups.save(original)
                    logger.notice("Backed up the Dock's app list (\(original.count, privacy: .public) apps) to \(copy.lastPathComponent, privacy: .public)")
                } catch {
                    // The copy is a safety net; changing the Dock doesn't depend on it.
                    logger.error("Backing up the Dock's app list failed: \(String(describing: error), privacy: .public)")
                }
            }
            do {
                try store.savePersistentApps(entries)
            } catch {
                pendingAdditions.formIntersection(standaloneGroupIDs)
                return .saveFailed(message: error.localizedDescription, groupIDs: changedGroups)
            }
        }
        pendingAdditions.subtract(tiles.filter { $0.bundleURL != nil }.map(\.groupID))
        pendingAdditions.formIntersection(standaloneGroupIDs)
        return changed ? .saved(previousCount: original.count, count: entries.count) : .unchanged
    }
}

/// Copies of the Dock's app list taken before the app changes it, as property lists (the list holds
/// data and dates JSON can't keep) named `persistent-apps-<UTC time>.plist`, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/dock-backups/`. Only the newest `keep` copies
/// are kept. They're there to put the Dock's list back by hand should a change go wrong.
public struct DockTileBackups: Sendable {
    public static let defaultKeep = 6
    static let prefix = "persistent-apps-"
    static let fileExtension = "plist"

    public static var defaultDirectory: URL {
        JSONFileSupport.directoryURL.appending(path: "dock-backups", directoryHint: .isDirectory)
    }

    public let directory: URL
    public let keep: Int
    private let now: @Sendable () -> Date

    public init(
        directory: URL = DockTileBackups.defaultDirectory,
        keep: Int = DockTileBackups.defaultKeep,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.keep = max(keep, 1)
        self.now = now
    }

    /// Writes `entries` to a new copy and removes all but the newest `keep`. Returns the copy.
    @discardableResult
    public func save(_ entries: [DockTileEntry]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(for: now())
        try data.write(to: url, options: .atomic)
        for old in copies().dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }

    /// The copies, newest first.
    public func copies() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(".\(Self.fileExtension)") }
            // The UTC time in the name sorts as text; a copy made in the same millisecond as
            // another gets a counter after the time, which sorts as newer.
            .sorted { ($0 as NSString).deletingPathExtension > ($1 as NSString).deletingPathExtension }
            .map { directory.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// The entries in a copy, `nil` when it can't be read.
    public static func entries(in copy: URL) -> [DockTileEntry]? {
        guard let data = try? Data(contentsOf: copy) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [DockTileEntry]
    }

    private func uniqueURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = Self.prefix + formatter.string(from: date)
        var name = "\(base).\(Self.fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
            name = String(format: "%@-%02d.%@", base, counter, Self.fileExtension)
            counter += 1
        }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }
}
