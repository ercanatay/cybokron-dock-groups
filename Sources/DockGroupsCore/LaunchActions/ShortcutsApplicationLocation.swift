import AppKit

/// Where the Shortcuts app is, checked the same way wherever something is handed to it: a file URL
/// of an app bundle under `/System/Applications/` whose own bundle identifier is
/// `com.apple.shortcuts`. Anything else is "not found", so nothing is ever opened with whatever
/// app happens to claim the `shortcuts` scheme.
public enum ShortcutsApplicationLocation {
    public static let bundleIdentifier = "com.apple.shortcuts"
    /// Where Shortcuts.app must be: the sealed system volume's apps.
    public static let systemApplicationsPath = "/System/Applications/"

    /// `location` when it passes every check, otherwise `nil`. `bundleIdentifierOf` reads the app
    /// bundle's own identifier.
    public static func verified(_ location: URL?, bundleIdentifierOf: (URL) -> String?) -> URL? {
        guard let location, location.isFileURL else { return nil }
        let path = location.standardizedFileURL.path
        guard path.hasPrefix(systemApplicationsPath), FileLocation.isAppBundlePath(path),
              let found = bundleIdentifierOf(location),
              found.lowercased() == bundleIdentifier
        else { return nil }
        return location
    }

    /// Shortcuts.app as LaunchServices has it, when it passes the checks.
    public static func current(workspace: NSWorkspace = .shared) -> URL? {
        verified(workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)) { Bundle(url: $0)?.bundleIdentifier }
    }
}
