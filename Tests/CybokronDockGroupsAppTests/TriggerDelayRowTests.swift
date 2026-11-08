import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

@MainActor
private final class CountingHandler: AutomationHandling {
    let groups: [DockGroup]
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
    func showPopup(of group: DockGroup) {}
}

/// A trigger with a delay in the group window: its row says the delay and, while it waits, the
/// time left; the controller follows the coordinator, and archiving the group cancels the wait.
@MainActor
struct TriggerDelayRowTests {
    @Test func secondsLeftRoundUpAndStopAtZero() {
        let due = Date(timeIntervalSince1970: 1_000)
        #expect(TriggerRow.secondsLeft(until: due, now: due.addingTimeInterval(-29.2)) == 30)
        #expect(TriggerRow.secondsLeft(until: due, now: due.addingTimeInterval(-1)) == 1)
        #expect(TriggerRow.secondsLeft(until: due, now: due) == 0)
        #expect(TriggerRow.secondsLeft(until: due, now: due.addingTimeInterval(5)) == 0)
    }

    @Test func theControllerShowsTheWaitAndArchivingCancelsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-delay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let trigger = GroupTrigger(groupID: group.id, event: .screensWake, action: .openAll, runMode: .immediately, delaySeconds: 600)
        _ = store.add(trigger)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        let handler = CountingHandler(groups: [group])
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())

        controller.handleWorkspaceSignal(.screens(asleep: true))
        controller.handleWorkspaceSignal(.screens(asleep: false))
        #expect(await eventually { controller.delayedUntil[trigger.id] != nil })
        let due = try #require(controller.delayedUntil[trigger.id])
        #expect(abs(due.timeIntervalSinceNow - 600) < 30)
        #expect(handler.openAllCount == 0)

        _ = groups.archiveGroup(group.id)
        #expect(await eventually { controller.delayedUntil.isEmpty })
        #expect(controller.state.entry(for: trigger.id).lastOutcome == .skipped(.groupMissing))
        #expect(handler.openAllCount == 0)
    }

    private func eventually(within timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
