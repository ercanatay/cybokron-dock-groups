import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// A process watch that never reports anything.
private final class IdleProcessWatch: ApplicationProcessWatching {
    private(set) var isClosed = false
    func poll() -> ExperimentalProcessEventWatchPollResult { isClosed ? .unknown : .idle }
    private var descriptorClosed: (@Sendable () -> Void)?
    func close() {
        guard !isClosed else { return }
        isClosed = true
        descriptorClosed?()
    }
    func startSignalling(_ handler: @escaping @MainActor () -> Void) -> Bool { !isClosed }
    func whenDescriptorClosed(_ action: @escaping @Sendable () -> Void) {
        if isClosed { action() } else { descriptorClosed = action }
    }
}

@MainActor
private final class CatchUpOpenAllCounter: AutomationHandling {
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

/// Answers every notice with Start Now, recording it (no panel is shown).
@MainActor
private final class RecordingNoticePresenter: TriggerNoticePresenting {
    private(set) var shown: [TriggerNotice] = []
    func present(_ notice: TriggerNotice) async -> TriggerNoticeAnswer {
        shown.append(notice)
        return .run
    }
    func dismiss() {}
}

/// "Run what was missed" through the app's controller (`handleWorkspaceSignal`): the reading
/// before the sleep survives the stop and the verifier's reset, the wake's fresh generation and
/// fresh check, and the first trusted reading after the wake runs the trigger once, with a notice.
@MainActor
struct TriggerControllerCatchUpTests {
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

    @Test func anAppOpenedDuringSleepRunsItsCatchUpTriggerAfterAFreshCheck() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "ef", count: 20)))
        let binding = try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: hash, signature: .developerID, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .openAll, runMode: .immediately, catchUp: true)
        trigger.applicationIdentity = .authorize(binding)
        _ = store.add(trigger)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())

        var running: [Int32] = []
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in running },
            makeWatch: { _ in IdleProcessWatch() },
            readIncarnation: { ProcessIncarnation(pid: $0, startSeconds: 1_793_000_000, startMicroseconds: 1) },
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .matching })
        )
        defer { verifier.retainOnly([]) }
        controller.coordinator.applicationIdentityVerifier = verifier
        let handler = CatchUpOpenAllCounter(groups: [group])
        controller.start(handler: handler, launchedAsLoginItem: false, launchedAt: Date())
        let presenter = RecordingNoticePresenter()
        controller.coordinator.noticePresenter = presenter
        #expect(await eventually { verifier.displayedVerdict(for: binding) == .verified })

        // Not running before the sleep: a trusted reading of verified (no) code.
        let before = controller.applicationObservationGeneration
        controller.handleApplicationSnapshot(generation: before, sequence: 100, counts: [Self.bundle: 0])
        controller.handleWorkspaceSignal(.screens(asleep: true))
        #expect(controller.coordinator.catchUpReadingCount == 1)
        #expect(!controller.isApplicationPresenceObserving)

        // Opened during the sleep; after the wake a fresh generation and a fresh check.
        running = [42]
        controller.handleWorkspaceSignal(.screens(asleep: false))
        let after = controller.applicationObservationGeneration
        #expect(after > before)
        #expect(controller.coordinator.catchUpReadingCount == 1)
        controller.handleApplicationSnapshot(generation: after, sequence: 100, counts: [Self.bundle: 1])
        #expect(controller.coordinator.catchUpReadingCount == 0)
        #expect(await eventually { handler.openAllCount == 1 })
        #expect(controller.state.entry(for: trigger.id).lastOutcome == .ran(.openAll))
        #expect(presenter.shown.count == 1)
        #expect(presenter.shown.first?.isCatchUp == true)
        #expect(presenter.shown.first?.runMode == .notice)
    }
}
