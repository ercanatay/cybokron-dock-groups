import Foundation

/// The apps that Start, Finish and Close All never quit, and that Start and Finish never hide: the
/// user's list (Settings), plus the apps that are always protected — this app and its standalone
/// groups' apps — and Finder, which is never quit. Protection only ever leaves an app alone, so
/// a list from a groups file or a backup can't make anything run.
public struct ProtectedApps: Hashable, Sendable {
    /// The most apps the list keeps.
    public static let maximumCount = 50
    /// This app's bundle identifier: a second copy of it is never quit either.
    public static let hostBundleIdentifier = "com.cybokron.dockgroups"
    /// Never quit, though it may be hidden ("Hide all other apps").
    public static let finderBundleIdentifier = "com.apple.finder"

    /// What protection is asked about.
    public enum Action: Hashable, Sendable {
        case hiding, quitting
    }

    /// Why an app is left alone.
    public enum Reason: Hashable, Sendable {
        /// It's in the user's list.
        case listed
        /// It's this app, one of its standalone groups' apps, or — when quitting — Finder.
        case always
    }

    /// Apps only, identified as group apps are (bundle identifier, or bundle location for an app
    /// without one), each once, in the order they were added.
    public private(set) var apps: [GroupItem]
    private var identities: Set<String>

    /// Keeps apps only — not websites, files, folders or items that couldn't be read — each once
    /// (ignoring case), and at most `maximumCount` of them. An app's location is kept only when
    /// it's an app bundle path, and an item's details are dropped.
    public init(_ apps: [GroupItem] = []) {
        var kept: [GroupItem] = []
        var seen = Set<String>()
        for app in apps where kept.count < Self.maximumCount {
            guard app.kind == .application, Self.isAppIdentity(app.bundleIdentifier),
                  seen.insert(app.normalizedBundleIdentifier).inserted
            else { continue }
            let path = app.path.flatMap { FileLocation.isAppBundlePath($0) ? $0 : nil }
            kept.append(GroupItem(bundleIdentifier: app.bundleIdentifier, name: app.name, path: path))
        }
        self.apps = kept
        identities = seen
    }

    public var isEmpty: Bool { apps.isEmpty }

    /// Whether the user's list has the app with this identity (`AppReference.normalizedBundleIdentifier`
    /// or `RunningAppSnapshot.identity`), ignoring case.
    public func lists(identity: String) -> Bool {
        identities.contains(identity.lowercased())
    }

    /// Why the app with this identity is left alone when it would be hidden or quit, or `nil`
    /// when it may be.
    public func reason(forIdentity identity: String, action: Action) -> Reason? {
        let identity = identity.lowercased()
        if Self.isAlwaysProtected(identity: identity, action: action) { return .always }
        return identities.contains(identity) ? .listed : nil
    }

    /// Whether the app with this identity is left alone when it would be hidden or quit.
    public func protects(identity: String, from action: Action) -> Bool {
        reason(forIdentity: identity, action: action) != nil
    }

    public func protects(_ app: RunningAppSnapshot, from action: Action) -> Bool {
        protects(identity: app.identity, from: action)
    }

    /// This app and its standalone groups' apps, whatever is asked; Finder when quitting.
    public static func isAlwaysProtected(identity: String, action: Action) -> Bool {
        let identity = identity.lowercased()
        if identity == hostBundleIdentifier || identity.hasPrefix(AgentIdentity.bundleIdentifierPrefix) { return true }
        return action == .quitting && identity == finderBundleIdentifier
    }

    /// The listed apps that are in `group`, as a standalone group's own app needs them: its Close
    /// All only reaches the group's apps, and its configuration then doesn't change when other
    /// apps are protected or unprotected.
    public func restricted(to group: DockGroup) -> ProtectedApps {
        let members = Set(group.apps.filter { $0.kind == .application }.map(\.normalizedBundleIdentifier))
        return ProtectedApps(apps.filter { members.contains($0.normalizedBundleIdentifier) })
    }

    /// A bundle identifier (no "/" or ":") or the location of an app bundle.
    private static func isAppIdentity(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        if identifier.hasPrefix("/") { return FileLocation.isAppBundlePath(identifier) }
        return !identifier.contains("/") && !identifier.contains(":")
    }
}

extension ProtectedApps: Codable {
    /// An array of apps as groups store them (`bundleIdentifier`, `name`, `path`). Each is read on
    /// its own: an unreadable one is left out, and the rest is cleaned up as `init` does.
    public init(from decoder: Decoder) throws {
        let elements = try [Element](from: decoder)
        self.init(elements.compactMap(\.app))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apps)
    }

    /// One element of the array, `nil` when it isn't a readable item.
    private struct Element: Decodable {
        let app: GroupItem?

        init(from decoder: Decoder) throws {
            app = try? GroupItem(from: decoder)
        }
    }
}
