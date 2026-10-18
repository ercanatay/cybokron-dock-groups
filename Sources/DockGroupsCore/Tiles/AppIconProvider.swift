import AppKit
import UniformTypeIdentifiers

/// Supplies the icons shown for a group's apps.
@MainActor
public protocol AppIconProviding: AnyObject {
    /// The app's icon, or a generic app icon when the app isn't on this Mac; a globe for websites.
    func icon(for app: AppReference) -> NSImage
    /// Whether the app can be found on this Mac. Websites always can be opened.
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
        if app.isWebsite {
            return WebsiteIcon.image
        }
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
        app.isWebsite || app.resolvedURL(workspace: workspace) != nil
    }
}
