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

    /// How many copies `copyAside` keeps per file and label, the new one included.
    static let keptCopies = 3

    /// Copies a file to `<name>.<label>-<timestamp>.json` next to it, leaving the original in
    /// place. The new copy and the newest earlier ones are kept, `keeping` in all (by the time and
    /// counter in their names); older copies with the same label are removed — once the new copy
    /// is in place, so a failed copy never costs the previous ones.
    /// Returns the copy's location, or `nil` when there was no file.
    static func copyAside(_ fileURL: URL, label: String, now: Date = Date(), keeping: Int = keptCopies) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let copyURL = sidecarURL(for: fileURL, label: label, now: now)
        try FileManager.default.copyItem(at: fileURL, to: copyURL)
        let folder = fileURL.deletingLastPathComponent()
        let prefix = "\(fileURL.deletingPathExtension().lastPathComponent).\(label)-"
        let earlier = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") && $0 != copyURL.lastPathComponent }
            .sorted { sidecarOrder(of: $0, prefix: prefix) > sidecarOrder(of: $1, prefix: prefix) }
        for name in earlier.dropFirst(max(keeping - 1, 0)) {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
        return copyURL
    }

    /// Where a copy named `<prefix><yyyyMMdd-HHmmss>[-<n>].json` stands, oldest first: its time,
    /// then its counter (none is 1). Names that don't follow the pattern come before all others.
    static func sidecarOrder(of name: String, prefix: String) -> SidecarOrder {
        let stem = name.dropFirst(prefix.count).dropLast(".json".count)
        let timestamp = String(stem.prefix(15))
        guard timestamp.count == 15, timestamp.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
            return SidecarOrder(timestamp: "", counter: 0)
        }
        let rest = stem.dropFirst(15)
        if rest.isEmpty { return SidecarOrder(timestamp: timestamp, counter: 1) }
        guard rest.first == "-", let counter = Int(rest.dropFirst()) else { return SidecarOrder(timestamp: "", counter: 0) }
        return SidecarOrder(timestamp: timestamp, counter: counter)
    }

    struct SidecarOrder: Comparable {
        let timestamp: String
        let counter: Int

        static func < (lhs: SidecarOrder, rhs: SidecarOrder) -> Bool {
            (lhs.timestamp, lhs.counter) < (rhs.timestamp, rhs.counter)
        }
    }

    /// `<name>.<label>-<timestamp>.json` next to `fileURL`; when that's taken (twice in the same
    /// second), `-2`, `-3` … follow the timestamp.
    static func sidecarURL(for fileURL: URL, label: String, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = fileURL.deletingLastPathComponent()
        let base = "\(fileURL.deletingPathExtension().lastPathComponent).\(label)-\(formatter.string(from: now))"
        var candidate = folder.appending(path: "\(base).json", directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base)-\(counter).json", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }
}
