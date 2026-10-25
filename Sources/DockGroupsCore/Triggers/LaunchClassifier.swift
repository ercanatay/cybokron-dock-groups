import Foundation

/// How a launch counts for triggers (triggers spec §2.5, TS-3, TS-4), from what the app saw while
/// it settled:
///
/// - A link, a document or a Siri or Shortcuts request during the launch makes it quiet: the app
///   was opened to do that, not to start the user's day. (TS-4: such a launch delivers its URL
///   before `applicationDidFinishLaunching`, and macOS then says it wasn't a default launch.)
/// - A launch as a login item (the open-application event says so) or within `loginWindow` of the
///   console login session's start is a login, identified by that session's start, so At Login runs
///   once per session.
/// - Anything else is a normal launch. The quiet-launch marker an update or a language restart
///   leaves comes on top (`TriggerCoordinator.launchKind`).
public enum LaunchClassifier {
    /// How soon after the login session began a launch still counts as at login.
    public static let loginWindow: TimeInterval = 5 * 60

    public static func kind(launchedAsLoginItem: Bool, consoleSessionStart: Date?, launchedAt: Date, hadRequest: Bool) -> LaunchKind {
        if hadRequest { return .quiet }
        if let session = consoleSessionStart {
            let sinceLogin = launchedAt.timeIntervalSince(session)
            if launchedAsLoginItem || (sinceLogin >= -60 && sinceLogin <= loginWindow) {
                return .login(session: session)
            }
            return .normal
        }
        // No session start to tell sessions apart: each login-item launch counts on its own.
        return launchedAsLoginItem ? .login(session: launchedAt) : .normal
    }
}
