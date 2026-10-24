import Foundation

/// Loads and saves the group list: the active groups and the archived ones.
public protocol GroupPersisting {
    /// Returns the saved active groups — never the archived ones — or an empty list when nothing
    /// has been saved yet. Siri and Shortcuts read the groups this way before the app is ready.
    func loadGroups() throws -> [DockGroup]
    /// Saves `groups` as the whole list, without archived groups.
    func saveGroups(_ groups: [DockGroup]) throws
    /// Moves saved data that couldn't be loaded out of the way so later saves don't overwrite it.
    /// Returns the new location, or `nil` when there was nothing to move.
    func preserveUnreadableData() throws -> URL?
    /// Copies the saved file next to itself before it's replaced wholesale, as restoring a backup
    /// does. Returns the copy's location, or `nil` when there's nothing saved (or nothing on disk).
    func preserveCopy(label: String) throws -> URL?
    /// Returns the saved active and archived groups. `GroupStore` loads them this way.
    func loadStoredGroups() throws -> StoredGroups
    /// Saves the active and archived groups. `GroupStore` saves them this way.
    func saveStoredGroups(_ groups: StoredGroups) throws
}

extension GroupPersisting {
    public func preserveCopy(label: String) throws -> URL? { nil }

    /// A persistence that knows only active groups has no archived ones.
    public func loadStoredGroups() throws -> StoredGroups {
        StoredGroups(active: try loadGroups())
    }

    /// A persistence that knows only active groups refuses archived ones rather than dropping them.
    public func saveStoredGroups(_ groups: StoredGroups) throws {
        guard groups.archived.isEmpty else { throw GroupPersistenceError.archivedGroupsUnsupported }
        try saveGroups(groups.active)
    }
}

public enum GroupPersistenceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    /// Archived groups were to be saved where only active groups can be.
    case archivedGroupsUnsupported

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return Localization.format("core.persistence.groups.newer", "The groups file was saved by a newer version of Cybokron Dock Groups (format %ld).", version)
        case .archivedGroupsUnsupported:
            return Localization.string("core.persistence.groups.archivedUnsupported", "The archived groups can't be saved here.")
        }
    }
}

/// On-disk envelope of the group list: `{ "formatVersion": 1, "groups": [ … ] }`, the active groups
/// first, then the archived ones marked `"archived": true` (`GroupEntry`). The format version
/// stays 1: a version without archives reads the archived groups as ordinary groups.
struct GroupsDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var stored: StoredGroups

    init(stored: StoredGroups) {
        formatVersion = Self.currentFormatVersion
        self.stored = stored
    }

    init(groups: [DockGroup]) {
        self.init(stored: StoredGroups(active: groups))
    }

    var groups: [DockGroup] { stored.active }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        stored = GroupEntry.storedGroups(from: try container.decode([GroupEntry].self, forKey: .groups))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(GroupEntry.entries(of: stored), forKey: .groups)
    }
}

/// Stores the group list as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/groups.json`. Nothing leaves this Mac.
public struct JSONFileGroupPersistence: GroupPersisting {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "groups.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileGroupPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The active groups only: archived groups never leave the file this way.
    public func loadGroups() throws -> [DockGroup] {
        try loadStoredGroups().active
    }

    /// Writes `groups` as the whole file, without archived groups.
    public func saveGroups(_ groups: [DockGroup]) throws {
        try saveStoredGroups(StoredGroups(active: groups))
    }

    public func loadStoredGroups() throws -> StoredGroups {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StoredGroups() }
        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(GroupsDocument.self, from: data)
        guard document.formatVersion <= GroupsDocument.currentFormatVersion else {
            throw GroupPersistenceError.unsupportedFormatVersion(document.formatVersion)
        }
        return document.stored
    }

    public func saveStoredGroups(_ groups: StoredGroups) throws {
        try JSONFileSupport.write(GroupsDocument(stored: groups), to: fileURL)
    }

    public func preserveUnreadableData() throws -> URL? {
        try JSONFileSupport.moveAside(fileURL)
    }

    public func preserveCopy(label: String) throws -> URL? {
        try JSONFileSupport.copyAside(fileURL, label: label)
    }
}
