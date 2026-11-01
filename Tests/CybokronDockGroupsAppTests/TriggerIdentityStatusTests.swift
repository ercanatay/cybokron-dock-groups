import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// The trigger lists' status line and approval label for application triggers: each state where
/// nothing runs says why (not the generic "can't run"), an unverified one keeps its last run, and
/// the tooltip tells how to use a blocked one now.
@MainActor
struct TriggerIdentityStatusTests {
    private static let bundle = "com.cybokronfixture.normal"

    private func binding() throws -> ApplicationIdentityBinding {
        let hash = try #require(ApplicationCodeHash(hex: String(repeating: "ab", count: 20)))
        return try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: hash, signature: .developerID, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000)))
    }

    @Test func statusLinesSayWhyAnApplicationTriggerDoesntRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())

        func trigger(_ identity: ApplicationIdentityAuthorization, action: TriggerAction = .openAll) -> GroupTrigger {
            var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: action, runMode: .immediately)
            trigger.applicationIdentity = identity
            return trigger
        }

        let generic = "Can't run: fix or remove it."
        let waiting = trigger(.needsReapproval(try binding()))
        #expect(controller.statusLine(of: waiting) == "Needs re-approval: the app's code changed since it was approved, so this trigger doesn't run.")
        let invalid = trigger(.invalid(.null))
        #expect(controller.statusLine(of: invalid) == "Invalid: its app approval can't be read, so this trigger doesn't run.")
        #expect(invalid.problem == generic)
        let authorized = trigger(.authorize(try binding()))
        #expect(controller.statusLine(of: authorized) == "Doesn't run: this version can't check the running app's code yet.")
        // Unverified: it can show the popup, so its last run is what the line tells.
        let unverified = trigger(.unverified, action: .showPopup)
        #expect(controller.statusLine(of: unverified) == "Not run yet.")
        for line in [waiting, invalid, authorized, unverified].map(controller.statusLine(of:)) {
            #expect(line != generic)
        }
    }

    @Test func labelsAndTooltipsForEveryState() {
        let badges = TriggerApplicationIdentityState.allCases.map(L10n.Triggers.Identity.badge)
        #expect(badges == ["Unverified", "Needs re-approval", "Invalid", "Verification unavailable"])
        for state in TriggerApplicationIdentityState.allCases {
            let help = TriggerIdentityLabel.help(for: state)
            #expect(help.hasPrefix(L10n.Triggers.Identity.detail(state)))
            // Only where nothing runs does it tell how to use the trigger now; never a button.
            #expect(help.contains(L10n.Triggers.Identity.howToReapprove) == state.blocksEveryAction)
            #expect((L10n.Triggers.Identity.statusLine(state) == nil) == !state.blocksEveryAction)
        }
        #expect(L10n.Triggers.Identity.actionNeedsVerifiedApp("Start") == "Start (needs a verified app)")
    }
}
