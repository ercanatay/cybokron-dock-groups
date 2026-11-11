import AppKit

// Launch actions, slice 3, the launcher part: docs/design/launch-action-runner-slice.md.
//
// The only place a launch action's arguments reach the system. A plan (`LaunchActionArgumentPlan`,
// already checked) is started here, and only when its browser isn't running: a running browser may
// ignore launch arguments and open the page in whatever profile it shows (threat model T6), so it's
// refused instead, and nothing is opened or sent to it. The browser is started by LaunchServices
// (`NSWorkspace`), never as a child process, with an empty environment and no shell.

/// What the launcher needs of the system to start a browser with a launch action.
@MainActor
protocol LaunchActionWorkspace: AnyObject {
    /// Whether any instance of the app with this bundle identifier (compared ignoring case) runs.
    func isApplicationRunning(bundleIdentifier: String) -> Bool
    /// Where the app with this bundle identifier is installed, or `nil` when it isn't.
    func applicationLocation(bundleIdentifier: String) -> URL?
    /// The bundle identifier of the app bundle at `url`, or `nil` when it has none.
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
    /// Starts the app at `applicationURL` with `configuration` and has it open `urls`.
    func startApplication(at applicationURL: URL, opening urls: [URL], configuration: NSWorkspace.OpenConfiguration) async throws
}

/// Why a plan wasn't started. Fixed reasons that hold nothing from the item, so they can be logged.
enum LaunchActionRunRefusal: String, Error, CaseIterable, Hashable, Sendable {
    /// The browser already runs; its launch arguments could be ignored, so nothing was opened.
    case browserAlreadyRunning
    /// The browser isn't on this Mac, or what's there isn't the browser it claims to be.
    case browserNotInstalled
    /// The system didn't start the browser.
    case launchFailed
}

/// What starting a plan did.
enum LaunchActionRunOutcome: Hashable, Sendable {
    /// The browser was started with the plan's arguments and asked to open its address.
    case launched
    /// Nothing was started or opened, for this reason.
    case refused(LaunchActionRunRefusal)
}

/// Starts a checked plan's browser with the plan's arguments, only when that browser isn't running.
@MainActor
struct LaunchActionRunner {
    let workspace: LaunchActionWorkspace

    /// Checked in this order, the first failure winning: the browser is installed at a location
    /// that is an app bundle with the plan's bundle identifier; no instance of it runs; then it's
    /// started. A refusal starts and opens nothing.
    func run(_ plan: LaunchActionArgumentPlan) async -> LaunchActionRunOutcome {
        let identifier = plan.executableBundleIdentifier
        guard let location = workspace.applicationLocation(bundleIdentifier: identifier),
              location.isFileURL, FileLocation.isAppBundlePath(location.standardizedFileURL.path),
              let found = workspace.bundleIdentifier(ofApplicationAt: location),
              found.lowercased() == identifier.lowercased()
        else { return .refused(.browserNotInstalled) }
        // Asked last, right before starting, so the time for the browser to start meanwhile is short.
        guard !workspace.isApplicationRunning(bundleIdentifier: identifier) else {
            return .refused(.browserAlreadyRunning)
        }
        do {
            try await workspace.startApplication(at: location, opening: [plan.url], configuration: Self.configuration(for: plan))
            return .launched
        } catch {
            return .refused(.launchFailed)
        }
    }

    /// The configuration a plan's browser is started with: the plan's arguments as they are, one
    /// element each; an empty environment; brought to the front; never a second instance.
    static func configuration(for plan: LaunchActionArgumentPlan) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = plan.arguments
        configuration.environment = [:]
        configuration.createsNewApplicationInstance = false
        return configuration
    }
}

/// Why an item with a launch action wasn't opened (`GroupLauncher`). Fixed reasons, logged by
/// `code` only: never the profile name, the arguments or the address.
enum LaunchActionItemRefusal: Hashable, Sendable {
    /// The request didn't come from the user in the app (`LaunchSource.isUserPresent`).
    case unattendedSource(LaunchSource)
    /// The workspace can't start an app with a launch action.
    case noRunner
    /// No plan could be made (`LaunchActionArgumentPlan`).
    case plan(LaunchActionArgumentRefusal)
    /// The plan wasn't started (`LaunchActionRunner`).
    case run(LaunchActionRunRefusal)

    /// The reason as a fixed code for the log: "source.link", "plan.actionDisabled",
    /// "run.browserAlreadyRunning".
    var code: String {
        switch self {
        case .unattendedSource(let source): return "source.\(source.rawValue)"
        case .noRunner: return "noRunner"
        case .plan(let refusal): return "plan.\(refusal.rawValue)"
        case .run(let refusal): return "run.\(refusal.rawValue)"
        }
    }

    /// The outcome reported for the item: not found when its browser isn't installed, otherwise
    /// not opened, with the launch report's existing text.
    var outcome: LaunchReport.Outcome {
        switch self {
        case .plan(.browserNotInstalled), .run(.browserNotInstalled):
            return .notFound
        case .unattendedSource, .noRunner, .plan, .run:
            return .failed(reason: Localization.string("core.launch.notOpened", "The app wasn't opened."))
        }
    }
}

extension LaunchAction {
    /// The browser the action's template starts when the item has no browser chosen for it.
    var preferredBrowserBundleIdentifier: String? {
        switch self {
        case .browserProfile(let browser, _): return browser.bundleIdentifiers.first
        }
    }
}

extension SystemApplicationWorkspace: LaunchActionWorkspace {
    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        let wanted = bundleIdentifier.lowercased()
        return workspace.runningApplications.contains { !$0.isTerminated && $0.bundleIdentifier?.lowercased() == wanted }
    }

    func applicationLocation(bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    func startApplication(at applicationURL: URL, opening urls: [URL], configuration: NSWorkspace.OpenConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
