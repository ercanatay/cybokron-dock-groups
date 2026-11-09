import AppKit
import LocalAuthentication
import OSLog

/// Why apps weren't quit while "Ask for authentication before quitting apps" is on
/// (`PopupPreferences.asksForAuthenticationBeforeQuitting`). Every case quits nothing: the setting
/// fails closed (`docs/design/quit-authentication.md`).
public enum QuitAuthenticationFailure: String, Equatable, Sendable, CaseIterable {
    /// The user cancelled the prompt, or macOS or the app ended it.
    case cancelled
    /// The user didn't authenticate.
    case failed
    /// This Mac couldn't ask: no password set, nothing to authenticate with, locked out, no
    /// window to show the prompt in.
    case unavailable
    /// The request came from somewhere that can't ask: a link (and so the command line), Siri,
    /// Shortcuts or a standalone group's own app.
    case notInteractive

    /// What the user is told: nothing was quit, and why. `appName` names Cybokron Dock Groups.
    public func message(appName: String) -> String {
        switch self {
        case .cancelled, .failed, .unavailable:
            return Localization.string(
                "core.quitAuthentication.notAuthenticated",
                "Nothing was quit: authentication was cancelled, failed or isn't available on this Mac."
            )
        case .notInteractive:
            return Localization.format(
                "core.quitAuthentication.notInteractive",
                "Nothing was quit: “Ask for authentication before quitting apps” is on, and links, Siri, Shortcuts, the command line and standalone groups' own apps can't ask for it. Quit the apps from %@ itself instead.",
                appName
            )
        }
    }
}

/// What asking the device owner gave.
public enum QuitAuthenticationResult: Equatable, Sendable {
    case authenticated
    case refused(QuitAuthenticationFailure)
}

/// Asks the device owner to authenticate before apps are quit. `DeviceOwnerAuthenticator` asks
/// with LocalAuthentication; tests use a fake.
@MainActor
public protocol ApplicationAuthenticating: AnyObject {
    /// Asks once; `reason` completes the system prompt's "… is trying to <reason>." Never throws:
    /// every way it can't authenticate is a `QuitAuthenticationFailure`.
    func authenticate(reason: String) async -> QuitAuthenticationResult
}

/// The error Quit Group in Siri or Shortcuts ends with while authentication is required: nothing
/// was quit (`GroupQuitRequests.requestFromIntent`).
public struct QuitAuthenticationRefusal: Error, Equatable, Sendable {
    public let failure: QuitAuthenticationFailure

    public init(_ failure: QuitAuthenticationFailure) {
        self.failure = failure
    }
}

/// "Ask for authentication before quitting apps": whether quitting needs the device owner first,
/// and asking them. Only Close All, Force Quit, and Start and Finish when their plan quits apps
/// come here; hiding, opening and showing never do.
///
/// Only the app's own popup, menus, group window and keyboard shortcuts can ask (`interactive`).
/// Everything else — links (the command line opens links too), Siri, Shortcuts, a standalone
/// group's own app — is refused without asking (`QuitAuthenticationFailure.notInteractive`).
/// Triggers and a Focus never quit, so they never get here.
///
/// One prompt at a time: a second request while one shows gets `nil` (dropped).
@MainActor
public final class QuitAuthentication {
    private let required: () -> Bool
    private let authenticator: ApplicationAuthenticating?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "QuitAuthentication")

    /// Whether a prompt is showing.
    public private(set) var isAuthenticating = false

    /// - Parameters:
    ///   - isRequired: The setting, read at every request.
    ///   - authenticator: What asks; without one, every request that would ask is refused as
    ///     `unavailable`.
    public init(isRequired: @escaping () -> Bool, authenticator: ApplicationAuthenticating?) {
        self.required = isRequired
        self.authenticator = authenticator
    }

    /// Whether quitting needs authentication now.
    public var isRequired: Bool { required() }

    /// The system prompt's reason: “Cybokron Dock Groups is trying to quit apps.”
    public static var reason: String {
        Localization.string("core.quitAuthentication.reason", "quit apps")
    }

    /// Why a request may not quit without asking: `notInteractive` when authentication is required
    /// and the request can't ask; `nil` when it may go on (to `authenticate`, when it's required).
    public func refusalWithoutAsking(interactive: Bool) -> QuitAuthenticationFailure? {
        guard isRequired, !interactive else { return nil }
        logger.notice("Not quitting: \(QuitAuthenticationFailure.notInteractive.rawValue, privacy: .public)")
        return .notInteractive
    }

    /// Asks the device owner once. `nil` when another prompt is showing (the request is dropped).
    /// Only the result is logged: nothing about how the user authenticated.
    public func authenticate() async -> QuitAuthenticationResult? {
        guard !isAuthenticating else {
            logger.notice("Not quitting: another authentication prompt is showing")
            return nil
        }
        guard let authenticator else {
            logger.notice("Not quitting: \(QuitAuthenticationFailure.unavailable.rawValue, privacy: .public)")
            return .refused(.unavailable)
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let result = await authenticator.authenticate(reason: Self.reason)
        switch result {
        case .authenticated:
            logger.notice("Quitting: authenticated")
        case .refused(let failure):
            logger.notice("Not quitting: \(failure.rawValue, privacy: .public)")
        }
        return result
    }
}

/// `ApplicationAuthenticating` with LocalAuthentication's `.deviceOwnerAuthentication` policy:
/// Touch ID, a paired Apple Watch or the account password — macOS picks and falls back. Not the
/// biometrics-only policies: a Mac without Touch ID (or with the lid closed) couldn't quit at all,
/// and they have no password fallback. Nothing is stored: no keychain item, no secret, a new
/// `LAContext` for every request, so one authentication never covers a later quit.
@MainActor
public final class DeviceOwnerAuthenticator: ApplicationAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> QuitAuthenticationResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .refused(Self.failure(forErrorCode: error?.code))
        }
        // A menu bar app with a non-activating popup: come forward, so the prompt isn't behind
        // the app the user was in (the app's alerts do the same).
        NSApplication.shared.activate()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<QuitAuthenticationResult, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? .authenticated : .refused(Self.failure(forErrorCode: (error as NSError?)?.code)))
            }
        }
        withExtendedLifetime(context) {}
        return result
    }

    /// The failure for an `LAError` code; no code, or one that isn't an `LAError`, is `failed`.
    nonisolated public static func failure(forErrorCode code: Int?) -> QuitAuthenticationFailure {
        guard let code, let laCode = LAError.Code(rawValue: code) else { return .failed }
        switch laCode {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .cancelled
        case .authenticationFailed:
            return .failed
        default:
            // No password set, no Touch ID, no watch or companion device, locked out, no window
            // for the prompt (`notInteractive`), an invalidated context, and codes added later.
            return .unavailable
        }
    }
}
