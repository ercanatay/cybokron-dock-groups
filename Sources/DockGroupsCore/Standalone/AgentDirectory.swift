import Foundation

/// An agent bundle found in the agents directory.
public struct InstalledAgent: Equatable, Sendable {
    public let bundleURL: URL
    /// The bundle's folder name, e.g. `work.app`.
    public var folderName: String { bundleURL.lastPathComponent }
    /// From the bundle's Info.plist; `nil` when it can't be read.
    public let bundleIdentifier: String?
    /// The bundle's `group-config.json`; `nil` when it's missing or unreadable.
    public let configuration: AgentConfiguration?
    /// `AgentInfoPlist.sourceDigestKey` from the Info.plist.
    public let sourceDigest: String?

    public init(bundleURL: URL, bundleIdentifier: String?, configuration: AgentConfiguration?, sourceDigest: String?) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.configuration = configuration
        self.sourceDigest = sourceDigest
    }

    /// The group the agent stands for: from its configuration, else from its bundle identifier.
    public var groupID: UUID? {
        configuration?.group.id ?? AgentIdentity.groupID(fromBundleIdentifier: bundleIdentifier)
    }

    /// The bundle identifier a running copy of the agent has.
    public var runningBundleIdentifier: String? {
        bundleIdentifier ?? groupID.map(AgentIdentity.bundleIdentifier(for:))
    }

    /// Reads the agent bundle at `bundleURL`; missing or broken parts come back as `nil`.
    public init(bundleURL: URL) {
        let layout = AgentBundleLayout(bundleURL: bundleURL)
        let info = (try? Data(contentsOf: layout.infoPlistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        self.init(
            bundleURL: bundleURL,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            configuration: try? AgentConfiguration.load(from: layout.configurationURL),
            sourceDigest: info?[AgentInfoPlist.sourceDigestKey] as? String
        )
    }
}

/// The folder holding the agents:
/// `~/Library/Application Support/Cybokron/DockGroups/Agents/<slug>.app`.
public enum AgentDirectory {
    /// Prefix of the folders agents are put together in before they're moved into place.
    static let stagingPrefix = ".staging-"

    public static var defaultURL: URL {
        JSONFileSupport.directoryURL.appending(path: "Agents", directoryHint: .isDirectory)
    }

    /// The `.app` folders in `directory`, sorted by name. Hidden entries (such as unfinished builds)
    /// and anything else are skipped; a missing directory has no agents.
    public static func scan(_ directory: URL, fileManager: FileManager = .default) -> [InstalledAgent] {
        bundleURLs(in: directory, fileManager: fileManager).map(InstalledAgent.init(bundleURL:))
    }

    static func bundleURLs(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { url in
                url.pathExtension.lowercased() == "app"
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Leftovers of builds that never finished (the app quit or crashed midway).
    public static func stagingLeftovers(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(stagingPrefix) }
    }
}
