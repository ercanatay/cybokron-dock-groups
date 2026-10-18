import AppKit

/// Finds the running instances of a group's app: by bundle identifier, or — for an app identified
/// by path (`AppReference.isIdentifiedByPath`) — by the location of its bundle.
@MainActor
public enum RunningApplicationLookup {
    /// The running instances of the app whose `AppReference.bundleIdentifier` is `identifier`.
    public static func runningApplications(identifiedBy identifier: String, workspace: NSWorkspace = .shared) -> [NSRunningApplication] {
        let app = AppReference(bundleIdentifier: identifier, name: "")
        guard app.isIdentifiedByPath else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        }
        return workspace.runningApplications.filter { pathIdentity(of: $0) == app.normalizedBundleIdentifier }
    }

    /// The identity a running app without a bundle identifier is matched by: the normalized
    /// location of its bundle. `nil` for apps that have a bundle identifier or no bundle.
    public static func pathIdentity(of application: NSRunningApplication) -> String? {
        pathIdentity(bundleIdentifier: application.bundleIdentifier, bundleURL: application.bundleURL)
    }

    /// `pathIdentity(of:)` for the given properties of a running app.
    nonisolated public static func pathIdentity(bundleIdentifier: String?, bundleURL: URL?) -> String? {
        guard bundleIdentifier == nil, let bundleURL, bundleURL.isFileURL else { return nil }
        return normalizedLocation(of: bundleURL)
    }

    /// The form in which two locations of the same bundle compare equal, as
    /// `AppReference.normalizedBundleIdentifier` holds it for apps identified by path: symbolic
    /// links resolved (`/private/var/…` becomes `/var/…`), case ignored.
    nonisolated public static func normalizedLocation(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}
