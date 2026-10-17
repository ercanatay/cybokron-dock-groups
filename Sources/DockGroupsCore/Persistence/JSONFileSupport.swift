import Foundation

/// File handling shared by the JSON documents the app keeps in Application Support.
enum JSONFileSupport {
    /// `~/Library/Application Support/Cybokron/DockGroups`. Nothing in it leaves this Mac.
    static var directoryURL: URL {
        URL.applicationSupportDirectory.appending(components: "Cybokron", "DockGroups", directoryHint: .isDirectory)
    }

    /// Encodes `value` as pretty-printed JSON and writes it atomically, creating the folder if needed.
    static func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }

    /// Renames a file that couldn't be read to `<name>.unreadable-<timestamp>.json`, so later saves
    /// don't overwrite it. Returns the new location, or `nil` when there was no file.
    static func moveAside(_ fileURL: URL) throws -> URL? {
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
