import Foundation

/// How a group's standalone agent is named and recognized.
///
/// A standalone group gets its own small app, the *agent*: a copy of this app's executable in a
/// bundle of its own, with the group's tile as its icon. The agent's bundle identifier carries the
/// group's identifier, which is how a running copy of the executable knows it is an agent and which
/// group it stands for.
public enum AgentIdentity {
    /// Bundle identifiers of agents start with this; the group's UUID follows.
    public static let bundleIdentifierPrefix = "com.cybokron.dockgroups.agent."
    /// Name of the executable inside every agent bundle.
    public static let executableName = "Cybokron Group Agent"
    /// Folder name used when a group name has no letters or digits to build one from.
    static let fallbackFolderBase = "group"

    /// `com.cybokron.dockgroups.agent.<UUID>`.
    public static func bundleIdentifier(for groupID: UUID) -> String {
        bundleIdentifierPrefix + groupID.uuidString
    }

    /// Whether `bundleIdentifier` is an agent's (case-insensitively, as LaunchServices compares).
    public static func isAgent(bundleIdentifier: String?) -> Bool {
        groupID(fromBundleIdentifier: bundleIdentifier) != nil
    }

    /// The group an agent bundle identifier stands for; `nil` for any other identifier.
    public static func groupID(fromBundleIdentifier bundleIdentifier: String?) -> UUID? {
        guard let bundleIdentifier,
              bundleIdentifier.lowercased().hasPrefix(bundleIdentifierPrefix)
        else { return nil }
        return UUID(uuidString: String(bundleIdentifier.dropFirst(bundleIdentifierPrefix.count)))
    }

    /// The bundle folder names (`<slug>.app`) of the given groups' agents, keyed by group.
    ///
    /// The name is the group name's slug ("Çalışma Alanı" → `calisma-alani.app`). Groups whose
    /// names give no slug (a lone emoji) use `group-<id>.app`, and groups whose slugs collide all get
    /// a short piece of their identifier appended (`work-1a2b3c4d.app`), so the result doesn't depend
    /// on the order of the groups.
    public static func folderNames(for groups: [DockGroup]) -> [UUID: String] {
        let bases = groups.map { ($0.id, GroupLookup.slug(for: $0.name)) }
        var counts: [String: Int] = [:]
        for (_, base) in bases where !base.isEmpty {
            counts[base, default: 0] += 1
        }
        var names: [UUID: String] = [:]
        for (id, base) in bases {
            let stem: String
            if base.isEmpty {
                stem = "\(fallbackFolderBase)-\(shortID(id))"
            } else if counts[base, default: 0] > 1 {
                stem = "\(base)-\(shortID(id))"
            } else {
                stem = base
            }
            names[id] = "\(stem).app"
        }
        return names
    }

    /// The first eight hex digits of the identifier, lowercased.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}

/// Distributed notifications from the main app to running agents. The notification's object is the
/// group's UUID string, so each agent only hears about its own group.
public enum AgentNotification {
    /// The agent's `group-config.json` changed; `bundlePathKey` in the user info says where the agent
    /// bundle is now (it moves when the group is renamed).
    public static let configurationChanged = Notification.Name("com.cybokron.dockgroups.agent.configurationChanged")
    public static let bundlePathKey = "bundlePath"

    /// The agent bundle a `configurationChanged` notification's `bundlePathKey` names, when the
    /// agent may move there; `nil` otherwise. Any process can post a distributed notification, so
    /// the path must be an `.app` folder directly in `agentDirectory` (after resolving symbolic
    /// links and `..`), and its Info.plist must name `bundleIdentifier` — the agent's own.
    public static func acceptedBundleURL(
        fromPath path: String,
        agentDirectory: URL = AgentDirectory.defaultURL,
        bundleIdentifier: String
    ) -> URL? {
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        let bundle = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let directory = agentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.pathExtension.lowercased() == "app",
              bundle.deletingLastPathComponent().path == directory.path
        else { return nil }
        let found = InstalledAgent(bundleURL: bundle).bundleIdentifier
        guard let found, found.lowercased() == bundleIdentifier.lowercased() else { return nil }
        return bundle
    }
}
