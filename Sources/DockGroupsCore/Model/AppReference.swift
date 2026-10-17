import AppKit

/// An app that belongs to a group, identified by its bundle identifier.
public struct AppReference: Identifiable, Hashable, Codable, Sendable {
    public var bundleIdentifier: String
    /// Display name captured when the app was added, shown when the app can't be found.
    public var name: String
    /// Where the app was when it was added. Only a fallback: a LaunchServices lookup by bundle
    /// identifier wins, so apps that were moved or updated keep working.
    public var path: String?

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, path: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
    }

    /// Reads the identity of the `.app` bundle at `applicationURL`.
    public init(applicationURL: URL) throws {
        let path = applicationURL.standardizedFileURL.path
        guard applicationURL.pathExtension.lowercased() == "app", let bundle = Bundle(url: applicationURL) else {
            throw AppReferenceError.notAnApplication(path: path)
        }
        guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw AppReferenceError.missingBundleIdentifier(path: path)
        }
        let infoName = ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.isEmpty }
        self.init(
            bundleIdentifier: bundleIdentifier,
            name: infoName ?? applicationURL.deletingPathExtension().lastPathComponent,
            path: path
        )
    }

    /// LaunchServices treats bundle identifiers case-insensitively; so do group membership checks.
    var normalizedBundleIdentifier: String { bundleIdentifier.lowercased() }

    /// Where the app currently lives: the LaunchServices location for its bundle identifier, or the
    /// path it was added from if that still exists. `nil` when the app isn't on this Mac.
    public func resolvedURL(workspace: NSWorkspace = .shared) -> URL? {
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }
}

public enum AppReferenceError: LocalizedError, Equatable, Sendable {
    case notAnApplication(path: String)
    case missingBundleIdentifier(path: String)

    public var errorDescription: String? {
        switch self {
        case .notAnApplication(let path):
            return "“\((path as NSString).lastPathComponent)” isn't an app."
        case .missingBundleIdentifier(let path):
            return "“\((path as NSString).lastPathComponent)” has no bundle identifier, so it can't be added to a group."
        }
    }
}
