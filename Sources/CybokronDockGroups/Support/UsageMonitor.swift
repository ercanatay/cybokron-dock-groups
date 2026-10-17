import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Feeds app launches and activations from NSWorkspace into the usage statistics, however the app
/// was opened (Dock, Finder, Spotlight, a group). Only regular apps — the ones with a Dock icon —
/// count; background agents and this app itself don't. Lives as long as the app.
@MainActor
final class UsageMonitor {
    private let usage: UsageStore
    private let workspace: NSWorkspace
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased()
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Usage")

    init(usage: UsageStore, workspace: NSWorkspace = .shared) {
        self.usage = usage
        self.workspace = workspace
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = workspace.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.launched(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleIdentifier = app.bundleIdentifier
            else { return }
            MainActor.assumeIsolated { self?.usage.recordActivation(bundleIdentifier: bundleIdentifier) }
        })
    }

    private func launched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              let bundleIdentifier = app.bundleIdentifier,
              bundleIdentifier.lowercased() != ownBundleIdentifier,
              UsageTracker.isTracked(bundleIdentifier: bundleIdentifier)
        else { return }
        let reference = AppReference(
            bundleIdentifier: bundleIdentifier,
            name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? bundleIdentifier,
            path: app.bundleURL?.standardizedFileURL.path
        )
        logger.debug("Launch recorded: \(bundleIdentifier, privacy: .public)")
        usage.recordLaunch(of: reference)
    }
}

/// The Most Used list as the menu and the popup show it: the configured number of best-ranked apps
/// that are still on this Mac, or `nil` while the list is turned off in Settings.
@MainActor
final class MostUsedProvider {
    private let usage: UsageStore
    private let preferences: PreferencesStore
    private let icons: AppIconProviding

    init(usage: UsageStore, preferences: PreferencesStore, icons: AppIconProviding) {
        self.usage = usage
        self.preferences = preferences
        self.icons = icons
    }

    var isEnabled: Bool { preferences.preferences.showsMostUsed }

    /// Fires when the list may have changed.
    var changes: AnyPublisher<Void, Never> {
        usage.$stats.map { _ in () }.eraseToAnyPublisher()
    }

    /// Computed afresh on every call, so it never lags behind the statistics.
    func entries() -> [MostUsedEntry]? {
        guard isEnabled else { return nil }
        return usage.mostUsed(limit: preferences.preferences.mostUsedLimit, isAvailable: icons.isInstalled)
    }

    /// The list as a group the popup and the launcher understand; `nil` while turned off.
    func group() -> DockGroup? {
        entries().map(MostUsedGroup.group(with:))
    }
}
