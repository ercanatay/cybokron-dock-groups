import Foundation

/// Whether a group item can be found on this Mac right now.
public enum ItemPresence: Equatable, Sendable {
    /// The app, file or folder is here, at this location (symbolic links resolved).
    case available(URL)
    /// A website: it's always openable and never checked.
    case online
    /// Not where it was: moved, renamed or deleted, or no longer of its kind (a file that's now a
    /// folder). An app that isn't installed.
    case missing
    /// Its location is on the volume of this name ("/Volumes/<name>/…"), which isn't connected.
    case volumeUnavailable(name: String)
    /// macOS didn't let the app check (no permission, as for a folder protected by privacy
    /// settings): shown without judging it, as it may well be there.
    case unverified

    /// Whether opening the item is worth trying.
    public var isOpenable: Bool {
        switch self {
        case .available, .online, .unverified: return true
        case .missing, .volumeUnavailable: return false
        }
    }

    /// Where the item was found; `nil` unless it's `.available`.
    public var location: URL? {
        if case .available(let url) = self { return url }
        return nil
    }
}

/// Checks whether group items are on this Mac, and what a location is.
@MainActor
public protocol ItemLocating: AnyObject {
    /// Where the item is, or why it can't be found. Apps are looked up as `resolvedURL` does,
    /// files and folders on disk, and websites aren't checked.
    func presence(of item: GroupItem) -> ItemPresence
    /// What the file or folder at `url` is, symbolic links followed; `nil` when it can't be read.
    func typeInfo(at url: URL) -> ItemTypeInfo?
}

/// The file system calls `WorkspaceItemLocator` makes, so tests can stand in for permission
/// errors and missing volumes.
public protocol FileSystemProbing {
    /// `url` with symbolic links resolved (unchanged when there are none or it doesn't exist).
    func resolvingSymbolicLinks(in url: URL) -> URL
    /// What the item at `url` is. Throws the file system's error when it can't be read: no such
    /// file, or no permission.
    func typeInfo(at url: URL) throws -> ItemTypeInfo
    /// Whether anything exists at `path`.
    func itemExists(atPath path: String) -> Bool
}
