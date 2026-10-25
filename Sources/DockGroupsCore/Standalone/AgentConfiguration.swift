import Foundation

/// What an agent knows about its group, stored in the agent bundle as
/// `Contents/Resources/group-config.json`: the group itself (identifier, name, emoji, apps, tile and
/// popup settings) and a snapshot of the app-wide popup preferences it falls back to.
///
/// The main app rewrites the file whenever the group or the preferences change; the agent reads
/// nothing else, so it works while the main app isn't running.
public struct AgentConfiguration: Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileName = "group-config.json"

    public var formatVersion: Int
    public var group: DockGroup
    public var preferences: PopupPreferences

    /// Settings the agent has no use for are left at their defaults, so changing them doesn't
    /// rebuild every agent: the update setting concerns the main app only, and so do the group's
    /// Start and Finish settings (agents don't start or finish groups) and its keyboard shortcut
    /// (only the main app registers shortcuts), and how capturing the open apps lists them (only the
    /// main app captures). Of the protected apps, only those in the group are kept: the agent's
    /// Close All reaches no others.
    public init(group: DockGroup, preferences: PopupPreferences) {
        formatVersion = Self.currentFormatVersion
        var group = group
        group.switching = GroupSwitching()
        group.shortcut = nil
        self.group = group
        var snapshot = preferences
        snapshot.automaticallyChecksForUpdates = PopupPreferences().automaticallyChecksForUpdates
        snapshot.protectedApps = preferences.protectedApps.restricted(to: group)
        snapshot.capture = CaptureSettings()
        self.preferences = snapshot
    }

    /// The group's popup settings: its own overrides on top of the preferences snapshot.
    public var popupSettings: PopupSettings {
        preferences.resolved(with: group.popup)
    }

    /// Pretty-printed JSON with sorted keys, so equal configurations give equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> AgentConfiguration {
        let configuration = try JSONDecoder().decode(AgentConfiguration.self, from: data)
        guard configuration.formatVersion <= currentFormatVersion else {
            throw AgentConfigurationError.unsupportedFormatVersion(configuration.formatVersion)
        }
        return configuration
    }

    public static func load(from fileURL: URL) throws -> AgentConfiguration {
        try decode(from: Data(contentsOf: fileURL))
    }
}

public enum AgentConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return Localization.format("core.agent.configuration.newer", "The group's settings were saved by a newer version of Cybokron Dock Groups (format %ld).", version)
        }
    }
}

extension AgentConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, group, preferences
    }

    /// The group is required; preferences written by another version fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        group = try container.decode(DockGroup.self, forKey: .group)
        preferences = container.decodeLeniently(PopupPreferences.self, forKey: .preferences) ?? PopupPreferences()
    }
}
