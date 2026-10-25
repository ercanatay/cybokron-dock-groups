import Foundation

/// What an app item may be when it comes from outside the app's own pickers: a backup, capturing
/// the open apps, and every addition through the store (`GroupStore.addItems`). A group opens what
/// its items point to, so an app is kept only as a bundle identifier or as the location of an app
/// bundle, and its fallback location only when that's an app bundle too; nothing else (a script,
/// a `.command` file, a folder) gets in as an app. Websites, files and folders are left to their
/// own rules (`WebsiteAddress`, `FileItemPolicy`).
public enum AppItemPolicy {
    /// Whether `identifier` can be a bundle identifier: it has no "/" or ":". Those mark an app's
    /// location, a web address or a file's location, so an app item with one is an item that
    /// couldn't be read, which would show as an app that's never found.
    public static func isBundleIdentifier(_ identifier: String) -> Bool {
        !identifier.contains { $0 == "/" || $0 == ":" }
    }

    /// `item` itself for websites, files and folders. An app identified by its location is kept
    /// only at an app bundle path (`FileLocation.isAppBundlePath`); any other app only with an
    /// identity that can be a bundle identifier, its fallback location dropped when that isn't an
    /// app bundle path (the app is still found by its bundle identifier).
    /// - Returns: The item to keep, or `nil` to leave it out.
    public static func sanitized(_ item: GroupItem) -> GroupItem? {
        guard item.kind == .application else { return item }
        if item.isIdentifiedByPath {
            guard FileLocation.isAppBundlePath(item.bundleIdentifier) else { return nil }
        } else if !isBundleIdentifier(item.bundleIdentifier) {
            return nil
        }
        var item = item
        if let path = item.path, !FileLocation.isAppBundlePath(path) {
            item.path = nil
        }
        return item
    }
}
