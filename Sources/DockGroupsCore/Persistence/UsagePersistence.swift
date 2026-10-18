import Foundation

/// Loads and saves the usage statistics behind the Most Used list.
public protocol UsagePersisting: Sendable {
    /// The saved launch counts (keyed by lowercased bundle identifier); empty when none are saved.
    func loadLaunches() throws -> [String: AppUsage]
    /// The saved co-occurrence graph; empty when none is saved.
    func loadCooccurrence() throws -> [String: [String: Int]]
    func save(_ stats: UsageStats) throws
    /// Move a file that couldn't be loaded out of the way. Return the new location, or `nil` when
    /// there was nothing to move.
    func preserveUnreadableLaunches() throws -> URL?
    func preserveUnreadableCooccurrence() throws -> URL?
}

public enum UsagePersistenceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return Localization.format("core.persistence.usage.newer", "The usage statistics were saved by a newer version of Cybokron Dock Groups (format %ld).", version)
        }
    }
}

/// Stores the statistics as two JSON files, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/`: `usage-stats.json` with the launch counts
/// and `usage-cooccurrence.json` with the pairs of apps launched together. Nothing leaves this Mac.
public struct JSONFileUsagePersistence: UsagePersisting {
    public static var defaultLaunchesFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "usage-stats.json", directoryHint: .notDirectory)
    }

    public static var defaultCooccurrenceFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "usage-cooccurrence.json", directoryHint: .notDirectory)
    }

    public let launchesFileURL: URL
    public let cooccurrenceFileURL: URL

    public init(
        launchesFileURL: URL = JSONFileUsagePersistence.defaultLaunchesFileURL,
        cooccurrenceFileURL: URL = JSONFileUsagePersistence.defaultCooccurrenceFileURL
    ) {
        self.launchesFileURL = launchesFileURL
        self.cooccurrenceFileURL = cooccurrenceFileURL
    }

    /// Both files in `directory`, under their standard names.
    public init(directory: URL) {
        self.init(
            launchesFileURL: directory.appending(path: "usage-stats.json", directoryHint: .notDirectory),
            cooccurrenceFileURL: directory.appending(path: "usage-cooccurrence.json", directoryHint: .notDirectory)
        )
    }

    public func loadLaunches() throws -> [String: AppUsage] {
        guard FileManager.default.fileExists(atPath: launchesFileURL.path) else { return [:] }
        let document = try JSONDecoder().decode(LaunchesDocument.self, from: Data(contentsOf: launchesFileURL))
        try Self.checkFormatVersion(document.formatVersion, supported: LaunchesDocument.currentFormatVersion)
        var apps: [String: AppUsage] = [:]
        for usage in document.apps {
            let key = UsageStats.key(for: usage.app.bundleIdentifier)
            // Duplicate entries (hand-edited files) add up.
            if var existing = apps[key] {
                existing.launchCount += usage.launchCount
                existing.lastLaunchedAt = [existing.lastLaunchedAt, usage.lastLaunchedAt].compactMap { $0 }.max()
                apps[key] = existing
            } else {
                apps[key] = usage
            }
        }
        return apps
    }

    public func loadCooccurrence() throws -> [String: [String: Int]] {
        guard FileManager.default.fileExists(atPath: cooccurrenceFileURL.path) else { return [:] }
        let document = try JSONDecoder().decode(CooccurrenceDocument.self, from: Data(contentsOf: cooccurrenceFileURL))
        try Self.checkFormatVersion(document.formatVersion, supported: CooccurrenceDocument.currentFormatVersion)
        return document.pairs
    }

    public func save(_ stats: UsageStats) throws {
        try JSONFileSupport.write(LaunchesDocument(apps: Array(stats.apps.values)), to: launchesFileURL)
        try JSONFileSupport.write(CooccurrenceDocument(pairs: stats.cooccurrence), to: cooccurrenceFileURL)
    }

    public func preserveUnreadableLaunches() throws -> URL? {
        try JSONFileSupport.moveAside(launchesFileURL)
    }

    public func preserveUnreadableCooccurrence() throws -> URL? {
        try JSONFileSupport.moveAside(cooccurrenceFileURL)
    }

    private static func checkFormatVersion(_ version: Int, supported: Int) throws {
        guard version <= supported else { throw UsagePersistenceError.unsupportedFormatVersion(version) }
    }
}

// MARK: - File formats

/// `usage-stats.json`: `{"formatVersion": 1, "apps": [{"bundleIdentifier": …, "name": …, "path": …,
/// "launchCount": 3, "lastLaunchedAt": <seconds since 1970>}]}`.
struct LaunchesDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var apps: [AppUsage]

    init(apps: [AppUsage]) {
        formatVersion = Self.currentFormatVersion
        // A stable order keeps the file diffable.
        self.apps = apps.sorted { $0.app.normalizedBundleIdentifier < $1.app.normalizedBundleIdentifier }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, apps
    }

    /// The file must be a JSON object; unreadable entries are skipped instead of failing the file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = container.decodeLeniently(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        apps = (container.decodeLeniently([LenientEntry<AppUsage>].self, forKey: .apps) ?? []).compactMap(\.value)
    }
}

/// `usage-cooccurrence.json`: `{"formatVersion": 1, "pairs": {"<bundle id>": {"<bundle id>": 2}}}`.
struct CooccurrenceDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var pairs: [String: [String: Int]]

    init(pairs: [String: [String: Int]]) {
        formatVersion = Self.currentFormatVersion
        self.pairs = pairs
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, pairs
    }

    /// The file must be a JSON object; pairs that aren't positive counts are skipped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = container.decodeLeniently(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        var pairs: [String: [String: Int]] = [:]
        if let graph = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .pairs) {
            for appKey in graph.allKeys {
                guard let partners = try? graph.nestedContainer(keyedBy: AnyCodingKey.self, forKey: appKey) else { continue }
                let app = UsageStats.key(for: appKey.stringValue)
                for partnerKey in partners.allKeys {
                    let partner = UsageStats.key(for: partnerKey.stringValue)
                    guard let count = partners.decodeLeniently(Int.self, forKey: partnerKey), count > 0, partner != app else {
                        continue
                    }
                    pairs[app, default: [:]][partner, default: 0] += count
                }
            }
        }
        self.pairs = pairs
    }
}

extension AppUsage: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, path, launchCount, lastLaunchedAt
    }

    /// The bundle identifier and a positive launch count are required; the rest is optional.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let launchCount = try container.decode(Int.self, forKey: .launchCount)
        guard !bundleIdentifier.isEmpty, launchCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .launchCount,
                in: container,
                debugDescription: "Expected a bundle identifier and a positive launch count"
            )
        }
        let name = container.decodeLeniently(String.self, forKey: .name).flatMap { $0.isEmpty ? nil : $0 }
        app = AppReference(
            bundleIdentifier: bundleIdentifier,
            name: name ?? bundleIdentifier,
            path: container.decodeLeniently(String.self, forKey: .path)
        )
        self.launchCount = launchCount
        lastLaunchedAt = container.decodeLeniently(Double.self, forKey: .lastLaunchedAt)
            .map(Date.init(timeIntervalSince1970:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app.bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(app.name, forKey: .name)
        try container.encodeIfPresent(app.path, forKey: .path)
        try container.encode(launchCount, forKey: .launchCount)
        try container.encodeIfPresent(lastLaunchedAt?.timeIntervalSince1970, forKey: .lastLaunchedAt)
    }
}

/// Decodes an array element without failing the array: unreadable elements become `nil`.
private struct LenientEntry<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
