import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// A process watch that never reports anything.
private final class QuietProcessWatch: ApplicationProcessWatching {
    private var isClosed = false
    func poll() -> ExperimentalProcessEventWatchPollResult { isClosed ? .unknown : .idle }
    func close() { isClosed = true }
}

/// The app's controller with the running-code verifier: it is the production setting, a code
/// change is saved to `triggers.json` as needing re-approval, and the status line follows the
/// verdict.
@MainActor
struct TriggerControllerIdentityVerifierTests {
    private static let bundle = "com.cybokronfixture.normal"

    private struct Fixture {
        let dir: URL
        let triggersURL: URL
        let store: TriggerStore
        let controller: TriggerController
        let trigger: GroupTrigger
        let binding: ApplicationIdentityBinding
    }

    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let triggersURL = dir.appendingPathComponent("triggers.json")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: triggersURL), saveDelay: .zero)
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "ab", count: 20)))
        let binding = try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: hash, signature: .developerID, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .openAll, runMode: .notice)
        trigger.applicationIdentity = .authorize(binding)
        _ = store.add(trigger)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        return Fixture(dir: dir, triggersURL: triggersURL, store: store, controller: controller, trigger: trigger, binding: binding)
    }

    /// Waits until `condition` holds. The ceiling is real time, as in the core tests'
    /// `eventually`, rather than a count of sleeps that a loaded runner stretches unpredictably.
    private func eventually(within timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func aCodeChangeIsSavedAsNeedingReapproval() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(f.controller.coordinator.applicationIdentityVerifier is RunningApplicationIdentityVerifier)
        let verifier = RunningApplicationIdentityVerifier(
            instances: { _ in [42] },
            makeWatch: { _ in QuietProcessWatch() },
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .different })
        )
        f.controller.coordinator.applicationIdentityVerifier = verifier
        f.controller.start(handler: FakePresenceAutomationHandler(), launchedAsLoginItem: false, launchedAt: Date())
        #expect(await eventually { f.store.trigger(withID: f.trigger.id)?.applicationIdentityStatus == .needsReapproval })
        let saved = try JSONFileTriggerPersistence(fileURL: f.triggersURL).loadTriggers()
        #expect(saved.first?.applicationIdentity == .needsReapproval(f.binding))
        let current = try #require(f.store.trigger(withID: f.trigger.id))
        #expect(f.controller.statusLine(of: current) == "Needs re-approval: the app's code changed since it was approved, so this trigger doesn't run.")
        verifier.retainOnly([])
    }

    @Test func aConfirmedTriggerShowsItsLastRun() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let unavailable = "Doesn't run: the running app's code couldn't be confirmed as the approved version."
        // Not checked yet.
        #expect(f.controller.statusLine(of: f.trigger) == unavailable)
        // Nothing runs under the identifier: confirmed without a check.
        f.controller.coordinator.applicationIdentityVerifier = RunningApplicationIdentityVerifier(
            instances: { _ in [] },
            makeWatch: { _ in QuietProcessWatch() },
            check: ApplicationRunningCodeCheck(compare: { _, _, _ in .unknown })
        )
        f.controller.start(handler: FakePresenceAutomationHandler(), launchedAsLoginItem: false, launchedAt: Date())
        #expect(f.controller.statusLine(of: f.trigger) == "Not run yet.")
        #expect(f.store.trigger(withID: f.trigger.id)?.applicationIdentityStatus == .authorized)
    }

    @Test func approvingAnUnverifiedTriggerSavesItToTheFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var unverified = GroupTrigger(groupID: f.trigger.groupID, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .showPopup, isEnabled: false)
        unverified.applicationIdentity = .unverified
        _ = f.store.add(unverified)
        #expect(f.store.trigger(withID: unverified.id)?.canApproveApplication == true)
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "cd", count: 20)))
        var running: [Int32] = []
        f.controller.applicationApprover = TriggerApplicationApprover(
            store: f.store,
            instances: { _ in running },
            makeWatch: { _ in QuietProcessWatch() },
            read: { _, _ in .identity(ApplicationRunningIdentity(codeHash: hash, signature: .appStore)) }
        )
        // Not running: nothing saved.
        #expect(await f.controller.approveApplication(ofTrigger: unverified.id) == .notRunning)
        #expect(try JSONFileTriggerPersistence(fileURL: f.triggersURL).loadTriggers().first { $0.id == unverified.id }?.applicationIdentity == .unverified)
        running = [42]
        #expect(await f.controller.approveApplication(ofTrigger: unverified.id) == .approved)
        let saved = try #require(try JSONFileTriggerPersistence(fileURL: f.triggersURL).loadTriggers().first { $0.id == unverified.id })
        #expect(saved.applicationIdentityStatus == .authorized)
        #expect(saved.applicationIdentity?.binding?.codeHash == hash)
        #expect(saved.applicationIdentity?.binding?.signature == .appStore)
        #expect(!saved.isEnabled)
        #expect(f.store.trigger(withID: unverified.id)?.canApproveApplication == false)
    }
}
