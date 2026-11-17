import Foundation

/// Loads and saves the Local Suggestions state.
public protocol SuggestionStatePersisting: Sendable {
    /// The saved state; a fresh one when none is saved.
    func loadState() throws -> SuggestionState
    func saveState(_ state: SuggestionState) throws
    /// Deletes the saved state (Clear History); nothing happens when there is none.
    func deleteState() throws
    /// Move a file that couldn't be loaded out of the way. Return the new location, or `nil` when
    /// there was nothing to move.
    func preserveUnreadableState() throws -> URL?
}

public enum SuggestionStatePersistenceError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
}

/// Stores the `SuggestionState` as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/suggestions-state.json`. Nothing leaves this
/// Mac; the file isn't part of a backup and standalone groups' agents don't read it.
public struct JSONFileSuggestionStatePersistence: SuggestionStatePersisting {
    public static let fileName = "suggestions-state.json"

    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: fileName, directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileSuggestionStatePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The file in `directory`, under its standard name.
    public init(directory: URL) {
        self.init(fileURL: directory.appending(path: Self.fileName, directoryHint: .notDirectory))
    }

    /// Throws for a file that isn't a JSON object or was written in a newer format.
    public func loadState() throws -> SuggestionState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SuggestionState() }
        let data = try Data(contentsOf: fileURL)
        struct Header: Decodable {
            var formatVersion: Int?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                formatVersion = container.decodeLeniently(Int.self, forKey: .formatVersion)
            }

            private enum CodingKeys: String, CodingKey { case formatVersion }
        }
        let version = try JSONDecoder().decode(Header.self, from: data).formatVersion ?? SuggestionState.currentFormatVersion
        guard version <= SuggestionState.currentFormatVersion else {
            throw SuggestionStatePersistenceError.unsupportedFormatVersion(version)
        }
        return try JSONDecoder().decode(SuggestionState.self, from: data)
    }

    public func saveState(_ state: SuggestionState) throws {
        try JSONFileSupport.write(state, to: fileURL)
    }

    public func deleteState() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public func preserveUnreadableState() throws -> URL? {
        try JSONFileSupport.moveAside(fileURL)
    }
}
