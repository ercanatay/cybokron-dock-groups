import Foundation

/// The code an application-presence rule was authorized for: its signing identifier, the exact code
/// hash (`cdhash`) of the instance the user chose and confirmed, how that code was signed and when it
/// was authorized. Built only by `ApplicationIdentityAuthorization.authorize`; read back from the
/// local triggers file. Holds no path, PID or name.
struct ApplicationIdentityBinding: Hashable, Sendable {
    /// How the authorized code was signed. Unsigned code can't be authorized, so it has no case.
    enum SignatureKind: String, CaseIterable, Sendable {
        case apple
        case appStore
        case developerID
        case adHoc
    }

    /// The signing identifier, compared exactly (case-sensitively) with the rule's bundle identifier.
    let identifier: String
    let codeHash: ApplicationCodeHash
    let signature: SignatureKind
    /// Whole seconds, so a saved binding reads back equal.
    let authorizedAt: Date

    /// `nil` for an identifier `TriggerApplicationIdentifier` refuses or a date no file can hold.
    init?(identifier: String, codeHash: ApplicationCodeHash, signature: SignatureKind, authorizedAt: Date) {
        guard TriggerApplicationIdentifier(identifier) != nil else { return nil }
        let seconds = authorizedAt.timeIntervalSince1970.rounded(.down)
        guard let date = TriggerState.date(fromSeconds: seconds) else { return nil }
        self.identifier = identifier
        self.codeHash = codeHash
        self.signature = signature
        self.authorizedAt = date
    }
}

/// Whether an application-presence rule may act, and on what grounds (see
/// `docs/design/app-presence-identity-authorization.md`):
///
/// - `authorized`: the user chose and confirmed a verified running instance on this Mac. Every
///   action the event allows, but only while the identity verifier confirms the running code
///   (`ApplicationIdentityVerifying`); without a confirmation nothing runs.
/// - `needsReapproval`: the authorized code changed (an update): nothing runs until the user
///   approves the new code. Trust is never widened automatically.
/// - `unverified`: matched by bundle identifier only. Only Show the Popup runs; other actions are
///   skipped (`TriggerSkipReason.applicationNotVerified`). Rules saved without this record (legacy,
///   imported, restored) are unverified and come in turned off.
/// - `invalid`: a record that can't be read (empty or malformed hash, unknown signature type or
///   status, unexpected keys, an identifier that isn't the rule's). Nothing runs; the record is
///   kept as read and written back unchanged.
///
/// Nothing read from a file authorizes anything by itself: imports and restores drop the record
/// (`droppingImportedIdentity`), and the coordinator asks the verifier before an authorized rule acts.
enum ApplicationIdentityAuthorization: Hashable, Sendable {
    case authorized(ApplicationIdentityBinding)
    case needsReapproval(ApplicationIdentityBinding)
    case unverified
    /// As read from the file.
    case invalid(JSONValue)

    enum Status: String, CaseIterable, Sendable {
        case authorized
        case needsReapproval
        case unverified
        case invalid
    }

    var status: Status {
        switch self {
        case .authorized: return .authorized
        case .needsReapproval: return .needsReapproval
        case .unverified: return .unverified
        case .invalid: return .invalid
        }
    }

    var binding: ApplicationIdentityBinding? {
        switch self {
        case .authorized(let binding), .needsReapproval(let binding): return binding
        case .unverified, .invalid: return nil
        }
    }

    // MARK: - Transitions

    /// The only way to `authorized`: `binding` must come from a running instance the user explicitly
    /// chose and whose code was verified on this Mac, never from a file, an import or a path.
    static func authorize(_ binding: ApplicationIdentityBinding) -> ApplicationIdentityAuthorization {
        .authorized(binding)
    }

    /// The authorized code changed: the rule waits for the user. Other states stay as they are.
    func requiringReapproval() -> ApplicationIdentityAuthorization {
        guard case .authorized(let binding) = self else { return self }
        return .needsReapproval(binding)
    }

    /// The user approved `binding` for a rule waiting for approval (or re-confirmed an authorized
    /// one); `nil` when the identifier differs: another app is a new choice, not a re-approval.
    func reapproved(with binding: ApplicationIdentityBinding) -> ApplicationIdentityAuthorization? {
        guard let current = self.binding, current.identifier == binding.identifier else { return nil }
        return .authorized(binding)
    }

    // MARK: - JSON

    private enum Key {
        static let status = "status"
        static let identifier = "identifier"
        static let codeHash = "cdhash"
        static let signature = "signature"
        static let authorizedAt = "authorizedAt"
        static let bindingKeys: Set<String> = [status, identifier, codeHash, signature, authorizedAt]
    }

    /// Strict: anything but an exact, known shape is `invalid` (kept as read).
    init(json: JSONValue) {
        guard let object = json.objectValue, let statusName = object[Key.status]?.stringValue,
              let status = Status(rawValue: statusName)
        else {
            self = .invalid(json)
            return
        }
        switch status {
        case .unverified:
            guard Set(object.keys) == [Key.status] else {
                self = .invalid(json)
                return
            }
            self = .unverified
        case .authorized, .needsReapproval:
            guard Set(object.keys) == Key.bindingKeys,
                  let identifier = object[Key.identifier]?.stringValue,
                  let hex = object[Key.codeHash]?.stringValue,
                  let codeHash = ApplicationCodeHash(hex: hex),
                  let signatureName = object[Key.signature]?.stringValue,
                  let signature = ApplicationIdentityBinding.SignatureKind(rawValue: signatureName),
                  case .integer(let seconds)? = object[Key.authorizedAt],
                  let date = TriggerState.date(fromSeconds: Double(seconds)),
                  let binding = ApplicationIdentityBinding(identifier: identifier, codeHash: codeHash, signature: signature, authorizedAt: date)
            else {
                self = .invalid(json)
                return
            }
            self = status == .authorized ? .authorized(binding) : .needsReapproval(binding)
        case .invalid:
            // Never a status a file can claim.
            self = .invalid(json)
        }
    }

    var json: JSONValue {
        switch self {
        case .unverified:
            return .object([Key.status: .string(Status.unverified.rawValue)])
        case .authorized(let binding), .needsReapproval(let binding):
            return .object([
                Key.status: .string(status.rawValue),
                Key.identifier: .string(binding.identifier),
                Key.codeHash: .string(binding.codeHash.hex),
                Key.signature: .string(binding.signature.rawValue),
                Key.authorizedAt: .integer(Int64(binding.authorizedAt.timeIntervalSince1970)),
            ])
        case .invalid(let raw):
            return raw
        }
    }
}

// MARK: - Verification

/// What the identity verifier says about the running code under an authorized rule's identifier.
enum ApplicationIdentityVerdict: Hashable, Sendable {
    /// Every running instance is the authorized code.
    case verified
    /// Different code runs under the identifier (an update or a look-alike): the rule needs approval.
    case codeChanged
    /// Can't tell (not checked yet, failed, timed out, or no verifier): nothing runs.
    case unavailable
}

/// Checks whether the code running under an authorized rule's identifier is the code it was
/// authorized for. Asked on the main actor at every check of the coordinator's chain, so an
/// implementation answers from results it already has (verification itself runs elsewhere, bounded
/// and cancellable) and must not log hashes, paths or other apps' identities.
@MainActor
protocol ApplicationIdentityVerifying: AnyObject {
    func verdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict
}

/// The production verifier until running-code verification is integrated: it never confirms
/// anything, so authorized rules don't act (fail closed) and only unverified Show the Popup rules can.
@MainActor
final class UnavailableApplicationIdentityVerifier: ApplicationIdentityVerifying {
    init() {}

    func verdict(for binding: ApplicationIdentityBinding) -> ApplicationIdentityVerdict { .unavailable }
}

/// What an application-presence rule may do right now: its saved authorization combined with the
/// verifier's verdict.
enum ApplicationIdentityClearance: Hashable, Sendable {
    case allActions
    case showPopupOnly
    case none

    func permits(_ action: TriggerAction) -> Bool {
        switch self {
        case .allActions: return true
        case .showPopupOnly: return action == .showPopup
        case .none: return false
        }
    }

    /// Fail closed: only `authorized` with a `verified` verdict clears every action; `unverified`
    /// clears Show the Popup; anything else clears nothing. Other events are not this gate's concern.
    @MainActor
    static func of(_ rule: GroupTrigger, verifier: any ApplicationIdentityVerifying) -> ApplicationIdentityClearance {
        guard let status = rule.applicationIdentityStatus else { return .allActions }
        switch status {
        case .unverified:
            return .showPopupOnly
        case .needsReapproval, .invalid:
            return .none
        case .authorized:
            guard let binding = rule.applicationIdentity?.binding else { return .none }
            return verifier.verdict(for: binding) == .verified ? .allActions : .none
        }
    }
}
