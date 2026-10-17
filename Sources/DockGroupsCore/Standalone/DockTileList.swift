import Foundation

/// One entry of the Dock's app list (`persistent-apps` in the `com.apple.dock` preferences), kept
/// as the property list dictionary the Dock wrote so keys this app doesn't know survive a rewrite.
public typealias DockTileEntry = [String: Any]

/// Edits the Dock's app list to add, update and remove the agents' tiles. Pure functions over the
/// list; `DockTileStoring` reads and writes it.
///
/// An app tile looks like this (the Dock adds bookmark data, dates and a GUID itself):
///
///     { "tile-type" = "file-tile";
///       "tile-data" = { "bundle-identifier" = "com.cybokron.dockgroups.agent.<UUID>";
///                       "file-data" = { "_CFURLString" = "file:///…/work.app/"; "_CFURLStringType" = 15; };
///                       "file-label" = "Work"; "file-type" = 41; }; }
public enum DockTileList {
    public static let domain = "com.apple.dock"
    public static let persistentAppsKey = "persistent-apps"

    static let tileTypeKey = "tile-type"
    static let tileDataKey = "tile-data"
    static let bundleIdentifierKey = "bundle-identifier"
    static let fileDataKey = "file-data"
    static let urlStringKey = "_CFURLString"
    static let urlStringTypeKey = "_CFURLStringType"
    static let labelKey = "file-label"
    static let fileTypeKey = "file-type"
    /// Keys describing the file as the Dock last saw it; dropped when the tile moves to another file.
    static let staleFileKeys = ["book", "file-mod-date", "parent-mod-date"]
    static let fileTileType = "file-tile"
    /// `_CFURLStringType` of a `file://` URL string.
    static let fileURLStringType = 15
    /// `file-type` of applications.
    static let applicationFileType = 41

    /// A new app tile for the bundle at `bundleURL`.
    public static func makeEntry(bundleIdentifier: String, bundleURL: URL, label: String) -> DockTileEntry {
        [
            tileTypeKey: fileTileType,
            tileDataKey: [
                bundleIdentifierKey: bundleIdentifier,
                fileDataKey: fileData(for: bundleURL),
                labelKey: label,
                fileTypeKey: applicationFileType,
            ] as [String: Any],
        ]
    }

    public static func bundleIdentifier(of entry: DockTileEntry) -> String? {
        tileData(of: entry)?[bundleIdentifierKey] as? String
    }

    public static func label(of entry: DockTileEntry) -> String? {
        tileData(of: entry)?[labelKey] as? String
    }

    /// The file the tile opens.
    public static func fileURL(of entry: DockTileEntry) -> URL? {
        guard let fileData = tileData(of: entry)?[fileDataKey] as? [String: Any],
              let string = fileData[urlStringKey] as? String
        else { return nil }
        if (fileData[urlStringTypeKey] as? Int) == 0 {
            return URL(fileURLWithPath: string)
        }
        return URL(string: string)
    }

    /// Bundle identifiers of all tiles that have one.
    public static func bundleIdentifiers(in entries: [DockTileEntry]) -> Set<String> {
        Set(entries.compactMap(bundleIdentifier(of:)))
    }

    /// Bundle identifiers of the agents' tiles.
    public static func agentBundleIdentifiers(in entries: [DockTileEntry]) -> Set<String> {
        bundleIdentifiers(in: entries).filter(AgentIdentity.isAgent(bundleIdentifier:))
    }

    /// The list with a tile for the agent: an existing tile with the same bundle identifier is
    /// updated in place (it keeps its position and the Dock's other data), otherwise a new tile is
    /// appended at the end. `nil` when the list already has an up-to-date tile.
    public static func upserting(
        bundleIdentifier: String,
        bundleURL: URL,
        label: String,
        in entries: [DockTileEntry]
    ) -> [DockTileEntry]? {
        guard let index = index(ofBundleIdentifier: bundleIdentifier, in: entries) else {
            return entries + [makeEntry(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, label: label)]
        }
        return updating(at: index, bundleURL: bundleURL, label: label, in: entries)
    }

    /// The list with an existing tile updated to `bundleURL` and `label`; `nil` when there's no such
    /// tile or it's already up to date. Unlike `upserting`, never adds a tile.
    public static func updating(
        bundleIdentifier: String,
        bundleURL: URL,
        label: String,
        in entries: [DockTileEntry]
    ) -> [DockTileEntry]? {
        guard let index = index(ofBundleIdentifier: bundleIdentifier, in: entries) else { return nil }
        return updating(at: index, bundleURL: bundleURL, label: label, in: entries)
    }

    /// The list without the tiles of these bundle identifiers; `nil` when none was in it.
    public static func removing(bundleIdentifiers: Set<String>, from entries: [DockTileEntry]) -> [DockTileEntry]? {
        let removed = Set(bundleIdentifiers.map { $0.lowercased() })
        let remaining = entries.filter { entry in
            guard let identifier = bundleIdentifier(of: entry) else { return true }
            return !removed.contains(identifier.lowercased())
        }
        return remaining.count == entries.count ? nil : remaining
    }

    // MARK: - Helpers

    static func index(ofBundleIdentifier bundleIdentifier: String, in entries: [DockTileEntry]) -> Int? {
        let wanted = bundleIdentifier.lowercased()
        return entries.firstIndex { self.bundleIdentifier(of: $0)?.lowercased() == wanted }
    }

    private static func updating(at index: Int, bundleURL: URL, label: String, in entries: [DockTileEntry]) -> [DockTileEntry]? {
        var entry = entries[index]
        var data = tileData(of: entry) ?? [:]
        let movesFile = fileURL(of: entry)?.standardizedFileURL.path != bundleURL.standardizedFileURL.path
        guard movesFile || (data[labelKey] as? String) != label else { return nil }
        if movesFile {
            data[fileDataKey] = fileData(for: bundleURL)
            for key in staleFileKeys {
                data.removeValue(forKey: key)
            }
        }
        data[labelKey] = label
        entry[tileDataKey] = data
        var updated = entries
        updated[index] = entry
        return updated
    }

    private static func tileData(of entry: DockTileEntry) -> [String: Any]? {
        entry[tileDataKey] as? [String: Any]
    }

    private static func fileData(for bundleURL: URL) -> [String: Any] {
        [
            urlStringKey: URL(fileURLWithPath: bundleURL.path, isDirectory: true).absoluteString,
            urlStringTypeKey: fileURLStringType,
        ]
    }
}

/// Reads and writes the Dock's app list.
public protocol DockTileStoring: AnyObject {
    func loadPersistentApps() -> [DockTileEntry]
    func savePersistentApps(_ entries: [DockTileEntry]) throws
}

public enum DockTileStoreError: LocalizedError, Equatable, Sendable {
    case saveFailed

    public var errorDescription: String? {
        "The Dock's settings couldn't be changed."
    }
}

/// `DockTileStoring` with the Dock's own preferences (`com.apple.dock`), through CFPreferences as
/// `defaults` does. The Dock reads them when it starts, so a change shows after `DockRestarter`
/// restarts it.
public final class SystemDockTileStore: DockTileStoring {
    public init() {}

    public func loadPersistentApps() -> [DockTileEntry] {
        let domain = DockTileList.domain as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(DockTileList.persistentAppsKey as CFString, domain) as? [DockTileEntry] ?? []
    }

    public func savePersistentApps(_ entries: [DockTileEntry]) throws {
        let domain = DockTileList.domain as CFString
        CFPreferencesSetAppValue(DockTileList.persistentAppsKey as CFString, entries as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw DockTileStoreError.saveFailed }
    }
}

/// Restarts the Dock (`killall Dock`) so it reloads its app list. macOS starts it again right
/// away; windows and apps aren't affected.
///
/// The Dock keeps the icons of its tiles in a cache of its own, keyed by the tile's file, so a
/// restart alone still shows an agent's previous icon after the agent was rebuilt in place.
/// `clearingIconCache` deletes that cache first; the Dock draws every icon afresh and rebuilds it.
public struct DockRestarter: Sendable {
    private let tools: ToolRunning

    public init(tools: ToolRunning = SystemToolRunner()) {
        self.tools = tools
    }

    /// The Dock's icon cache, in the per-user cache folder.
    public static var iconCacheURL: URL? {
        SystemTools.userCacheDirectory?.appending(path: "com.apple.dock.iconcache", directoryHint: .notDirectory)
    }

    @discardableResult
    public func restart(clearingIconCache: Bool = false) async -> Bool {
        if clearingIconCache, let cache = Self.iconCacheURL {
            try? FileManager.default.removeItem(at: cache)
        }
        return (try? await tools.run(SystemTools.killall, arguments: ["Dock"]))?.succeeded ?? false
    }
}
