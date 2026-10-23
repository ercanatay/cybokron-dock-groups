import Foundation

/// An item of a group: an app, a website, a file or a folder. The type is still called
/// `AppReference` (and a group's items `apps`), as its JSON keys are; new code uses this name.
public typealias GroupItem = AppReference

/// What each kind of item can do, so code asks about a capability instead of naming kinds.
extension AppReference.Kind {
    /// Whether the item runs as processes: it has a running dot, Hide All and Close All act on it,
    /// its windows can be restored, and Most Used counts its launches. Apps only.
    public var hasProcess: Bool { self == .application }

    /// Whether the item lives on this Mac's disks, so it can be missing, shown in Finder, previewed
    /// with Quick Look and located again. Everything but websites.
    public var isOnDisk: Bool { self != .website }

    /// Whether the item is a file or a folder, identified by a `file://` location.
    public var isFileSystemItem: Bool { self == .file || self == .folder }
}
