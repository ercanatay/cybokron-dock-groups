import AppKit

/// The parts of the system workspace that launching a group needs.
@MainActor
public protocol ApplicationWorkspace: AnyObject {
    /// Brings a running instance of the app to the front. Returns `false` when it isn't running.
    func activateRunningApplication(bundleIdentifier: String) -> Bool
    /// Where the app lives on this Mac, or `nil` when it isn't installed.
    func locateApplication(_ app: AppReference) -> URL?
    /// Launches the app at `url`, finishing once it has started.
    func launchApplication(at url: URL) async throws
}

/// `ApplicationWorkspace` backed by `NSWorkspace` and `NSRunningApplication`.
@MainActor
public final class SystemApplicationWorkspace: ApplicationWorkspace {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func activateRunningApplication(bundleIdentifier: String) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard let app = running.first(where: { !$0.isTerminated }) else { return false }
        if !app.activate(options: [.activateAllWindows]), let bundleURL = app.bundleURL {
            // macOS may refuse an activation request from an app that isn't frontmost. Asking
            // LaunchServices to open the already running app brings it forward instead; it never
            // starts a second instance.
            workspace.openApplication(at: bundleURL, configuration: Self.activatingConfiguration())
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

    private static func activatingConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }
}
