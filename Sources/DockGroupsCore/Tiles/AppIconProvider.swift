import AppKit
import UniformTypeIdentifiers

/// Supplies the icons shown for a group's items, and whether each can be found on this Mac.
@MainActor
public protocol AppIconProviding: AnyObject {
    /// The item's icon: an app's, file's or folder's own once it's been found, a globe for a
    /// website, and otherwise a generic icon of its kind (an app, a folder, or a document of its
    /// type) — drawn without looking at the disk.
    func icon(for app: AppReference) -> NSImage
    /// The item's icon given where it is (`presence`, checked by the caller): its own when it's
    /// `.available`, the generic icon of its kind otherwise.
    func icon(for item: GroupItem, presence: ItemPresence) -> NSImage
    /// Where the item is now: one check (a LaunchServices lookup, or a look at the disk for a file
    /// or folder); websites aren't checked.
    func presence(of item: GroupItem) -> ItemPresence
}

extension AppIconProviding {
    /// Whether opening the item is worth trying: an app, file or folder that's there (or that
    /// macOS didn't let the app check), or a website.
    public func isInstalled(_ app: AppReference) -> Bool {
        presence(of: app).isOpenable
    }
}

/// Icons from `NSWorkspace`, remembered per item identity. Only items that were found are
/// remembered, and an item seen missing is forgotten, so a moved, deleted or newly installed item
/// never keeps a stale icon: it shows the generic icon of its kind until it's found again.
@MainActor
public final class WorkspaceAppIconProvider: AppIconProviding {
    private let workspace: NSWorkspace
    private let locator: ItemLocating
    /// The icon of the app, file or folder at a location (a look at the disk).
    private let iconAtLocation: (URL) -> NSImage
    private var icons: [String: NSImage] = [:]

    /// - Parameter locator: Finds the items; by default a `WorkspaceItemLocator`.
    public convenience init(workspace: NSWorkspace = .shared, locator: ItemLocating? = nil) {
        self.init(workspace: workspace, locator: locator ?? WorkspaceItemLocator(workspace: workspace)) { url in
            workspace.icon(forFile: url.path)
        }
    }

    init(workspace: NSWorkspace, locator: ItemLocating, iconAtLocation: @escaping (URL) -> NSImage) {
        self.workspace = workspace
        self.locator = locator
        self.iconAtLocation = iconAtLocation
    }

    /// How many icons are remembered (for tests).
    var cachedIconCount: Int { icons.count }

    public func presence(of item: GroupItem) -> ItemPresence {
        locator.presence(of: item)
    }

    public func icon(for app: AppReference) -> NSImage {
        if app.isWebsite {
            return WebsiteIcon.image
        }
        if let icon = icons[app.normalizedBundleIdentifier] {
            return icon
        }
        return icon(for: app, presence: presence(of: app))
    }

    public func icon(for item: GroupItem, presence: ItemPresence) -> NSImage {
        if item.isWebsite {
            return WebsiteIcon.image
        }
        let key = item.normalizedBundleIdentifier
        switch presence {
        case .available(let url):
            if let icon = icons[key] {
                return icon
            }
            let icon = iconAtLocation(url)
            icons[key] = icon
            return icon
        case .unverified:
            // Not checked: an icon from before can stay, but none is read from the disk.
            return icons[key] ?? genericIcon(for: item)
        case .missing, .volumeUnavailable, .online:
            icons[key] = nil
            return genericIcon(for: item)
        }
    }

    /// The icon of the item's kind, without looking at the disk: an app's, a folder's, or that of a
    /// document of the file's type (by its extension).
    func genericIcon(for item: GroupItem) -> NSImage {
        switch item.kind {
        case .application:
            return workspace.icon(for: .applicationBundle)
        case .website:
            return WebsiteIcon.image
        case .folder:
            return workspace.icon(for: .folder)
        case .file:
            let fileExtension = item.fileURL?.pathExtension ?? ""
            let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
            return workspace.icon(for: type ?? .data)
        }
    }
}
