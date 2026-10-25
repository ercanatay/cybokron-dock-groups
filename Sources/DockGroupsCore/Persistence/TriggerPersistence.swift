import Foundation

/// Loads and saves the triggers.
public protocol TriggerPersisting {
    /// Returns the saved triggers, or none when nothing has been saved yet.
    func loadTriggers() throws -> [GroupTrigger]
    func saveTriggers(_ triggers: [GroupTrigger]) throws
    /// Moves saved data that couldn't be loaded out of the way so later saves don't overwrite it.
    /// Returns the new location, or `nil` when there was nothing to move.
    func preserveUnreadableData() throws -> URL?
    /// Copies the saved file next to itself before it's replaced wholesale, as restoring a backup
    /// does. Returns the copy's location, or `nil` when there's nothing saved.
    func preserveCopy(label: String) throws -> URL?
}

extension TriggerPersisting {
    public func preserveCopy(label: String) throws -> URL? { nil }
}

public enum TriggerPersistenceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return Localization.format(
                "core.trigger.persistence.newer",
                "The triggers file was saved by a newer version of Cybokron Dock Groups (format %ld).",
                version
            )
        }
    }
}

/// On-disk envelope of the triggers: `{ "formatVersion": 1, "triggers": [ … ] }` (triggers spec
/// §2.7). An entry without a readable identifier or group is left out; everything else of an entry
/// is read leniently (`GroupTrigger`), and an event this version can't read is kept as it was.
struct TriggersDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var triggers: [GroupTrigger]

    init(triggers: [GroupTrigger]) {
        formatVersion = Self.currentFormatVersion
        self.triggers = triggers
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, triggers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        triggers = try container.decode([LenientTrigger].self, forKey: .triggers).compactMap(\.trigger)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(triggers, forKey: .triggers)
    }

    /// A trigger that can't be read at all is left out rather than making the file unreadable.
    struct LenientTrigger: Decodable {
        let trigger: GroupTrigger?

        init(from decoder: Decoder) throws {
            trigger = try? GroupTrigger(from: decoder)
        }
    }
}

/// Stores the triggers as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/triggers.json`, next to the groups — a file
/// versions without triggers (0.10.0 and earlier) never open, so going back and forth keeps them.
/// Nothing leaves this Mac.
public struct JSONFileTriggerPersistence: TriggerPersisting {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "triggers.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileTriggerPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadTriggers() throws -> [GroupTrigger] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let document = try JSONDecoder().decode(TriggersDocument.self, from: Data(contentsOf: fileURL))
        guard document.formatVersion <= TriggersDocument.currentFormatVersion else {
            throw TriggerPersistenceError.unsupportedFormatVersion(document.formatVersion)
        }
        return document.triggers
    }

    public func saveTriggers(_ triggers: [GroupTrigger]) throws {
        try JSONFileSupport.write(TriggersDocument(triggers: triggers), to: fileURL)
    }

    public func preserveUnreadableData() throws -> URL? {
        try JSONFileSupport.moveAside(fileURL)
    }

    public func preserveCopy(label: String) throws -> URL? {
        try JSONFileSupport.copyAside(fileURL, label: label)
    }
}
