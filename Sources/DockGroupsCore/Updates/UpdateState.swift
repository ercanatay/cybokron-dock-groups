import Foundation

/// What the updater remembers between launches, in `update-state.json` next to the preferences. Kept
/// apart from `preferences.json` because it changes with every check, not with the user's choices.
public struct UpdateState: Equatable, Sendable {
    /// When the latest check finished, successfully or not.
    public var lastCheckDate: Date?
    /// A version the user chose to skip; automatic checks don't offer it again.
    public var skippedVersion: String?

    public init(lastCheckDate: Date? = nil, skippedVersion: String? = nil) {
        self.lastCheckDate = lastCheckDate
        self.skippedVersion = skippedVersion
    }
}

extension UpdateState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, lastCheckDate, skippedVersion
    }

    /// Every field is optional; unreadable values are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckDate = container.decodeLeniently(Double.self, forKey: .lastCheckDate).map(Date.init(timeIntervalSince1970:))
        skippedVersion = container.decodeLeniently(String.self, forKey: .skippedVersion)
    }

    /// Dates as seconds since 1970, like the usage statistics.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .formatVersion)
        try container.encodeIfPresent(lastCheckDate?.timeIntervalSince1970, forKey: .lastCheckDate)
        try container.encodeIfPresent(skippedVersion, forKey: .skippedVersion)
    }
}

/// Stores the `UpdateState` as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/update-state.json`.
public struct JSONFileUpdateStatePersistence: Sendable {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "update-state.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileUpdateStatePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The saved state; a missing or unreadable file means a fresh state (the file only holds
    /// conveniences, nothing worth keeping aside).
    public func load() -> UpdateState {
        guard let data = try? Data(contentsOf: fileURL) else { return UpdateState() }
        return (try? JSONDecoder().decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    public func save(_ state: UpdateState) throws {
        try JSONFileSupport.write(state, to: fileURL)
    }
}
