import AppKit
import UniformTypeIdentifiers

/// Supplies the icons shown for a group's apps.
@MainActor
public protocol AppIconProviding: AnyObject {
    /// The app's icon, or a generic app icon when the app isn't on this Mac.
    func icon(for app: AppReference) -> NSImage
    /// Whether the app can be found on this Mac.
    func isInstalled(_ app: AppReference) -> Bool
}

/// Icons from `NSWorkspace`, remembered per bundle identifier. Apps that can't be found aren't
/// remembered, so an app installed later gets its real icon.
@MainActor
public final class WorkspaceAppIconProvider: AppIconProviding {
    private let workspace: NSWorkspace
    private var icons: [String: NSImage] = [:]

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func icon(for app: AppReference) -> NSImage {
        let key = app.normalizedBundleIdentifier
        if let icon = icons[key] {
            return icon
        }
        guard let url = app.resolvedURL(workspace: workspace) else {
            return workspace.icon(for: .applicationBundle)
        }
        let icon = workspace.icon(forFile: url.path)
        icons[key] = icon
        return icon
    }

    public func isInstalled(_ app: AppReference) -> Bool {
        app.resolvedURL(workspace: workspace) != nil
    }

    /// Forgets the remembered icons, e.g. after apps were updated.
    public func removeAll() {
        icons.removeAll()
    }
}
