import AppKit

/// The parts of the system workspace that launching a group needs.
@MainActor
public protocol ApplicationWorkspace: AnyObject {
    /// Brings a running instance of the app to the front. Returns `false` when it isn't running.
    /// `bundleIdentifier` is the app's `AppReference.bundleIdentifier`: its location for apps
    /// identified by path.
    func activateRunningApplication(bundleIdentifier: String) -> Bool
    /// Brings a running instance of the app back as clicking its Dock icon does: un-hides it,
    /// restores its windows from the Dock when all of them are minimized, and otherwise asks it to
    /// reopen. Returns `false` when it isn't running. By default it's only brought to the front.
    func reopenRunningApplication(bundleIdentifier: String) -> Bool
    /// Where the app lives on this Mac, or `nil` when it isn't installed.
    func locateApplication(_ app: AppReference) -> URL?
    /// Launches the app at `url`, finishing once it has started.
    func launchApplication(at url: URL) async throws
}

extension ApplicationWorkspace {
    public func reopenRunningApplication(bundleIdentifier: String) -> Bool {
        activateRunningApplication(bundleIdentifier: bundleIdentifier)
    }
}

/// `ApplicationWorkspace` backed by `NSWorkspace` and `NSRunningApplication`.
@MainActor
public final class SystemApplicationWorkspace: ApplicationWorkspace {
    private let workspace: NSWorkspace
    private lazy var restorer = WindowRestorer()

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return false }
        activate(app)
        return true
    }

    public func reopenRunningApplication(bundleIdentifier: String) -> Bool {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return false }
        let outcome = restorer.restore(app)
        if outcome.restoredWindowCount == 0, let bundleURL = app.bundleURL {
            // What a Dock click does: LaunchServices brings the running app forward and asks it to
            // reopen, so an app without a visible window shows one again — AppKit apps restore a
            // minimized window or open a new one. It never starts a second instance.
            workspace.openApplication(at: bundleURL, configuration: Self.activatingConfiguration())
        } else {
            activate(app)
        }
        return true
    }

    public func locateApplication(_ app: AppReference) -> URL? {
        app.resolvedURL(workspace: workspace)
    }

    public func launchApplication(at url: URL) async throws {
        let configuration = Self.activatingConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        RunningApplicationLookup.runningApplications(identifiedBy: bundleIdentifier, workspace: workspace)
            .first { !$0.isTerminated }
    }

    private func activate(_ app: NSRunningApplication) {
        if !app.activate(options: [.activateAllWindows]), let bundleURL = app.bundleURL {
            // macOS may refuse an activation request from an app that isn't frontmost. Asking
            // LaunchServices to open the already running app brings it forward instead; it never
            // starts a second instance.
            workspace.openApplication(at: bundleURL, configuration: Self.activatingConfiguration())
        }
    }

    private static func activatingConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }
}
