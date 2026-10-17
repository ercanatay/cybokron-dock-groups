import Foundation

/// Loads and saves the app-wide popup preferences.
public protocol PreferencesPersisting {
    /// Returns the saved preferences, or `nil` when nothing has been saved yet.
    func loadPreferences() throws -> PopupPreferences?
    func savePreferences(_ preferences: PopupPreferences) throws
    /// Moves a saved file that couldn't be loaded out of the way. Returns the new location, or
    /// `nil` when there was nothing to move.
    func preserveUnreadableData() throws -> URL?
}

/// On-disk form of the preferences: a flat JSON object with a format version next to the settings.
struct PreferencesDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var preferences: PopupPreferences

    init(preferences: PopupPreferences) {
        formatVersion = Self.currentFormatVersion
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
    }

    init(from decoder: Decoder) throws {
        // Requiring a JSON object rejects files that aren't preferences at all; within the object
        // every value is optional.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = container.decodeLeniently(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        preferences = try PopupPreferences(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try preferences.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
    }
}

/// Stores the preferences as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/preferences.json`.
public struct JSONFilePreferencesPersistence: PreferencesPersisting {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "preferences.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFilePreferencesPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadPreferences() throws -> PopupPreferences? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(PreferencesDocument.self, from: data).preferences
    }

    public func savePreferences(_ preferences: PopupPreferences) throws {
        try JSONFileSupport.write(PreferencesDocument(preferences: preferences), to: fileURL)
    }

    public func preserveUnreadableData() throws -> URL? {
        try JSONFileSupport.moveAside(fileURL)
    }
}
