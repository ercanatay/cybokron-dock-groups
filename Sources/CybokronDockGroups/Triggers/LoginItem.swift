import AppKit
import Combine
import OSLog
import ServiceManagement

/// Open at Login (triggers spec §1.11, §2.6, TS-2): the app itself registered as a login item with
/// `SMAppService.mainApp` — no helper, no LaunchAgent. It's only ever turned on or off by the user's
/// click in Settings → Triggers (or the editor's Turn On Open at Login); the status is read again
/// when Settings shows it and when the app becomes active, since the user may change it in System
/// Settings → General → Login Items meanwhile.
///
/// TS-2 (macOS 27.0.1): registering works for an ad hoc signed copy too; the status stays "on" after
/// the app is replaced in place (another build, another code hash, as an update does) and after it's
/// moved. Whether macOS then opens it at login is a manual gate.
///
/// Only the main app has one: an agent never creates it (`AppDelegate` owns the only instance).
@MainActor
final class LoginItem: ObservableObject {
    enum Status: Equatable {
        case on
        case off
        /// Registered, but turned off (or not yet allowed) in System Settings → Login Items.
        case needsApproval
    }

    @Published private(set) var status: Status = .off
    /// Why the last change didn't work; cleared by the next one.
    @Published private(set) var problem: String?

    private let service: SMAppService
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isOn: Bool { status == .on }

    func refresh() {
        let status: Status
        switch service.status {
        case .enabled: status = .on
        case .requiresApproval: status = .needsApproval
        case .notRegistered, .notFound: status = .off
        @unknown default: status = .off
        }
        if status != self.status {
            self.status = status
        }
    }

    /// Turns Open at Login on or off, as the user asked.
    func set(_ on: Bool) {
        problem = nil
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            logger.notice("Open at Login turned \(on ? "on" : "off", privacy: .public)")
        } catch {
            logger.error("Open at Login couldn't be turned \(on ? "on" : "off", privacy: .public): \(String(describing: error), privacy: .public)")
            problem = L10n.Triggers.Settings.loginItemFailed(error.localizedDescription)
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
