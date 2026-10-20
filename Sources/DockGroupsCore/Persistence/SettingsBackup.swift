import Foundation

/// Why a file couldn't be restored as a settings backup.
public enum SettingsBackupError: LocalizedError, Equatable, Sendable {
    /// The file isn't JSON, isn't one of this app's backups, or is missing required parts.
    case notABackup
    /// The backup was written by a newer version of the app, in a format this one doesn't know.
    case newerSchemaVersion(Int)
    /// The file is larger than any backup (`SettingsBackup.maximumFileSize`); it isn't read.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notABackup:
            return Localization.string("core.backup.error.notABackup", "This file isn't a Cybokron Dock Groups backup.")
        case .newerSchemaVersion(let version):
            return Localization.format("core.backup.error.newer", "This backup was made with a newer version of Cybokron Dock Groups (backup format %ld). Update the app to restore it.", version)
        case .tooLarge:
            return Localization.string("core.backup.error.tooLarge", "This file is too large to be a Cybokron Dock Groups backup.")
        }
    }
}

/// A backup of the user's groups and app-wide preferences, written by "Export Settings…" and read
/// back by "Import Settings…". The file is JSON with a `.dockgroups` extension.
///
/// Launch statistics for the Most Used list are deliberately left out: they're personal usage data
/// rebuilt on their own, not settings.
public struct SettingsBackup: Equatable, Sendable {
    /// The format this version writes and the newest one it can read.
    public static let currentSchemaVersion = 1
    /// Marks the file as this app's backup.
    public static let appIdentifier = "cybokron-dock-groups"
    public static let fileExtension = "dockgroups"
    /// The largest file Import Settings… reads: 5 MB, far more than any real backup (a few KB).
    public static let maximumFileSize = 5 * 1024 * 1024

    public var schemaVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var groups: [DockGroup]
    public var preferences: PopupPreferences

    public init(
        appVersion: String,
        exportedAt: Date = Date(),
        groups: [DockGroup],
        preferences: PopupPreferences
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.appVersion = appVersion
        // Whole seconds, as ISO 8601 keeps them, so a backup reads back equal to what was written.
        self.exportedAt = Date(timeIntervalSince1970: exportedAt.timeIntervalSince1970.rounded(.down))
        self.groups = groups
        self.preferences = preferences
    }

    /// The number of apps across all groups.
    public var appCount: Int {
        groups.reduce(0) { $0 + $1.apps.count }
    }

    /// `cybokron-dock-groups-backup-YYYY-MM-DD.dockgroups`, dated in the current time zone.
    public static func defaultFileName(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(appIdentifier)-backup-\(formatter.string(from: date)).\(fileExtension)"
    }

    // MARK: - Encoding

    /// The backup as pretty-printed JSON.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(BackupDocument(self))
    }

    /// Reads the backup file at `url`. A file larger than `maximumFileSize` is refused before it's
    /// read, and no more than that is ever read (in case it grows meanwhile).
    public static func read(from url: URL) throws -> SettingsBackup {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw SettingsBackupError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        return try decode(from: data)
    }

    /// Reads a backup, accepting only this app's backups in a format this version understands and
    /// no larger than `maximumFileSize`. App locations that can't be an app bundle are dropped
    /// (`withAppBundlePathsOnly`).
    public static func decode(from data: Data) throws -> SettingsBackup {
        guard data.count <= maximumFileSize else { throw SettingsBackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Check the header first, so a newer backup is reported as such even when the rest of it
        // has changed shape.
        guard let header = try? decoder.decode(BackupHeader.self, from: data),
              header.app == appIdentifier,
              header.schemaVersion >= 1
        else {
            throw SettingsBackupError.notABackup
        }
        guard header.schemaVersion <= currentSchemaVersion else {
            throw SettingsBackupError.newerSchemaVersion(header.schemaVersion)
        }
        guard let document = try? decoder.decode(BackupDocument.self, from: data) else {
            throw SettingsBackupError.notABackup
        }
        return SettingsBackup(document)
    }

    private init(_ document: BackupDocument) {
        schemaVersion = document.schemaVersion
        appVersion = document.appVersion
        exportedAt = document.exportedAt
        groups = document.groups.map(Self.withAppBundlePathsOnly)
        preferences = document.preferences.preferences
    }

    // MARK: - App locations

    /// Whether `path` can be where an app bundle is: an absolute path to a `.app` folder, without
    /// `.` or `..` components, NUL characters or more than `PATH_MAX` bytes. A backup is a file
    /// anyone can hand over, and a group opens what its items point to, so nothing else (a script,
    /// a `.command` file, a folder) gets in through one.
    public static func isAppBundlePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last, !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return last.count > 4 && last.lowercased().hasSuffix(".app")
    }

    /// `group` with its apps' locations checked (`isAppBundlePath`): an app identified by its
    /// location must be at an app bundle path or it's left out, and any other app's fallback
    /// location that isn't one is dropped (the app is still found by its bundle identifier).
    /// Websites have no location.
    static func withAppBundlePathsOnly(_ group: DockGroup) -> DockGroup {
        var group = group
        group.apps = group.apps.compactMap { app in
            guard !app.isWebsite else { return app }
            if app.isIdentifiedByPath, !isAppBundlePath(app.bundleIdentifier) { return nil }
            var app = app
            if let path = app.path, !isAppBundlePath(path) {
                app.path = nil
            }
            return app
        }
        group.freeLayoutSlots = DockGroup.sanitizedFreeLayoutSlots(group.freeLayoutSlots, apps: group.apps)
        return group
    }
}

// MARK: - Restoring

/// What restoring a backup would change, for the confirmation before it happens.
public struct SettingsRestoreSummary: Equatable, Sendable {
    /// Groups in the backup, and the apps they hold.
    public var groupCount: Int
    public var appCount: Int
    /// Current groups that a group of the same name in the backup takes the place of.
    public var replacedGroupCount: Int
    /// Current groups with no group of the same name in the backup; they're removed.
    public var removedGroupCount: Int
    /// Merging instead: the backup's groups that would be added, and the apps they hold…
    public var mergedGroupCount: Int
    public var mergedAppCount: Int
    /// …and the backup's groups skipped because a current group has the same name or identifier.
    public var skippedGroupCount: Int

    public init(backup: SettingsBackup, currentGroups: [DockGroup]) {
        groupCount = backup.groups.count
        appCount = backup.appCount
        let backupNames = Set(backup.groups.map(GroupStore.mergeName(of:)))
        let matching = currentGroups.filter { backupNames.contains(GroupStore.mergeName(of: $0)) }.count
        replacedGroupCount = matching
        removedGroupCount = currentGroups.count - matching
        let merged = GroupStore.groupsAddedByMerging(backup.groups, into: currentGroups)
        mergedGroupCount = merged.count
        mergedAppCount = merged.reduce(0) { $0 + $1.apps.count }
        skippedGroupCount = backup.groups.count - merged.count
    }
}

// MARK: - On-disk form

/// The fields every backup format has, read before the rest.
private struct BackupHeader: Decodable {
    var schemaVersion: Int
    var app: String
}

private struct BackupDocument: Codable {
    var schemaVersion: Int
    var app: String
    var appVersion: String
    var exportedAt: Date
    var groups: [DockGroup]
    /// Same contents as `preferences.json`.
    var preferences: PreferencesDocument

    init(_ backup: SettingsBackup) {
        schemaVersion = backup.schemaVersion
        app = SettingsBackup.appIdentifier
        appVersion = backup.appVersion
        exportedAt = backup.exportedAt
        groups = backup.groups
        preferences = PreferencesDocument(preferences: backup.preferences)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, app, appVersion, exportedAt, groups, preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        app = try container.decode(String.self, forKey: .app)
        // Informational only.
        appVersion = container.decodeLeniently(String.self, forKey: .appVersion) ?? ""
        exportedAt = container.decodeLeniently(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        groups = try container.decode([DockGroup].self, forKey: .groups)
        preferences = try container.decode(PreferencesDocument.self, forKey: .preferences)
    }
}
