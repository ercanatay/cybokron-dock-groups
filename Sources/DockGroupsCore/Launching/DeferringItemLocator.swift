import Foundation

/// The places macOS guards with its privacy settings (Files and Folders): looking at an item there
/// can make macOS ask the user whether the app may, and each standalone group's own app is asked
/// on its own (it has its own bundle identifier).
public enum ProtectedLocations {
    /// The guarded folders of the home folder: Desktop, Documents, Downloads, iCloud Drive and the
    /// cloud storage providers' folders.
    static let homeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]

    /// Whether `url` is in one of the guarded folders of `home`, or on another volume
    /// ("/Volumes/…": removable and network volumes are guarded too).
    public static func contains(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        if path.hasPrefix("/volumes/") {
            return true
        }
        let homePath = home.standardizedFileURL.path.lowercased()
        return homeFolders.contains { folder in
            let root = "\(homePath)/\(folder.lowercased())"
            return path == root || path.hasPrefix("\(root)/")
        }
    }
}

/// `ItemLocating` for a standalone group's own app: files and folders in the places macOS guards
/// (`ProtectedLocations`) aren't checked ahead of time — that could make macOS ask the user, for
/// each group's app — and show as `.unverified` until they're opened (`GroupLauncher` checks them
/// then, with its own locator). An item on a volume that isn't connected still shows as such: only
/// the volume's mount point is looked at. Everything else is checked by `base`.
@MainActor
public final class DeferringItemLocator: ItemLocating {
    private let base: ItemLocating
    private let fileSystem: FileSystemProbing
    private let home: URL

    public init(
        base: ItemLocating,
        fileSystem: FileSystemProbing = SystemFileSystemProbe(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.base = base
        self.fileSystem = fileSystem
        self.home = home
    }

    public func presence(of item: GroupItem) -> ItemPresence {
        guard item.kind.isFileSystemItem, let url = item.fileURL, ProtectedLocations.contains(url, home: home) else {
            return base.presence(of: item)
        }
        let components = url.standardizedFileURL.pathComponents
        if components.count > 3, components[1] == "Volumes", !fileSystem.itemExists(atPath: "/Volumes/\(components[2])") {
            return .volumeUnavailable(name: components[2])
        }
        return .unverified
    }

    public func typeInfo(at url: URL) -> ItemTypeInfo? {
        base.typeInfo(at: url)
    }
}
