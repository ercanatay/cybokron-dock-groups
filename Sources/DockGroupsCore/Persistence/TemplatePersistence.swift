import Foundation

/// Loads and saves the templates.
public protocol TemplatePersisting {
    /// Returns the saved templates, or none when nothing has been saved yet.
    func loadTemplates() throws -> [GroupTemplate]
    func saveTemplates(_ templates: [GroupTemplate]) throws
    /// Moves saved data that couldn't be loaded out of the way so later saves don't overwrite it.
    /// Returns the new location, or `nil` when there was nothing to move.
    func preserveUnreadableData() throws -> URL?
    /// Copies the saved file next to itself before it's replaced wholesale, as restoring a backup
    /// does. Returns the copy's location, or `nil` when there's nothing saved.
    func preserveCopy(label: String) throws -> URL?
}

extension TemplatePersisting {
    public func preserveCopy(label: String) throws -> URL? { nil }
}

public enum TemplatePersistenceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return Localization.format(
                "core.persistence.templates.newer",
                "The templates file was saved by a newer version of Cybokron Dock Groups (format %ld).",
                version
            )
        }
    }
}

/// On-disk envelope of the templates: `{ "formatVersion": 1, "templates": [ … ] }`.
struct TemplatesDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var templates: [GroupTemplate]

    init(templates: [GroupTemplate]) {
        formatVersion = Self.currentFormatVersion
        self.templates = templates
    }
}

/// Stores the templates as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/templates.json`, next to the groups — a file
/// versions without templates (0.8.0 and earlier) never open, so going back and forth keeps them.
/// Nothing leaves this Mac.
public struct JSONFileTemplatePersistence: TemplatePersisting {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "templates.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileTemplatePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadTemplates() throws -> [GroupTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let document = try JSONDecoder().decode(TemplatesDocument.self, from: Data(contentsOf: fileURL))
        guard document.formatVersion <= TemplatesDocument.currentFormatVersion else {
            throw TemplatePersistenceError.unsupportedFormatVersion(document.formatVersion)
        }
        return document.templates
    }

    public func saveTemplates(_ templates: [GroupTemplate]) throws {
        try JSONFileSupport.write(TemplatesDocument(templates: templates), to: fileURL)
    }

    public func preserveUnreadableData() throws -> URL? {
        try JSONFileSupport.moveAside(fileURL)
    }

    public func preserveCopy(label: String) throws -> URL? {
        try JSONFileSupport.copyAside(fileURL, label: label)
    }
}
