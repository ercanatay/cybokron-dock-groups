import Foundation

/// The second line of an item's row in the group window: what the item is or where, and whether
/// something is wrong with it, as cases the app turns into text.
public enum ItemRowStatus: Equatable, Sendable {
    /// All is well (or not checked yet): an app's bundle identifier (its location, as "~/…",
    /// when it has none), a website's address, or a file's or folder's location ("~/…").
    case identity(String)
    /// An app that isn't on this Mac, with its identity.
    case appNotFound(String)
    /// A file or folder that was moved, renamed or deleted, with where it was. It can be located.
    case missing(location: String)
    /// A file or folder on a volume that isn't connected, with the volume and the location.
    case volumeUnavailable(volume: String, location: String)
    /// macOS didn't let the app check the location (privacy settings): shown without judging it.
    case unverified(location: String)

    /// Whether the row shows a problem (in warning colors).
    public var isProblem: Bool {
        switch self {
        case .appNotFound, .missing, .volumeUnavailable: return true
        case .identity, .unverified: return false
        }
    }

    /// The status of `item` where `presence` (`nil`: not checked yet) found it.
    public init(item: GroupItem, presence: ItemPresence?, home: String = NSHomeDirectory()) {
        let identity = Self.identity(of: item, home: home)
        switch (item.kind, presence) {
        case (.website, _), (_, nil), (_, .available?), (_, .online?):
            self = .identity(identity)
        case (.application, _):
            self = .appNotFound(identity)
        case (.file, .missing?), (.folder, .missing?):
            self = .missing(location: identity)
        case (.file, .volumeUnavailable(let volume)?), (.folder, .volumeUnavailable(let volume)?):
            self = .volumeUnavailable(volume: volume, location: identity)
        case (.file, .unverified?), (.folder, .unverified?):
            self = .unverified(location: identity)
        }
    }

    /// What identifies the item to the user: an app's bundle identifier or location, a website's
    /// address, a file's or folder's location — locations in the home folder as "~/…".
    public static func identity(of item: GroupItem, home: String = NSHomeDirectory()) -> String {
        switch item.kind {
        case .website:
            return item.websiteURL?.absoluteString ?? item.bundleIdentifier
        case .application:
            return item.isIdentifiedByPath ? abbreviated(item.bundleIdentifier, home: home) : item.bundleIdentifier
        case .file, .folder:
            return item.fileURL.map { abbreviated($0.path, home: home) } ?? item.bundleIdentifier
        }
    }

    /// `path` with the home folder written "~".
    static func abbreviated(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
