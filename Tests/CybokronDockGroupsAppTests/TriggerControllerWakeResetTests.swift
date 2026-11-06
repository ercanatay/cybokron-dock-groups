import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// A process watch that never reports anything, counted so a test can see watches re-created.
private final class CountedProcessWatch: ApplicationProcessWatching {
    private(set) var isClosed = false
    func poll() -> ExperimentalProcessEventWatchPollResult { isClosed ? .unknown : .idle }
    func close() { isClosed = true }
    /// Its wake-up never fires.
    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool { !isClosed }
}

@MainActor
private final class OpenAllCounter: AutomationHandling {
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

/// The app's controller resets the running-code verifier whenever the Mac stops or starts being
/// able to act (sleep and wake, session changes): no confirmed identity outlives the gap, watches
/// are closed and re-created, nothing runs meanwhile, and the rule acts again only after a fresh
/// check.
@MainActor
struct TriggerControllerWakeResetTests {
    private static let bundle = "com.cybokronfixture.normal"

    private func eventually(within timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func sleepAndWakeResetTheVerifierAndNothingRunsUntilCheckedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "ab", count: 20)))
        let binding = try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: hash, signature: .developerID, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .openAll, runMode: .immediately)
        trigger.applicationIdentity = .authorize(binding)
        _ = store.add(trigger)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())

        var running: [Int32] = [42]
        var watches: [CountedProcessWatch] = []
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in running },
            makeWatch: { _ in
                let watch = CountedProcessWatch()
                watches.append(watch)
                return watch
            },
            readIncarnation: { ProcessIncarnation(pid: $0, startSeconds: 1_793_000_000, startMicroseconds: 1) },
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching })
        )
        defer { verifier.retainOnly([]) }
        controller.coordinator.applicationIdentityVerifier = verifier
        let handler = OpenAllCounter(groups: [group])
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
        #expect(watches.count == 1)

        // Sleep: every confirmation and watch is dropped; nothing is observed.
        controller.handleWorkspaceSignal(.screens(asleep: true))
        #expect(verifier.resetCount == 1)
        #expect(verifier.displayedVerdict(for: binding) == nil)
        #expect(verifier.watchCount == 0)
        #expect(watches.allSatisfy { $0.isClosed })
        #expect(!controller.isApplicationPresenceObserving)

        // Wake: reset again, a new generation, the instance is watched and checked afresh.
        let asleepGeneration = controller.applicationObservationGeneration
        controller.handleWorkspaceSignal(.screens(asleep: false))
        let generation = controller.applicationObservationGeneration
        #expect(verifier.resetCount == 2)
        #expect(generation > asleepGeneration)
        #expect(controller.isApplicationPresenceObserving)
        #expect(verifier.displayedVerdict(for: binding) == .pending)
        #expect(watches.count == 2)
        // Its first snapshot (sent before the source's own) counts the running instance: a
        // baseline, not an opening.
        controller.handleApplicationSnapshot(generation: generation, sequence: 100, counts: [Self.bundle: 1])
        #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
        try await Task.sleep(for: .milliseconds(2300))
        #expect(handler.openAllCount == 0)
        #expect(controller.state.entry(for: trigger.id).lastOutcome == nil)

        // Back to normal after the fresh check: a real opening runs.
        running = []
        controller.handleApplicationSnapshot(generation: generation, sequence: 101, counts: [Self.bundle: 0])
        running = [42]
        controller.handleApplicationSnapshot(generation: generation, sequence: 102, counts: [Self.bundle: 1])
        #expect(await eventually { handler.openAllCount == 1 })
        #expect(controller.state.entry(for: trigger.id).lastOutcome == .ran(.openAll))
    }

    @Test func aSessionChangeResetsTheVerifierToo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "cd", count: 20)))
        let binding = try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: hash, signature: .appStore, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .openAll, runMode: .immediately)
        trigger.applicationIdentity = .authorize(binding)
        _ = store.add(trigger)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in [42] },
            makeWatch: { _ in CountedProcessWatch() },
            readIncarnation: { ProcessIncarnation(pid: $0, startSeconds: 1_793_000_000, startMicroseconds: 1) },
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching })
        )
        defer { verifier.retainOnly([]) }
        controller.coordinator.applicationIdentityVerifier = verifier
        controller.start(handler: OpenAllCounter(groups: [group]), launchedAsLoginItem: false, launchedAt: Date())
        #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
        controller.handleWorkspaceSignal(.session(active: false))
        #expect(verifier.resetCount == 1)
        #expect(verifier.displayedVerdict(for: binding) == nil)
        // A screen change while the session is inactive isn't a transition: no reset.
        controller.handleWorkspaceSignal(.screens(asleep: true))
        controller.handleWorkspaceSignal(.screens(asleep: false))
        #expect(verifier.resetCount == 1)
        controller.handleWorkspaceSignal(.session(active: true))
        #expect(verifier.resetCount == 2)
        #expect(verifier.displayedVerdict(for: binding) == .pending)
        #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })
    }
}
