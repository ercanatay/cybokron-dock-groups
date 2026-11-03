import Foundation
import Testing
@testable import DockGroupsCore

/// What the interface reads about an application trigger's approval: the state each saved record
/// shows as, which actions the editor may offer for a draft, and when it can be saved.
@Suite("Application identity presentation")
@MainActor
struct TriggerApplicationIdentityPresentationTests {
    private static let group = UUID(uuidString: "7A1660E0-0000-4000-8000-0000000000B1")!
    nonisolated private static let bundle = "com.example.App"
    private let calendar = Calendar(identifier: .gregorian)

    private func appTrigger(_ action: TriggerAction = .showPopup, bundle: String = Self.bundle, identity: ApplicationIdentityAuthorization?) -> GroupTrigger {
        var trigger = GroupTrigger(groupID: Self.group, event: .applicationPresence(bundleIdentifier: bundle, edge: .starts), action: action, runMode: .immediately)
        if let identity { trigger.applicationIdentity = identity }
        return trigger
    }

    private func newApplicationDraft() -> TriggerDraft {
        var draft = TriggerDraft(calendar: calendar)
        draft.setWhen(.application(.starts))
        let selected = draft.selectApplication(AppReference(bundleIdentifier: Self.bundle, name: "App"))
        #expect(selected)
        return draft
    }

    // MARK: - States

    @Test func eachRecordShowsAsItsState() {
        #expect(appTrigger(identity: .unverified).applicationIdentityState == .unverified)
        #expect(appTrigger(identity: .needsReapproval(.fixture(Self.bundle))).applicationIdentityState == .needsReapproval)
        #expect(appTrigger(identity: .invalid(.null)).applicationIdentityState == .invalid)
        // A record for another identifier is invalid, whatever it claims.
        #expect(appTrigger(identity: .authorize(.fixture("com.example.Other"))).applicationIdentityState == .invalid)
        // Authorized, but the app's verifier never confirms the running code: nothing runs, and the
        // interface says verification isn't available rather than "approved".
        #expect(appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle))).applicationIdentityState == .verificationUnavailable)
        #expect(UnavailableApplicationIdentityVerifier().verdict(for: .fixture(Self.bundle)) == .unavailable)
    }

    // MARK: - Signature

    @Test func anAuthorizedTriggerTellsHowItsCodeWasSigned() {
        let kinds: [(ApplicationIdentityBinding.SignatureKind, TriggerApplicationSignature)] = [
            (.apple, .apple), (.appStore, .appStore), (.developerID, .developerID), (.adHoc, .adHoc),
        ]
        #expect(kinds.count == ApplicationIdentityBinding.SignatureKind.allCases.count)
        for (kind, expected) in kinds {
            let trigger = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle, signature: kind)))
            #expect(trigger.approvedApplicationSignature == expected)
        }
        // Only a certificate-backed signature verifies who made the app.
        #expect(TriggerApplicationSignature.allCases.filter { !$0.verifiesDeveloper } == [.adHoc])
    }

    @Test func onlyAnAuthorizedTriggerHasASignature() {
        #expect(appTrigger(identity: .unverified).approvedApplicationSignature == nil)
        #expect(appTrigger(identity: nil).approvedApplicationSignature == nil)
        #expect(appTrigger(identity: .needsReapproval(.fixture(Self.bundle, signature: .apple))).approvedApplicationSignature == nil)
        #expect(appTrigger(identity: .invalid(.null)).approvedApplicationSignature == nil)
        // Authorized for another identifier: invalid, so nothing is told.
        #expect(appTrigger(identity: .authorize(.fixture("com.example.Other", signature: .apple))).approvedApplicationSignature == nil)
        #expect(GroupTrigger(groupID: Self.group, event: .login, action: .start).approvedApplicationSignature == nil)
    }

    @Test func anUnknownSignatureTypeTellsNothing() {
        let record = ApplicationIdentityAuthorization(json: .object([
            "status": .string("authorized"),
            "identifier": .string(Self.bundle),
            "cdhash": .string(String(repeating: "ab", count: 20)),
            "signature": .string("enterprise"),
            "authorizedAt": .integer(1_793_000_000),
        ]))
        #expect(record.status == .invalid)
        let trigger = appTrigger(.openAll, identity: record)
        #expect(trigger.applicationIdentityState == .invalid)
        #expect(trigger.approvedApplicationSignature == nil)
        // The same record with a known type is authorized and tells it.
        let known = ApplicationIdentityAuthorization(json: .object([
            "status": .string("authorized"),
            "identifier": .string(Self.bundle),
            "cdhash": .string(String(repeating: "ab", count: 20)),
            "signature": .string("adHoc"),
            "authorizedAt": .integer(1_793_000_000),
        ]))
        #expect(appTrigger(.openAll, identity: known).approvedApplicationSignature == .adHoc)
    }

    @Test func otherEventsHaveNoState() {
        #expect(GroupTrigger(groupID: Self.group, event: .login, action: .start).applicationIdentityState == nil)
        #expect(GroupTrigger(groupID: Self.group, event: .screensSleep, action: .finish).applicationIdentityState == nil)
    }

    @Test func onlyAnUnverifiedTriggerIsLimitedToShowPopup() {
        for action in TriggerAction.allCases {
            #expect(TriggerApplicationIdentityState.unverified.permits(action) == (action == .showPopup))
            for state in [TriggerApplicationIdentityState.needsReapproval, .invalid, .verificationUnavailable] {
                #expect(state.permits(action))
            }
        }
        #expect(!TriggerApplicationIdentityState.unverified.blocksEveryAction)
        #expect(TriggerApplicationIdentityState.allCases.filter(\.blocksEveryAction) == [.needsReapproval, .invalid, .verificationUnavailable])
    }

    @Test func newerVersionsTriggersAreToldApart() {
        #expect(!appTrigger(identity: .unverified).isFromNewerVersion)
        #expect(GroupTrigger(groupID: Self.group, event: .unsupported(.object(["kind": .string("future")])), action: .start).isFromNewerVersion)
    }

    // MARK: - Editor

    @Test func aNewApplicationTriggerOffersOnlyShowPopup() {
        var draft = newApplicationDraft()
        #expect(draft.applicationIdentityState(replacing: nil) == .unverified)
        #expect(draft.allowedActions == TriggerAction.allCases)
        #expect(TriggerAction.allCases.filter { draft.permitsAction($0, replacing: nil) } == [.showPopup])
        // The event's default action (Start) can't be saved; Show Popup can.
        #expect(draft.action == .start)
        #expect(draft.isValid)
        #expect(!draft.canBeSaved(replacing: nil))
        draft.setAction(.showPopup)
        #expect(draft.canBeSaved(replacing: nil))
        let saved = draft.trigger(groupID: Self.group)
        #expect(saved.applicationIdentityState == .unverified)
        #expect(!saved.isEnabled)
    }

    @Test func anOlderUnverifiedTriggerWithAnotherActionMustSwitchToShowPopup() throws {
        let existing = appTrigger(.openAll, identity: .unverified)
        let draft = try #require(TriggerDraft(editing: existing, calendar: calendar))
        #expect(draft.action == .openAll)
        #expect(draft.applicationIdentityState(replacing: existing) == .unverified)
        #expect(!draft.permitsAction(.openAll, replacing: existing))
        #expect(!draft.canBeSaved(replacing: existing))
    }

    @Test func editingKeepsTheStateOfTheSameApp() throws {
        for (identity, state) in [
            (ApplicationIdentityAuthorization.needsReapproval(.fixture(Self.bundle)), TriggerApplicationIdentityState.needsReapproval),
            (.authorize(.fixture(Self.bundle)), .verificationUnavailable),
        ] {
            let existing = appTrigger(.openAll, identity: identity)
            let draft = try #require(TriggerDraft(editing: existing, calendar: calendar))
            #expect(draft.applicationIdentityState(replacing: existing) == state)
            // Nothing runs in these states anyway: the chosen action is kept for later.
            #expect(TriggerAction.allCases.allSatisfy { draft.permitsAction($0, replacing: existing) })
            #expect(draft.canBeSaved(replacing: existing))
        }
    }

    @Test func choosingAnotherAppMakesTheTriggerUnverified() throws {
        let existing = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        var draft = try #require(TriggerDraft(editing: existing, calendar: calendar))
        let selected = draft.selectApplication(AppReference(bundleIdentifier: "com.example.Other", name: "Other"))
        #expect(selected)
        #expect(draft.applicationIdentityState(replacing: existing) == .unverified)
        #expect(!draft.canBeSaved(replacing: existing))
    }

    @Test func otherEventsOfferEveryAllowedAction() {
        var draft = TriggerDraft(calendar: calendar)
        #expect(draft.applicationIdentityState(replacing: nil) == nil)
        #expect(TriggerAction.allCases.allSatisfy { draft.permitsAction($0, replacing: nil) })
        #expect(draft.canBeSaved(replacing: nil))
        draft.setKind(.screensSleep)
        #expect(!draft.permitsAction(.start, replacing: nil))
        #expect(draft.permitsAction(.finish, replacing: nil))
    }
}
