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
        #expect(controller.statusLine(of: authorized) == "Doesn't run: the running app's code couldn't be confirmed as the approved version.")
        // Unverified: it can show the popup, so its last run is what the line tells.
        let unverified = trigger(.unverified, action: .showPopup)
        #expect(controller.statusLine(of: unverified) == "Not run yet.")
        for line in [waiting, invalid, authorized, unverified].map(controller.statusLine(of:)) {
            #expect(line != generic)
        }
    }

    @Test func anAuthorizedTriggerShowsItsLabelOnlyWhileItsCodeIsntConfirmed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        let state = TriggerStateStore(persistence: JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        let verifier = SetVerdictVerifier()
        controller.coordinator.applicationIdentityVerifier = verifier

        func trigger(_ identity: ApplicationIdentityAuthorization, action: TriggerAction = .openAll) -> GroupTrigger {
            var trigger = GroupTrigger(groupID: group.id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: action, runMode: .immediately)
            trigger.applicationIdentity = identity
            return trigger
        }

        let authorized = trigger(.authorize(try binding()))
        verifier.verdict = .verified
        #expect(controller.identityBadge(of: authorized) == nil)
        verifier.verdict = .pending
        #expect(controller.identityBadge(of: authorized) == nil)
        for verdict in [ApplicationIdentityVerdict.unavailable, .codeChanged, nil] {
            verifier.verdict = verdict
            #expect(controller.identityBadge(of: authorized) == .verificationUnavailable)
        }
        // The other states keep their label whatever the verifier says.
        verifier.verdict = .verified
        #expect(controller.identityBadge(of: trigger(.unverified, action: .showPopup)) == .unverified)
        #expect(controller.identityBadge(of: trigger(.needsReapproval(try binding()))) == .needsReapproval)
        #expect(controller.identityBadge(of: trigger(.invalid(.null))) == .invalid)
        #expect(controller.identityBadge(of: GroupTrigger(groupID: group.id, event: .login, action: .start)) == nil)
    }

    @Test func labelsAndTooltipsForEveryState() {
        let badges = TriggerApplicationIdentityState.allCases.map(L10n.Triggers.Identity.badge)
        #expect(badges == ["Unverified", "Needs re-approval", "Invalid", "Verification unavailable"])
        for state in TriggerApplicationIdentityState.allCases {
            let help = TriggerIdentityLabel.help(for: state)
            #expect(help.hasPrefix(L10n.Triggers.Identity.detail(state)))
            // Only where the trigger has to be approved again does it tell how; never a button. An
            // authorized one whose code can't be confirmed has nothing to approve.
            #expect(help.contains(L10n.Triggers.Identity.howToReapprove) == [.needsReapproval, .invalid].contains(state))
            #expect((L10n.Triggers.Identity.statusLine(state) == nil) == !state.blocksEveryAction)
        }
        #expect(L10n.Triggers.Identity.actionNeedsVerifiedApp("Start") == "Start (needs an approved app)")
    }

    @Test func theApprovedSignatureIsToldAndAnAdHocOneIsCalledWeaker() throws {
        let signature = L10n.Triggers.Identity.Approve.signature
        #expect(signature(.apple) == "Approved: Apple signature.")
        #expect(signature(.appStore) == "Approved: Mac App Store signature.")
        #expect(signature(.developerID) == "Approved: Developer ID signature.")
        let adHoc = try #require(signature(.adHoc))
        #expect(adHoc.hasPrefix("Ad-hoc signature"))
        #expect(adHoc.contains("doesn't verify who made the app"))
        #expect(adHoc.contains("weaker"))
        #expect(!adHoc.hasPrefix("Approved:"))
        // No approval, no label (never a made-up kind).
        #expect(signature(nil) == nil)
        let texts = TriggerApplicationSignature.allCases.compactMap(signature)
        #expect(Set(texts).count == TriggerApplicationSignature.allCases.count)

        // From the trigger: only an authorized one has a label.
        func trigger(_ identity: ApplicationIdentityAuthorization) -> GroupTrigger {
            var trigger = GroupTrigger(groupID: UUID(), event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: .openAll, runMode: .immediately)
            trigger.applicationIdentity = identity
            return trigger
        }
        #expect(signature(trigger(.authorize(try binding())).approvedApplicationSignature) == "Approved: Developer ID signature.")
        #expect(signature(trigger(.needsReapproval(try binding())).approvedApplicationSignature) == nil)
        #expect(signature(trigger(.unverified).approvedApplicationSignature) == nil)
        #expect(signature(trigger(.invalid(.null)).approvedApplicationSignature) == nil)
    }
}

/// A verifier whose last answer a test sets (`nil`: never checked).
@MainActor
private final class SetVerdictVerifier: ApplicationIdentityVerifying {
    var verdict: ApplicationIdentityVerdict?

    func verdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict { verdict ?? .unavailable }
    func displayedVerdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict? { verdict }
}
