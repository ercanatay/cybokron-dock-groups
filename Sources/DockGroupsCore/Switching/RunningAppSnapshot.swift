import AppKit

/// A running app as starting and finishing groups see it (`TransitionPlanner`): taken once per
/// transition, so planning reads nothing and changes nothing.
public struct RunningAppSnapshot: Hashable, Sendable {
    public let processIdentifier: pid_t
    /// What group items match it by: the lowercased bundle identifier, or — for an app without
    /// one — the normalized location of its bundle (`RunningApplicationLookup.pathIdentity`), as
    /// `AppReference.normalizedBundleIdentifier` has them.
    public let identity: String
    /// The name it's shown with (`localizedName`), for reports and questions.
    public let name: String
    public let isHidden: Bool
    /// Whether it's a regular app (a Dock icon, a menu bar): only those are ever hidden or quit.
    public let isRegular: Bool

    public init(processIdentifier: pid_t, identity: String, name: String, isHidden: Bool = false, isRegular: Bool = true) {
        self.processIdentifier = processIdentifier
        self.identity = identity.lowercased()
        self.name = name
        self.isHidden = isHidden
        self.isRegular = isRegular
    }

    /// The identity of a running app with these properties: see `identity`. `nil` when it has
    /// neither a bundle identifier nor a bundle.
    public static func identity(bundleIdentifier: String?, bundleURL: URL?) -> String? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier.lowercased()
        }
        return RunningApplicationLookup.pathIdentity(bundleIdentifier: nil, bundleURL: bundleURL)
    }
}

/// A running app that switching can hide, quit and show again. `NSRunningApplication` is one.
public protocol SwitchableApplication: QuittableApplication {
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    /// Shows the app again after it was hidden. Returns `false` when that wasn't possible.
    func unhide() -> Bool
    /// Brings the app to the front. Returns `false` when macOS didn't.
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: SwitchableApplication {}

/// The running apps, for starting and finishing groups. The app's implementation asks
/// `NSWorkspace`; tests use a fake.
@MainActor
public protocol RunningApplicationsListing: AnyObject {
    /// The apps running now (terminated ones left out), in the order macOS lists them.
    func runningApplications() -> [RunningAppSnapshot]
    /// The running app with this process identifier; `nil` when there's none (any more).
    func application(withProcessIdentifier processIdentifier: pid_t) -> (any SwitchableApplication)?
}

/// `RunningApplicationsListing` backed by `NSWorkspace` and `NSRunningApplication`.
@MainActor
public final class SystemRunningApplicationsListing: RunningApplicationsListing {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func runningApplications() -> [RunningAppSnapshot] {
        workspace.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  let identity = RunningAppSnapshot.identity(bundleIdentifier: application.bundleIdentifier, bundleURL: application.bundleURL)
            else { return nil }
            return RunningAppSnapshot(
                processIdentifier: application.processIdentifier,
                identity: identity,
                name: application.localizedName ?? identity,
                isHidden: application.isHidden,
                isRegular: application.activationPolicy == .regular
            )
        }
    }

    public func application(withProcessIdentifier processIdentifier: pid_t) -> (any SwitchableApplication)? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated else { return nil }
        return application
    }
}
