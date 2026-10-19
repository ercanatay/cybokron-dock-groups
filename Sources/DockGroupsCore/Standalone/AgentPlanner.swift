import Foundation

/// The agent a standalone group should have.
public struct DesiredAgent: Equatable, Sendable {
    public let configuration: AgentConfiguration
    /// `<slug>.app`, from `AgentIdentity.folderNames(for:)`.
    public let folderName: String
    /// `AgentHost.executableDigest` of the main app's current executable.
    public let sourceDigest: String

    public init(configuration: AgentConfiguration, folderName: String, sourceDigest: String) {
        self.configuration = configuration
        self.folderName = folderName
        self.sourceDigest = sourceDigest
    }

    public var groupID: UUID { configuration.group.id }
    public var bundleIdentifier: String { AgentIdentity.bundleIdentifier(for: groupID) }
}

/// What has to happen for the agents directory to match the standalone groups.
public struct AgentSyncPlan: Equatable, Sendable {
    public struct Build: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            /// The group has no agent yet.
            case missing
            /// The group was renamed, so its agent moves to a new folder.
            case renamed
            /// The group or the preferences changed since the agent was built.
            case outdated
            /// The main app's executable changed (an update or a new build).
            case hostChanged
        }

        public let agent: DesiredAgent
        public let reason: Reason
        /// The agent's current bundle when it lives under another folder name; it's removed once
        /// the new bundle is in place.
        public let replacing: URL?
    }

    public struct Removal: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            /// No standalone group matches the agent (the group was deleted or turned standalone off).
            case noGroup
            /// The agent's configuration and bundle identifier can't be read.
            case unreadable
            /// Another bundle of the same group is kept.
            case duplicate
        }

        public let agent: InstalledAgent
        public let reason: Reason
    }

    public var builds: [Build] = []
    public var removals: [Removal] = []
    /// Agents that would be removed but are running; they're left alone until they quit.
    public var deferred: [Removal] = []

    public var isEmpty: Bool { builds.isEmpty && removals.isEmpty && deferred.isEmpty }
}

/// Compares the installed agents with the standalone groups. Pure, so the decisions are testable.
public enum AgentPlanner {
    /// An agent without a standalone group is *stranded* and removed — unless it's running: then it
    /// stays until it has quit, and a later pass removes it. Agents of `quittingGroupIDs`, whose
    /// groups the user turned Standalone off for or deleted, are removed even while running; the
    /// caller quits them first.
    ///
    /// - Parameter runningBundleIdentifiers: Bundle identifiers of running agents (any case).
    public static func plan(
        desired: [DesiredAgent],
        installed: [InstalledAgent],
        runningBundleIdentifiers: Set<String>,
        quittingGroupIDs: Set<UUID> = []
    ) -> AgentSyncPlan {
        var plan = AgentSyncPlan()
        let running = Set(runningBundleIdentifiers.map { $0.lowercased() })
        let desiredIDs = Set(desired.map(\.groupID))

        func remove(_ agent: InstalledAgent, _ reason: AgentSyncPlan.Removal.Reason) {
            let removal = AgentSyncPlan.Removal(agent: agent, reason: reason)
            let isRunning = agent.runningBundleIdentifier.map { running.contains($0.lowercased()) } ?? false
            let mayQuit = agent.groupID.map(quittingGroupIDs.contains) ?? false
            if isRunning, !mayQuit {
                plan.deferred.append(removal)
            } else {
                plan.removals.append(removal)
            }
        }

        var installedByGroup: [UUID: [InstalledAgent]] = [:]
        for agent in installed {
            guard let id = agent.groupID else {
                remove(agent, .unreadable)
                continue
            }
            guard desiredIDs.contains(id) else {
                remove(agent, .noGroup)
                continue
            }
            installedByGroup[id, default: []].append(agent)
        }

        for agent in desired {
            let candidates = installedByGroup[agent.groupID] ?? []
            let kept = candidates.first { $0.folderName == agent.folderName } ?? candidates.first
            for extra in candidates where extra.bundleURL != kept?.bundleURL {
                remove(extra, .duplicate)
            }
            guard let kept else {
                plan.builds.append(.init(agent: agent, reason: .missing, replacing: nil))
                continue
            }
            if kept.folderName != agent.folderName {
                plan.builds.append(.init(agent: agent, reason: .renamed, replacing: kept.bundleURL))
            } else if kept.configuration != agent.configuration {
                plan.builds.append(.init(agent: agent, reason: .outdated, replacing: nil))
            } else if kept.sourceDigest != agent.sourceDigest {
                plan.builds.append(.init(agent: agent, reason: .hostChanged, replacing: nil))
            }
        }
        return plan
    }

    /// Standalone groups whose agent tile is no longer in the Dock — the user dragged it out — so
    /// their Standalone setting should be turned off.
    ///
    /// - Parameter dockBundleIdentifiers: Bundle identifiers of the Dock's app tiles (any case);
    ///   `nil` when the Dock's list couldn't be read, and then no group counts as removed.
    public static func groupsRemovedFromDock(standaloneGroupIDs: [UUID], dockBundleIdentifiers: Set<String>?) -> [UUID] {
        guard let dockBundleIdentifiers else { return [] }
        let inDock = Set(dockBundleIdentifiers.map { $0.lowercased() })
        return standaloneGroupIDs.filter { !inDock.contains(AgentIdentity.bundleIdentifier(for: $0).lowercased()) }
    }
}
