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

@MainActor
private final class CountingPresenceHandler: AutomationHandling {
    let groups: [DockGroup]
    private(set) var popupCount = 0
    private(set) var openAllCount = 0
    init(groups: [DockGroup]) { self.groups = groups }
    func group(withID id: DockGroup.ID) -> DockGroup? { groups.first { $0.id == id } }
    var currentGroupID: DockGroup.ID? { nil }
    var currentGroupStartTrigger: TransitionTrigger? { nil }
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport? { nil }
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport? { nil }
    func openAllItems(of group: DockGroup) async -> LaunchReport {
        openAllCount += 1
        return LaunchReport(groupName: group.name, entries: [])
    }
    func showPopup(of group: DockGroup) { popupCount += 1 }
}

// MARK: - Tests

@MainActor
struct TriggerControllerPresenceTests {

    @Test func sessionPolicyDefaultsStrictAndCancelsPendingAction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let triggers = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        _ = triggers.add(GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .starts), action: .showPopup))
        let handler = CountingPresenceHandler(groups: [group])
        let controller = TriggerController(groups: groups, store: triggers, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        #expect(!controller.monitorIdentifiedAppsOnlyForSession)
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        let initialGeneration = controller.applicationObservationGeneration
        controller.handleApplicationSnapshot(generation: initialGeneration, sequence: 100, counts: ["com.cybokronfixture.normal": 0])
        controller.handleApplicationSnapshot(generation: initialGeneration, sequence: 101, counts: ["com.cybokronfixture.normal": 1])
        controller.setMonitorIdentifiedAppsOnlyForSession(true)
        #expect(controller.monitorIdentifiedAppsOnlyForSession)
        #expect(controller.applicationObservationGeneration > initialGeneration)
        let second = TriggerController(groups: groups, store: triggers, stateStore: state, loginItem: controller.loginItem, locationAccess: controller.locationAccess)
        #expect(!second.monitorIdentifiedAppsOnlyForSession)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(handler.popupCount == 0)
        let enabledGeneration = controller.applicationObservationGeneration
        controller.setMonitorIdentifiedAppsOnlyForSession(false)
        #expect(!controller.monitorIdentifiedAppsOnlyForSession)
        #expect(controller.applicationObservationGeneration > enabledGeneration)
        controller.handleWorkspaceSignal(.screens(asleep: true))
        controller.setMonitorIdentifiedAppsOnlyForSession(true)
        #expect(!controller.isApplicationPresenceObserving)
        controller.handleWorkspaceSignal(.screens(asleep: false))
        #expect(controller.isApplicationPresenceObserving)
    }

    @Test func unknownSnapshotRebaselinesBeforeNextOpening() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let triggers = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        _ = triggers.add(GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .starts), action: .showPopup))
        let handler = CountingPresenceHandler(groups: [group])
        let controller = TriggerController(groups: groups, store: triggers, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        let generation = controller.applicationObservationGeneration
        controller.handleApplicationSnapshot(generation: generation, sequence: 100, counts: ["com.cybokronfixture.normal": 0])
        controller.handleApplicationSnapshot(generation: generation, sequence: 101, counts: [:])
        controller.handleApplicationSnapshot(generation: generation, sequence: 102, counts: ["com.cybokronfixture.normal": 1])
        try await Task.sleep(for: .milliseconds(2300))
        #expect(handler.popupCount == 0)
        controller.handleApplicationSnapshot(generation: generation, sequence: 103, counts: ["com.cybokronfixture.normal": 0])
        controller.handleApplicationSnapshot(generation: generation, sequence: 104, counts: ["com.cybokronfixture.normal": 1])
        for _ in 0..<60 {
            if handler.popupCount == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(handler.popupCount == 1)
    }

    @Test func rejectedSnapshotDoesNotChangeUnknownStatus() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let triggers = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .starts), action: .showPopup)
        triggers.add(trigger)
        let controller = TriggerController(groups: groups, store: triggers, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        controller.start(handler: CountingPresenceHandler(groups: [group]), launchedAsLoginItem: false, launchedAt: Date())
        let generation = controller.applicationObservationGeneration
        let waiting = "Waiting: macOS cannot identify every running app."
        controller.handleApplicationSnapshot(generation: generation, sequence: 100, counts: [:])
        #expect(controller.statusLine(of: trigger) == waiting)
        // A snapshot with an old sequence is rejected by the tracker: still unknown.
        controller.handleApplicationSnapshot(generation: generation, sequence: 99, counts: ["com.cybokronfixture.normal": 0])
        #expect(controller.statusLine(of: trigger) == waiting)
        controller.handleApplicationSnapshot(generation: generation, sequence: 100, counts: ["com.cybokronfixture.normal": 0])
        #expect(controller.statusLine(of: trigger) == waiting)
        // The next accepted, identified snapshot clears it; a later rejected unknown one doesn't bring it back.
        controller.handleApplicationSnapshot(generation: generation, sequence: 101, counts: ["com.cybokronfixture.normal": 0])
        #expect(controller.statusLine(of: trigger) != waiting)
        controller.handleApplicationSnapshot(generation: generation, sequence: 50, counts: [:])
        #expect(controller.statusLine(of: trigger) != waiting)
    }

    @Test func syntheticSnapshotsReachFirstStartAndLastEndOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let opensGroup = groups.addGroup(named: "Opens")
        let closesGroup = groups.addGroup(named: "Closes")
        let triggers = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        _ = triggers.add(GroupTrigger(groupID: opensGroup.id, event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .starts), action: .showPopup))
        _ = triggers.add(GroupTrigger(groupID: closesGroup.id, event: .applicationPresence(bundleIdentifier: "com.cybokronfixture.normal", edge: .ends), action: .openAll, runMode: .immediately))
        let handler = CountingPresenceHandler(groups: [opensGroup, closesGroup])
        let controller = TriggerController(groups: groups, store: triggers, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        let generation = controller.applicationObservationGeneration
        #expect(controller.isApplicationPresenceObserving)
        for (offset, count) in [0, 1, 2, 1, 0].enumerated() {
            controller.handleApplicationSnapshot(generation: generation, sequence: UInt64(100 + offset), counts: ["com.cybokronfixture.normal": count])
        }
        for _ in 0..<60 {
            if handler.popupCount >= 1 && handler.openAllCount >= 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(handler.popupCount == 1)
        #expect(handler.openAllCount == 1)
    }

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

        // An unknown snapshot is visible only on runnable application rules.
        controller.handleApplicationSnapshot(generation: firstGen, sequence: 100, counts: [:])
        #expect(controller.statusLine(of: trigger) == "Waiting: macOS cannot identify every running app.")
        var disabled = trigger
        disabled.isEnabled = false
        #expect(controller.statusLine(of: disabled) != "Waiting: macOS cannot identify every running app.")
        controller.handleApplicationSnapshot(generation: firstGen - 1, sequence: 101, counts: ["com.cybokronfixture.normal": 0])
        #expect(controller.statusLine(of: trigger) == "Waiting: macOS cannot identify every running app.")
        controller.handleApplicationSnapshot(generation: firstGen, sequence: 101, counts: ["com.cybokronfixture.normal": 0])
        #expect(controller.statusLine(of: trigger) != "Waiting: macOS cannot identify every running app.")

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
