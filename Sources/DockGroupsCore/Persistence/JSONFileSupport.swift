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
        let backupURL = sidecarURL(for: fileURL, label: "unreadable")
        try FileManager.default.moveItem(at: fileURL, to: backupURL)
        return backupURL
    }

    /// Copies a file to `<name>.<label>-<timestamp>.json` next to it, leaving the original in
    /// place. Only the latest copy is kept: earlier copies with the same label are removed.
    /// Returns the copy's location, or `nil` when there was no file.
    static func copyAside(_ fileURL: URL, label: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let folder = fileURL.deletingLastPathComponent()
        let prefix = "\(fileURL.deletingPathExtension().lastPathComponent).\(label)-"
        let earlier = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in earlier where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
        let copyURL = sidecarURL(for: fileURL, label: label)
        try FileManager.default.copyItem(at: fileURL, to: copyURL)
        return copyURL
    }

    private static func sidecarURL(for fileURL: URL, label: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appending(
            path: "\(baseName).\(label)-\(formatter.string(from: Date())).json",
            directoryHint: .notDirectory
        )
    }
}
