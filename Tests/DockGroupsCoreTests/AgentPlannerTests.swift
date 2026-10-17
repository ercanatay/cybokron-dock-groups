import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Agent sync and stranded agent cleanup")
struct AgentPlannerTests {
    private let directory = URL(fileURLWithPath: "/tmp/Agents", isDirectory: true)
    private let digest = "digest-1"

    private func group(_ name: String, id: UUID = UUID()) -> DockGroup {
        DockGroup(id: id, name: name, isStandalone: true)
    }

    private func desired(_ group: DockGroup, preferences: PopupPreferences = PopupPreferences()) -> DesiredAgent {
        DesiredAgent(
            configuration: AgentConfiguration(group: group, preferences: preferences),
            folderName: AgentIdentity.folderNames(for: [group])[group.id]!,
            sourceDigest: digest
        )
    }

    private func installed(_ agent: DesiredAgent, folderName: String? = nil, digest: String? = nil) -> InstalledAgent {
        InstalledAgent(
            bundleURL: directory.appending(path: folderName ?? agent.folderName, directoryHint: .isDirectory),
            bundleIdentifier: agent.bundleIdentifier,
            configuration: agent.configuration,
            sourceDigest: digest ?? agent.sourceDigest
        )
    }

    /// An agent left behind by a group that no longer exists.
    private func stranded(_ name: String) -> InstalledAgent {
        installed(desired(group(name)))
    }

    @Test func upToDateAgentNeedsNothing() {
        let agent = desired(group("Work"))
        let plan = AgentPlanner.plan(desired: [agent], installed: [installed(agent)], runningBundleIdentifiers: [])
        #expect(plan.isEmpty)
    }

    @Test func missingAgentIsBuilt() {
        let agent = desired(group("Work"))
        let plan = AgentPlanner.plan(desired: [agent], installed: [], runningBundleIdentifiers: [])
        #expect(plan.builds == [.init(agent: agent, reason: .missing, replacing: nil)])
        #expect(plan.removals.isEmpty)
    }

    @Test func changedGroupOrPreferencesRebuild() {
        let original = group("Work")
        var edited = original
        edited.emoji = "🧪"
        let plan = AgentPlanner.plan(desired: [desired(edited)], installed: [installed(desired(original))], runningBundleIdentifiers: [])
        #expect(plan.builds.map(\.reason) == [.outdated])

        let themed = desired(original, preferences: PopupPreferences(theme: .light))
        let themePlan = AgentPlanner.plan(desired: [themed], installed: [installed(desired(original))], runningBundleIdentifiers: [])
        #expect(themePlan.builds.map(\.reason) == [.outdated])
    }

    @Test func newMainAppExecutableRebuilds() {
        let agent = desired(group("Work"))
        let plan = AgentPlanner.plan(desired: [agent], installed: [installed(agent, digest: "older")], runningBundleIdentifiers: [])
        #expect(plan.builds.map(\.reason) == [.hostChanged])
    }

    @Test func renamedGroupMovesItsAgent() {
        let original = group("Work")
        var renamed = original
        renamed.name = "Office"
        let old = installed(desired(original))
        let plan = AgentPlanner.plan(desired: [desired(renamed)], installed: [old], runningBundleIdentifiers: [])
        #expect(plan.builds == [.init(agent: desired(renamed), reason: .renamed, replacing: old.bundleURL)])
        #expect(plan.removals.isEmpty)
    }

    @Test func strandedAgentIsRemovedWhenNotRunning() {
        let agent = stranded("Deleted")
        let plan = AgentPlanner.plan(desired: [], installed: [agent], runningBundleIdentifiers: [])
        #expect(plan.removals == [.init(agent: agent, reason: .noGroup)])
        #expect(plan.deferred.isEmpty)
    }

    @Test func runningStrandedAgentIsLeftUntilItQuits() {
        let agent = stranded("Deleted")
        let running: Set<String> = [agent.bundleIdentifier!.lowercased()]
        let plan = AgentPlanner.plan(desired: [], installed: [agent], runningBundleIdentifiers: running)
        #expect(plan.removals.isEmpty)
        #expect(plan.deferred == [.init(agent: agent, reason: .noGroup)])
    }

    @Test func agentOfAGroupTurnedOffIsRemovedEvenWhileRunning() {
        let agent = stranded("Turned Off")
        let plan = AgentPlanner.plan(
            desired: [],
            installed: [agent],
            runningBundleIdentifiers: [agent.bundleIdentifier!],
            quittingGroupIDs: [agent.groupID!]
        )
        #expect(plan.removals == [.init(agent: agent, reason: .noGroup)])
        #expect(plan.deferred.isEmpty)
    }

    @Test func groupThatIsNoLongerStandaloneLosesItsAgent() {
        // The group still exists but isn't standalone, so it isn't among the desired agents.
        let agent = stranded("Plain Now")
        let plan = AgentPlanner.plan(desired: [desired(group("Other"))], installed: [agent], runningBundleIdentifiers: [])
        #expect(plan.removals.map(\.reason) == [.noGroup])
        #expect(plan.builds.map(\.reason) == [.missing])
    }

    @Test func unreadableAgentIsRemoved() {
        let broken = InstalledAgent(bundleURL: directory.appending(path: "broken.app"), bundleIdentifier: nil, configuration: nil, sourceDigest: nil)
        let plan = AgentPlanner.plan(desired: [], installed: [broken], runningBundleIdentifiers: [])
        #expect(plan.removals == [.init(agent: broken, reason: .unreadable)])
    }

    @Test func groupIsTakenFromTheBundleIdentifierWhenTheConfigurationIsUnreadable() {
        let work = group("Work")
        let agent = desired(work)
        let damaged = InstalledAgent(bundleURL: directory.appending(path: agent.folderName), bundleIdentifier: agent.bundleIdentifier, configuration: nil, sourceDigest: digest)
        #expect(damaged.groupID == work.id)
        let plan = AgentPlanner.plan(desired: [agent], installed: [damaged], runningBundleIdentifiers: [])
        #expect(plan.builds.map(\.reason) == [.outdated])
        #expect(plan.removals.isEmpty)
    }

    @Test func duplicateBundlesOfAGroupKeepTheExpectedOne() {
        let agent = desired(group("Work"))
        let expected = installed(agent)
        let leftover = installed(agent, folderName: "work-old.app")
        let plan = AgentPlanner.plan(desired: [agent], installed: [leftover, expected], runningBundleIdentifiers: [])
        #expect(plan.removals == [.init(agent: leftover, reason: .duplicate)])
        #expect(plan.builds.isEmpty)
    }

    @Test func tilesDraggedOutOfTheDockAreFound() {
        let kept = UUID()
        let removed = UUID()
        let inDock: Set<String> = ["com.apple.Safari", AgentIdentity.bundleIdentifier(for: kept).lowercased()]
        #expect(AgentPlanner.groupsRemovedFromDock(standaloneGroupIDs: [kept, removed], dockBundleIdentifiers: inDock) == [removed])
        #expect(AgentPlanner.groupsRemovedFromDock(standaloneGroupIDs: [], dockBundleIdentifiers: inDock).isEmpty)
    }
}
