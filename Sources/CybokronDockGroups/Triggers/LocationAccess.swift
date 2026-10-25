import AppKit
import Combine
import CoreLocation
import DockGroupsCore
import OSLog

/// Location Services access, for Wi-Fi triggers only (triggers spec §1.5, §2.3, TS-7): macOS shows
/// the Wi-Fi network's name only to apps allowed to use Location Services.
///
/// - It only ever reads and asks for the authorization: it never starts location updates or reads
///   a location (T-S9).
/// - Nothing of CoreLocation is touched until the status is needed — a Wi-Fi trigger exists, the
///   editor shows a Wi-Fi event, Settings → Triggers shows the status — and the manager is never
///   made while Location Services is off for the whole Mac.
/// - It asks only in `request()`, which only the trigger editor's Allow… calls. TS-7 (macOS 27):
///   for this menu bar app, the when-in-use request shows macOS's question with
///   `NSLocationUsageDescription`, and the answer is "allowed" for good; once refused, macOS
///   doesn't ask again, so Open Privacy Settings… goes to the list instead. Without the
///   `com.apple.security.personal-information.location` entitlement the hardened runtime drops
///   the question altogether.
///
/// Only the main app has one (`TriggerController`): an agent never touches Location Services.
@MainActor
final class LocationAccess: NSObject, ObservableObject {
    @Published private(set) var status: LocationAuthorization = .notDetermined
    /// Whether the status was looked at; until then it's only a default.
    private(set) var hasLooked = false

    private var manager: CLLocationManager?
    private var observer: NSObjectProtocol?
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// Looks at the status the first time it's needed.
    func lookIfNeeded() {
        guard !hasLooked else { return }
        refresh()
    }

    /// Reads the status again. The first time, it starts following it: macOS says when it changes,
    /// and it's read again when the app becomes active (System Settings may have changed it).
    func refresh() {
        if !hasLooked {
            hasLooked = true
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // With Location Services off, CoreLocation may warn when it's used: nothing more is asked.
        guard CLLocationManager.locationServicesEnabled() else {
            set(.servicesOff)
            return
        }
        let manager = self.manager ?? makeManager()
        set(Self.authorization(manager.authorizationStatus))
    }

    /// Allow…: asks macOS for Location access, once, when it was never asked. The app comes forward
    /// first, since macOS asks only an app in use.
    func request() {
        refresh()
        guard status == .notDetermined, let manager else { return }
        logger.notice("Asking for Location access, for Wi-Fi triggers")
        NSApp.activate()
        manager.requestWhenInUseAuthorization()
    }

    /// Open Privacy Settings…: System Settings → Privacy & Security → Location Services.
    func openPrivacySettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func makeManager() -> CLLocationManager {
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
        return manager
    }

    private func set(_ status: LocationAuthorization) {
        guard status != self.status else { return }
        logger.notice("Location access: \(status.rawValue, privacy: .public)")
        self.status = status
    }

    private static func authorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}

extension LocationAccess: CLLocationManagerDelegate {
    /// macOS says the authorization changed (it also says so once, right after the manager is made).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}
