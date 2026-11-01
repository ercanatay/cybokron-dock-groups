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
    /// Authorized for a code hash, but this version can't confirm the running code
    /// (`UnavailableApplicationIdentityVerifier` is the app's verifier), so nothing runs.
    case verificationUnavailable

    /// Whether a rule in this state may be given `action`: an unverified rule only Show the Popup.
    /// The other states run nothing at all, so the action the user chose is kept for later.
    public func permits(_ action: TriggerAction) -> Bool {
        self != .unverified || action == .showPopup
    }

    /// Whether the rule runs nothing in this state (an unverified rule runs Show the Popup).
    public var blocksEveryAction: Bool { self != .unverified }
}

extension GroupTrigger {
    /// The application-presence rule's authorization as the interface tells it; `nil` for other
    /// events. An authorized rule is `verificationUnavailable`: running-code verification isn't
    /// integrated, so the coordinator's verifier never confirms it (fail closed). Once a verifier
    /// is integrated, this has to follow its verdict.
    public var applicationIdentityState: TriggerApplicationIdentityState? {
        switch applicationIdentityStatus {
        case nil: return nil
        case .unverified?: return .unverified
        case .needsReapproval?: return .needsReapproval
        case .invalid?: return .invalid
        case .authorized?: return .verificationUnavailable
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
