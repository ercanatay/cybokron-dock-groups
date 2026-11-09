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

/// A running app that can be asked to quit or hide. `NSRunningApplication` is one.
public protocol QuittableApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var isHidden: Bool { get }
    /// Whether the app has a Dock icon (`.regular`), a menu bar item only (`.accessory`) or no UI
    /// at all (`.prohibited`). macOS doesn't hide the last two.
    var activationPolicy: NSApplication.ActivationPolicy { get }
    /// Hides the app, as ⌘H would. Returns `false` when that wasn't possible.
    func hide() -> Bool
    /// Sends the app a quit request. Returns `false` when the request couldn't be sent.
    func terminate() -> Bool
    /// Kills the app. Returns `false` when that wasn't possible.
    func forceTerminate() -> Bool
}

extension NSRunningApplication: QuittableApplication {}

extension QuittableApplication {
    /// Fakes that don't say are regular apps.
    public var activationPolicy: NSApplication.ActivationPolicy { .regular }

    /// Whether macOS can hide the app at all: background (`.accessory`, `.prohibited`) apps have
    /// nothing to hide, so not hiding isn't a failure.
    var isHideable: Bool { activationPolicy == .regular }
}

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
    /// Running apps left alone because they're protected (`ProtectedApps`), in the group's order.
    public let kept: [AppReference]

    public init(groupName: String, mode: QuitMode, quit: [AppReference], refused: [AppReference], kept: [AppReference] = []) {
        self.groupName = groupName
        self.mode = mode
        self.quit = quit
        self.refused = refused
        self.kept = kept
    }
}

/// What Hide All did with a group's running apps.
public struct HideReport: Equatable, Sendable {
    public let groupName: String
    /// Running apps that were hidden (or already were), in the group's order.
    public let hidden: [AppReference]
    /// Running regular apps that couldn't be hidden.
    public let refused: [AppReference]
    /// Running background apps (no Dock icon: `.accessory`, `.prohibited`) that macOS doesn't hide.
    /// Not a problem to tell the user about; only logged.
    public let unhideable: [AppReference]

    public init(groupName: String, hidden: [AppReference], refused: [AppReference], unhideable: [AppReference] = []) {
        self.groupName = groupName
        self.hidden = hidden
        self.refused = refused
        self.unhideable = unhideable
    }
}

/// What hiding, quitting or showing running apps again did (`GroupTerminator.hide`, `quit`,
/// `unhide`), in the order asked.
public struct RunningAppsReport: Equatable, Sendable {
    /// Apps it was done to (or that already were so: hidden, shown).
    public let done: [RunningAppSnapshot]
    /// Apps that said no.
    public let refused: [RunningAppSnapshot]
    /// Apps left alone: protected, this app, or no longer running (or no longer the same app).
    public let skipped: [RunningAppSnapshot]

    public init(done: [RunningAppSnapshot] = [], refused: [RunningAppSnapshot] = [], skipped: [RunningAppSnapshot] = []) {
        self.done = done
        self.refused = refused
        self.skipped = skipped
    }
}

/// Quits ("Close All") or hides ("Hide All") a group's running apps. Apps that aren't running are
/// left alone — nothing is launched — and this app never quits or hides itself even when it
/// belongs to the group. Close All also leaves protected apps alone (`ProtectedApps`: the user's
/// list, this app's standalone groups' apps and Finder), whoever asked — the popup, a menu, a link,
/// Siri or a standalone group's own app — as everything that quits apps comes through here.
///
/// Starting and finishing groups hide, quit and show again the apps a `TransitionPlan` names
/// (`hide`, `quit`, `unhide`); those check the protection again, and that each app is still the
/// one planned for.
@MainActor
public final class GroupTerminator {
    private let applications: RunningApplicationsProviding
    private let listing: RunningApplicationsListing
    private let ownProcessIdentifier: pid_t
    private let protectedApps: () -> ProtectedApps
    private let pendingLaunches: DelayedLaunches?
    private let sleeper: Sleeping
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupTerminator")

    /// How long to wait before looking again at apps whose hide request came back `false`: macOS
    /// often applies a hide a moment after the call reports no.
    public static let hideSettleDelay: Duration = .milliseconds(400)

    /// - Parameters:
    ///   - listing: Finds the apps a transition plan names by process identifier; by default
    ///     `SystemRunningApplicationsListing`.
    ///   - protectedApps: The user's protected apps, read at every call; the always protected ones
    ///     are added to them.
    ///   - pendingLaunches: The group's items still waiting for their launch delay
    ///     (`GroupLauncher.pendingLaunches`): Close All and Hide All cancel them.
    ///   - sleeper: Waits `hideSettleDelay` before checking again that apps asked to hide did;
    ///     `TaskSleeping` by default.
    public init(
        applications: RunningApplicationsProviding,
        ownProcessIdentifier: pid_t,
        listing: RunningApplicationsListing? = nil,
        protectedApps: @escaping () -> ProtectedApps = { ProtectedApps() },
        pendingLaunches: DelayedLaunches? = nil,
        sleeper: Sleeping? = nil
    ) {
        self.sleeper = sleeper ?? TaskSleeping()
        self.applications = applications
        self.ownProcessIdentifier = ownProcessIdentifier
        self.listing = listing ?? SystemRunningApplicationsListing()
        self.protectedApps = protectedApps
        self.pendingLaunches = pendingLaunches
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

    /// Quits the group's running apps, except protected ones, which the report lists as kept. The
    /// group's items still waiting for their launch delay don't open any more.
    public func closeAll(_ group: DockGroup, mode: QuitMode) -> QuitReport {
        pendingLaunches?.cancel(group: group.id)
        var quit: [AppReference] = []
        var refused: [AppReference] = []
        var kept: [AppReference] = []
        let protected = protectedApps()
        for app in group.apps {
            let instances = runningInstances(of: app)
            guard !instances.isEmpty else { continue }
            if protected.protects(identity: app.normalizedBundleIdentifier, from: .quitting) {
                kept.append(app)
                continue
            }
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
        logger.debug("Close All (\(mode.rawValue, privacy: .public)) in group \(group.id, privacy: .public): \(quit.count) quit, \(refused.count) refused, \(kept.count) protected")
        return QuitReport(groupName: group.name, mode: mode, quit: quit, refused: refused, kept: kept)
    }

    /// Hides every running app of the group. Apps that are already hidden stay hidden. The group's
    /// items still waiting for their launch delay don't open any more.
    public func hideAll(_ group: DockGroup) -> HideReport {
        pendingLaunches?.cancel(group: group.id)
        var hidden: [AppReference] = []
        var refused: [AppReference] = []
        for app in group.apps {
            let instances = runningInstances(of: app)
            guard !instances.isEmpty else { continue }
            let results = instances.map { $0.isHidden || $0.hide() }
            if results.allSatisfy({ $0 }) {
                hidden.append(app)
            } else {
                refused.append(app)
                logger.error("Hide All in group \(group.id, privacy: .public): \(app.bundleIdentifier, privacy: .public) refused")
            }
        }
        logger.debug("Hide All in group \(group.id, privacy: .public): \(hidden.count) hidden, \(refused.count) refused")
        return HideReport(groupName: group.name, hidden: hidden, refused: refused)
    }

    /// Like `hideAll`, but an app whose hide request came back `false` gets `hideSettleDelay` to
    /// show up hidden before it counts as refused (macOS often hides a moment after saying no).
    /// Background apps (`.accessory`, `.prohibited`) that stay visible are reported as
    /// `unhideable`, not refused.
    public func hideAllSettled(_ group: DockGroup) async -> HideReport {
        pendingLaunches?.cancel(group: group.id)
        var requested: [(app: AppReference, instances: [any QuittableApplication], notHidden: [any QuittableApplication])] = []
        for app in group.apps {
            let instances = runningInstances(of: app)
            guard !instances.isEmpty else { continue }
            requested.append((app, instances, instances.filter { !$0.isHidden && !$0.hide() }))
        }
        await settle(requested.contains { $0.notHidden.contains { $0.isHideable } })

        var hidden: [AppReference] = []
        var refused: [AppReference] = []
        var unhideable: [AppReference] = []
        for entry in requested {
            let stillVisible = entry.notHidden.filter { !$0.isHidden && !$0.isTerminated }
            if stillVisible.isEmpty {
                hidden.append(entry.app)
            } else if stillVisible.contains(where: \.isHideable) {
                refused.append(entry.app)
                logger.error("Hide All in group \(group.id, privacy: .public): \(entry.app.bundleIdentifier, privacy: .public) refused")
            } else {
                unhideable.append(entry.app)
                logger.notice("Hide All in group \(group.id, privacy: .public): \(entry.app.bundleIdentifier, privacy: .public) is a background app, macOS doesn't hide it")
            }
        }
        logger.debug("Hide All in group \(group.id, privacy: .public): \(hidden.count) hidden, \(refused.count) refused, \(unhideable.count) background")
        return HideReport(groupName: group.name, hidden: hidden, refused: refused, unhideable: unhideable)
    }

    /// Waits `hideSettleDelay` when `needed`; a cancelled wait just ends early.
    private func settle(_ needed: Bool) async {
        guard needed else { return }
        try? await sleeper.sleep(for: Self.hideSettleDelay)
    }

    // MARK: - Transitions

    /// Hides the apps, as Start and Finish do. Protected apps and this app are skipped, and so is
    /// an app that quit meanwhile; an app that's already hidden counts as done.
    public func hide(_ apps: [RunningAppSnapshot]) -> RunningAppsReport {
        perform(on: apps, protectedFrom: .hiding, label: "Hide") { application in
            application.isHidden || application.hide()
        }
    }

    /// Like `hide`, but an app whose hide request came back `false` gets `hideSettleDelay` to show
    /// up hidden before it counts as refused. Background apps (`.accessory`, `.prohibited`) that
    /// stay visible are skipped (logged), not refused.
    public func hideSettled(_ apps: [RunningAppSnapshot]) async -> RunningAppsReport {
        let protected = protectedApps()
        var entries: [(snapshot: RunningAppSnapshot, application: (any SwitchableApplication)?, hidNow: Bool)] = []
        for snapshot in apps {
            let application = eligibleApplication(for: snapshot, protectedFrom: .hiding, protected: protected)
            entries.append((snapshot, application, application.map { $0.isHidden || $0.hide() } ?? false))
        }
        await settle(entries.contains { !$0.hidNow && $0.application?.isHideable == true })

        var done: [RunningAppSnapshot] = []
        var refused: [RunningAppSnapshot] = []
        var skipped: [RunningAppSnapshot] = []
        for entry in entries {
            guard let application = entry.application else {
                skipped.append(entry.snapshot)
                continue
            }
            if entry.hidNow || application.isHidden || application.isTerminated {
                done.append(entry.snapshot)
            } else if application.isHideable {
                refused.append(entry.snapshot)
                logger.error("Hide: \(entry.snapshot.identity, privacy: .public) refused")
            } else {
                skipped.append(entry.snapshot)
                logger.notice("Hide: \(entry.snapshot.identity, privacy: .public) is a background app, macOS doesn't hide it")
            }
        }
        return RunningAppsReport(done: done, refused: refused, skipped: skipped)
    }

    /// Asks the apps to quit, as Start and Finish do: always gracefully, so they can still ask to
    /// save changes. Protected apps, Finder and this app are skipped, and so is an app that quit
    /// meanwhile.
    public func quit(_ apps: [RunningAppSnapshot]) -> RunningAppsReport {
        perform(on: apps, protectedFrom: .quitting, label: "Quit") { $0.terminate() }
    }

    /// Shows the apps again, as Finish does for the group it goes back to, and brings `front` (one
    /// of the group's running apps) forward. Nothing is launched.
    public func unhide(_ apps: [RunningAppSnapshot], bringingToFront front: RunningAppSnapshot? = nil) -> RunningAppsReport {
        let report = perform(on: apps, protectedFrom: nil, label: "Show") { application in
            !application.isHidden || application.unhide()
        }
        if let front, front.processIdentifier != ownProcessIdentifier,
           let application = currentApplication(for: front), !application.isTerminated {
            if !application.activate(options: [.activateAllWindows]) {
                logger.debug("Finish: \(front.identity, privacy: .public) didn't come to the front")
            }
        }
        return report
    }

    /// Does `action` to each app that's still the one planned for (same process, same identity)
    /// and isn't protected from `protectedFrom`.
    private func perform(
        on apps: [RunningAppSnapshot],
        protectedFrom action: ProtectedApps.Action?,
        label: String,
        _ act: (any SwitchableApplication) -> Bool
    ) -> RunningAppsReport {
        var done: [RunningAppSnapshot] = []
        var refused: [RunningAppSnapshot] = []
        var skipped: [RunningAppSnapshot] = []
        let protected = protectedApps()
        for app in apps {
            guard let application = eligibleApplication(for: app, protectedFrom: action, protected: protected) else {
                skipped.append(app)
                continue
            }
            if act(application) {
                done.append(app)
            } else {
                refused.append(app)
                logger.error("\(label, privacy: .public): \(app.identity, privacy: .public) refused")
            }
        }
        return RunningAppsReport(done: done, refused: refused, skipped: skipped)
    }

    /// The app still running as planned, unless it's this app or protected from `action`.
    private func eligibleApplication(
        for app: RunningAppSnapshot,
        protectedFrom action: ProtectedApps.Action?,
        protected: ProtectedApps
    ) -> (any SwitchableApplication)? {
        if app.processIdentifier == ownProcessIdentifier
            || action.map({ protected.protects(app, from: $0) }) == true
            || (action == nil && ProtectedApps.isAlwaysProtected(identity: app.identity, action: .hiding)) {
            return nil
        }
        guard let application = currentApplication(for: app), !application.isTerminated else { return nil }
        return application
    }

    /// The running app with the snapshot's process identifier, if it's still the same app: a
    /// process identifier that was reused meanwhile belongs to another app, which is left alone.
    private func currentApplication(for snapshot: RunningAppSnapshot) -> (any SwitchableApplication)? {
        guard let application = listing.application(withProcessIdentifier: snapshot.processIdentifier),
              RunningAppSnapshot.identity(bundleIdentifier: application.bundleIdentifier, bundleURL: application.bundleURL) == snapshot.identity
        else { return nil }
        return application
    }

    /// Websites, files and folders have no process: Close All and Hide All leave them alone.
    private func runningInstances(of app: AppReference) -> [any QuittableApplication] {
        guard app.kind.hasProcess else { return [] }
        return applications.runningApplications(bundleIdentifier: app.bundleIdentifier).filter {
            !$0.isTerminated && $0.processIdentifier != ownProcessIdentifier
        }
    }
}
