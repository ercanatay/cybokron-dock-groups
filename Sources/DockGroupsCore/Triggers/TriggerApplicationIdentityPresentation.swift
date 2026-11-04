import Foundation

/// What the interface tells about an application-presence rule's authorization
/// (`ApplicationIdentityAuthorization`, `docs/design/app-presence-identity-authorization.md`). Read
/// only: nothing here changes a rule or what it may do.
public enum TriggerApplicationIdentityState: String, CaseIterable, Sendable {
    /// Matched by bundle identifier only: off by default, and only Show the Popup runs.
    case unverified
    /// The authorized code changed: nothing runs until the user approves the new code.
    case needsReapproval
    /// The saved record can't be read: nothing runs.
    case invalid
    /// Authorized for a code hash. It runs only while the coordinator's verifier confirms the
    /// running code (`RunningApplicationIdentityVerifier` in the app); while it doesn't, nothing
    /// runs. The trigger lists show it only then (`TriggerController.identityBadge(of:)`).
    case verificationUnavailable

    /// Whether a rule in this state may be given `action`: an unverified rule only Show the Popup.
    /// The other states run nothing at all, so the action the user chose is kept for later.
    public func permits(_ action: TriggerAction) -> Bool {
        self != .unverified || action == .showPopup
    }

    /// Whether the rule runs nothing in this state (an unverified rule runs Show the Popup).
    public var blocksEveryAction: Bool { self != .unverified }
}

/// How the code an application trigger was approved for was signed
/// (`ApplicationIdentityBinding.SignatureKind`), for the editor to tell. An ad-hoc signature names
/// no developer: the approval holds the exact code only, not who made it.
public enum TriggerApplicationSignature: String, CaseIterable, Sendable {
    case apple
    case appStore
    case developerID
    case adHoc

    init(_ kind: ApplicationIdentityBinding.SignatureKind) {
        switch kind {
        case .apple: self = .apple
        case .appStore: self = .appStore
        case .developerID: self = .developerID
        case .adHoc: self = .adHoc
        }
    }

    /// Whether the signature verifies who made the app (a certificate chain to Apple).
    public var verifiesDeveloper: Bool { self != .adHoc }
}

extension GroupTrigger {
    /// How the approved code was signed; `nil` unless the trigger is authorized (unverified, waiting
    /// for re-approval, an unreadable record or one for another identifier, other events, a newer
    /// version's trigger). A record with an unknown signature type reads as invalid, so it has none.
    public var approvedApplicationSignature: TriggerApplicationSignature? {
        guard !isFromNewerVersion, applicationIdentityStatus == .authorized,
              let binding = applicationIdentity?.binding
        else { return nil }
        return TriggerApplicationSignature(binding.signature)
    }

    /// The application-presence rule's authorization as the interface tells it; `nil` for other
    /// events. An authorized rule is `verificationUnavailable` here, whatever the verifier last
    /// said: this reads the record only. What the lists show follows the verifier's verdict
    /// (`TriggerCoordinator.applicationIdentityIsUnconfirmed`).
    public var applicationIdentityState: TriggerApplicationIdentityState? {
        switch applicationIdentityStatus {
        case nil: return nil
        case .unverified?: return .unverified
        case .needsReapproval?: return .needsReapproval
        case .invalid?: return .invalid
        case .authorized?: return .verificationUnavailable
        }
    }

    /// Whether the user can approve this application trigger's app (`TriggerApplicationApprover`):
    /// one matched by bundle identifier only, or one waiting for its new code to be approved.
    public var canApproveApplication: Bool {
        guard !isFromNewerVersion else { return false }
        switch applicationIdentityStatus {
        case .unverified?, .needsReapproval?: return true
        case .authorized?, .invalid?, nil: return false
        }
    }

    /// Made by a newer version (an event or an action this one doesn't know): its own message wins.
    public var isFromNewerVersion: Bool {
        event.isUnsupported || unrecognizedAction != nil
    }
}

extension TriggerDraft {
    /// The authorization state the trigger saved from this draft would have
    /// (`trigger(groupID:replacing:)`): unverified for a new application trigger or a changed
    /// application, `existing`'s for the same application; `nil` for other events.
    public func applicationIdentityState(replacing existing: GroupTrigger?) -> TriggerApplicationIdentityState? {
        trigger(groupID: existing?.groupID ?? UUID(), replacing: existing).applicationIdentityState
    }

    /// Whether the editor may offer `action` as a choice: every action the event allows, except
    /// that an unverified application trigger only shows the popup.
    public func permitsAction(_ action: TriggerAction, replacing existing: GroupTrigger?) -> Bool {
        guard allowedActions.contains(action) else { return false }
        return applicationIdentityState(replacing: existing)?.permits(action) ?? true
    }

    /// Whether Save (or Add) is offered: a valid draft whose action its authorization lets run.
    public func canBeSaved(replacing existing: GroupTrigger?) -> Bool {
        isValid && permitsAction(action, replacing: existing)
    }
}
