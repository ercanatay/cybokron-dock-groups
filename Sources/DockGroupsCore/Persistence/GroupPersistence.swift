import Foundation

/// Loads and saves the group list.
public protocol GroupPersisting {
    /// Returns the saved groups, or an empty list when nothing has been saved yet.
    func loadGroups() throws -> [DockGroup]
    func saveGroups(_ groups: [DockGroup]) throws
    /// Moves saved data that couldn't be loaded out of the way so later saves don't overwrite it.
    /// Returns the new location, or `nil` when there was nothing to move.
    func preserveUnreadableData() throws -> URL?
}

public enum GroupPersistenceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "The groups file was saved by a newer version of Cybokron Dock Groups (format \(version))."
        }
    }
}

/// On-disk envelope of the group list.
struct GroupsDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var groups: [DockGroup]

    init(groups: [DockGroup]) {
        formatVersion = Self.currentFormatVersion
        self.groups = groups
    }
}

/// Stores the group list as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/groups.json`. Nothing leaves this Mac.
public struct JSONFileGroupPersistence: GroupPersisting {
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(components: "Cybokron", "DockGroups", "groups.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileGroupPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadGroups() throws -> [DockGroup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(GroupsDocument.self, from: data)
        guard document.formatVersion <= GroupsDocument.currentFormatVersion else {
            throw GroupPersistenceError.unsupportedFormatVersion(document.formatVersion)
        }
        return document.groups
    }

    public func saveGroups(_ groups: [DockGroup]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(GroupsDocument(groups: groups))
        try data.write(to: fileURL, options: .atomic)
    }

    public func preserveUnreadableData() throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let backupURL = fileURL.deletingLastPathComponent().appending(
            path: "\(baseName).unreadable-\(formatter.string(from: Date())).json",
            directoryHint: .notDirectory
        )
        try FileManager.default.moveItem(at: fileURL, to: backupURL)
        return backupURL
    }
}
