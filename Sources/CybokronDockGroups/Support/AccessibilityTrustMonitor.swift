import AppKit
import ApplicationServices
import DockGroupsCore
import OSLog

/// The app's live view of its Accessibility access, shared by the settings panes and the global
/// shortcuts. It reads `AXIsProcessTrusted()` again when the app becomes active (as when the user
/// comes back from System Settings), when the system posts its accessibility notification, when a
/// status view appears, and every second while access is missing and someone watches.
@MainActor
final class AccessibilityTrustMonitor: ObservableObject {
    static let shared = AccessibilityTrustMonitor()

    /// Whether this app has Accessibility access.
    @Published private(set) var isTrusted: Bool

    /// Posted (undocumented) when an app's Accessibility access changes. The poll covers systems
    /// that don't post it.
    private static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")
    /// The access the notification announces can lag it; it's read again after this delay too.
    private static let notificationDelay: TimeInterval = 0.5

    private let tracker: AccessibilityTrustTracker
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Accessibility")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(check: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        tracker = AccessibilityTrustTracker(check: check)
        isTrusted = tracker.isTrusted
        tracker.onChange = { [weak self] trusted in
            self?.isTrusted = trusted
            self?.logger.notice("Accessibility access \(trusted ? "granted" : "revoked", privacy: .public)")
        }
        tracker.onPollingChange = { [weak self] polling in
            self?.setPolling(polling)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.accessibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNowAndShortlyAfter() }
        })
    }

    /// Reads access again now.
    func refresh() {
        tracker.refresh()
    }

    /// Call when a view showing the status appears, or a feature starts needing access; polls
    /// while access is missing. Balance with `endObserving()`.
    func beginObserving() {
        tracker.beginObserving()
    }

    func endObserving() {
        tracker.endObserving()
    }

    private func refreshNowAndShortlyAfter() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notificationDelay) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func setPolling(_ polling: Bool) {
        timer?.invalidate()
        timer = nil
        guard polling else {
            logger.debug("Stopped checking Accessibility access")
            return
        }
        logger.debug("Checking Accessibility access every \(AccessibilityTrustTracker.pollInterval, privacy: .public) s until granted")
        let timer = Timer(timeInterval: AccessibilityTrustTracker.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common: keeps firing while a menu or a drag tracks events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
