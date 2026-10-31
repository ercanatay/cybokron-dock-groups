import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

// MARK: - Temporary directory isolation

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "dg-trigger-presence-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Fake automation handling

@MainActor
final class FakePresenceAutomationHandler: AutomationHandling {
    func group(withID id: DockGroup.ID) -> DockGroup? { nil }
    var currentGroupID: DockGroup.ID? { nil }
    var currentGroupStartTrigger: TransitionTrigger? { nil }
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport? { nil }
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport? { nil }
    func openAllItems(of group: DockGroup) async -> LaunchReport {
        LaunchReport(groupName: group.name, entries: [])
    }
    func showPopup(of group: DockGroup) {}
}

// MARK: - Tests

@MainActor
struct TriggerControllerPresenceTests {

    @Test func presenceLifecycle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groupURL = dir.appendingPathComponent("groups.json")
        let triggerURL = dir.appendingPathComponent("triggers.json")
        let stateURL = dir.appendingPathComponent("trigger-state.json")

        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupURL), saveDelay: .zero)
        let group = groups.addGroup(named: "PresenceTest")

        let triggerStore = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: triggerURL), saveDelay: .zero)
        let stateStore = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: stateURL), saveDelay: .zero)

        let trigger = GroupTrigger(
            groupID: group.id,
            event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .starts),
            action: .showPopup
        )
        triggerStore.add(trigger)

        let handler = FakePresenceAutomationHandler()
        let controller = TriggerController(
            groups: groups,
            store: triggerStore,
            stateStore: stateStore,
            loginItem: LoginItem(),
            locationAccess: LocationAccess()
        )

        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        // Allow Combine main-queue propagation for store changes
        try await Task.sleep(for: .milliseconds(150))

        #expect(controller.applicationObservationGeneration > 0)
        #expect(controller.isApplicationPresenceObserving == true)
        let firstGen = controller.applicationObservationGeneration

        // Sleep stops observations
        controller.handleWorkspaceSignal(.screens(asleep: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.isApplicationPresenceObserving == false)
        #expect(controller.applicationObservationGeneration == firstGen)

        // Wake restarts with newer generation
        controller.handleWorkspaceSignal(.screens(asleep: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.applicationObservationGeneration > firstGen)
        #expect(controller.isApplicationPresenceObserving == true)
        let wakeGen = controller.applicationObservationGeneration

        // Session inactive stops
        controller.handleWorkspaceSignal(.session(active: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.isApplicationPresenceObserving == false)

        // Session active restarts newer generation
        controller.handleWorkspaceSignal(.session(active: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.applicationObservationGeneration > wakeGen)
        #expect(controller.isApplicationPresenceObserving == true)

        // Waking the screens alone must not restart while the session is still inactive.
        controller.handleWorkspaceSignal(.screens(asleep: true))
        controller.handleWorkspaceSignal(.session(active: false))
        let inactiveGeneration = controller.applicationObservationGeneration
        controller.handleWorkspaceSignal(.screens(asleep: false))
        #expect(!controller.isApplicationPresenceObserving)
        #expect(controller.applicationObservationGeneration == inactiveGeneration)
        controller.handleWorkspaceSignal(.session(active: true))
        #expect(controller.isApplicationPresenceObserving)
        #expect(controller.applicationObservationGeneration > inactiveGeneration)

        // Disable trigger stops observations
        triggerStore.setEnabled(false, forTrigger: trigger.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.isApplicationPresenceObserving == false)

        // Re-enable restores observations for archive/rename tests
        triggerStore.setEnabled(true, forTrigger: trigger.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.isApplicationPresenceObserving == true)

        // Archive group stops observations
        groups.archiveGroup(group.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.isApplicationPresenceObserving == false)

        // Restore group restarts observations
        groups.restoreGroup(group.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.isApplicationPresenceObserving == true)

        // Rename unrelated group must not reset observations
        let other = groups.addGroup(named: "Other")
        try await Task.sleep(for: .milliseconds(150))
        let beforeRename = controller.applicationObservationGeneration
        groups.renameGroup(other.id, to: "Renamed")
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.applicationObservationGeneration == beforeRename)
        #expect(controller.isApplicationPresenceObserving == true)
    }
}
