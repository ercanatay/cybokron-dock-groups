import AppKit
import OSLog

/// How Close All ends a group's apps.
public enum QuitMode: String, Equatable, Sendable {
    /// Asks each app to quit, as choosing Quit in the app would; apps can still ask to save changes.
    case graceful
    /// Ends the apps immediately, without save prompts. Unsaved changes are lost.
    case force

    /// ⌘-click forces; a plain or ⌥-click quits normally.
    public init(modifierFlags: NSEvent.ModifierFlags) {
        self = modifierFlags.contains(.command) ? .force : .graceful
    }
}

/// A running app that can be asked to quit. `NSRunningApplication` is one.
public protocol QuittableApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    /// Sends the app a quit request. Returns `false` when the request couldn't be sent.
    func terminate() -> Bool
    /// Kills the app. Returns `false` when that wasn't possible.
    func forceTerminate() -> Bool
}

extension NSRunningApplication: QuittableApplication {}

/// Finds running instances of an app.
@MainActor
public protocol RunningApplicationsProviding: AnyObject {
    /// `bundleIdentifier` is the app's `AppReference.bundleIdentifier`: its location for apps
    /// identified by path.
    func runningApplications(bundleIdentifier: String) -> [any QuittableApplication]
}

/// `RunningApplicationsProviding` backed by `NSRunningApplication`.
@MainActor
public final class SystemRunningApplications: RunningApplicationsProviding {
    public init() {}

    public func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] {
        RunningApplicationLookup.runningApplications(identifiedBy: bundleIdentifier)
    }
}

/// What Close All did with a group's running apps.
public struct QuitReport: Equatable, Sendable {
    public let groupName: String
    public let mode: QuitMode
    /// Running apps that were asked to quit (graceful) or ended (force), in the group's order.
    public let quit: [AppReference]
    /// Running apps for which that wasn't possible.
    public let refused: [AppReference]
}

/// Quits a group's running apps ("Close All"). Apps that aren't running are left alone, and this
/// app never quits itself even when it belongs to the group.
@MainActor
public final class GroupTerminator {
    private let applications: RunningApplicationsProviding
    private let ownProcessIdentifier: pid_t
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupTerminator")

    public init(applications: RunningApplicationsProviding, ownProcessIdentifier: pid_t) {
        self.applications = applications
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    public convenience init() {
        self.init(
            applications: SystemRunningApplications(),
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Whether any app of the group is running (and so Close All has something to do).
    public func hasRunningApps(_ group: DockGroup) -> Bool {
        group.apps.contains { !runningInstances(of: $0).isEmpty }
    }

    public func closeAll(_ group: DockGroup, mode: QuitMode) -> QuitReport {
        var quit: [AppReference] = []
        var refused: [AppReference] = []
        for app in group.apps {
            let instances = runningInstances(of: app)
            guard !instances.isEmpty else { continue }
            let results = instances.map { instance in
                mode == .force ? instance.forceTerminate() : instance.terminate()
            }
            if results.allSatisfy({ $0 }) {
                quit.append(app)
            } else {
                refused.append(app)
                logger.error("Close All (\(mode.rawValue, privacy: .public)) in group \(group.id, privacy: .public): \(app.bundleIdentifier, privacy: .public) refused")
            }
        }
        logger.debug("Close All (\(mode.rawValue, privacy: .public)) in group \(group.id, privacy: .public): \(quit.count) quit, \(refused.count) refused")
        return QuitReport(groupName: group.name, mode: mode, quit: quit, refused: refused)
    }

    private func runningInstances(of app: AppReference) -> [any QuittableApplication] {
        applications.runningApplications(bundleIdentifier: app.bundleIdentifier).filter {
            !$0.isTerminated && $0.processIdentifier != ownProcessIdentifier
        }
    }
}
