import AppKit

/// An app that belongs to a group, identified by its bundle identifier — or, for an app bundle that
/// has none (a script wrapper, for example), by its location.
public struct AppReference: Identifiable, Hashable, Codable, Sendable {
    /// The app's bundle identifier. An app without one is identified by the absolute path of its
    /// bundle instead (see `isIdentifiedByPath`); bundle identifiers can't contain "/", so the two
    /// kinds never collide.
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

    /// Reads the identity of the `.app` bundle at `applicationURL`. A bundle without a bundle
    /// identifier is identified by its location, with symbolic links resolved.
    public init(applicationURL: URL) throws {
        let path = applicationURL.standardizedFileURL.path
        guard applicationURL.pathExtension.lowercased() == "app", let bundle = Bundle(url: applicationURL) else {
            throw AppReferenceError.notAnApplication(path: path)
        }
        let bundleIdentifier = bundle.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let infoName = ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.isEmpty }
        self.init(
            bundleIdentifier: bundleIdentifier ?? applicationURL.resolvingSymlinksInPath().standardizedFileURL.path,
            name: infoName ?? applicationURL.deletingPathExtension().lastPathComponent,
            path: path
        )
    }

    /// Whether the app has no bundle identifier and `bundleIdentifier` holds its location instead.
    public var isIdentifiedByPath: Bool { bundleIdentifier.hasPrefix("/") }

    /// LaunchServices treats bundle identifiers case-insensitively; so do group membership checks.
    /// Locations are compared the same way, as APFS volumes ignore case by default.
    public var normalizedBundleIdentifier: String { bundleIdentifier.lowercased() }

    /// Where the app currently lives: the LaunchServices location for its bundle identifier, or the
    /// path it was added from if that still exists. `nil` when the app isn't on this Mac. Apps
    /// identified by path are only looked for there.
    public func resolvedURL(workspace: NSWorkspace = .shared) -> URL? {
        if !isIdentifiedByPath, let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let location = path ?? (isIdentifiedByPath ? bundleIdentifier : nil),
           FileManager.default.fileExists(atPath: location) {
            return URL(fileURLWithPath: location, isDirectory: true)
        }
        return nil
    }
}

public enum AppReferenceError: LocalizedError, Equatable, Sendable {
    case notAnApplication(path: String)

    public var errorDescription: String? {
        switch self {
        case .notAnApplication(let path):
            return "“\((path as NSString).lastPathComponent)” isn't an app."
        }
    }
}
