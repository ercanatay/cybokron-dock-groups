import CoreWLAN
import DockGroupsCore
import Foundation
import OSLog

/// The Wi-Fi network's name, for Wi-Fi triggers (triggers spec §1.5, §2.3, §5, TS-7): CoreWLAN's
/// `ssid()` — which macOS answers only for an app allowed to use Location Services — and its events
/// when the network, the link or Wi-Fi's power changes. `NetworkSource` settles them.
///
/// It never scans for networks and never reads the access point's hardware address, the router or
/// anything else that could stand in for the network's name (T-S9). Without Location access it
/// doesn't even ask CoreWLAN: the reading is unknown, never "not connected" (`WiFiReading`), so a
/// "leaves" trigger can't run because the app lost sight of the network.
@MainActor
final class WiFiSource: NSObject, CWEventDelegate {
    private var onChange: (() -> Void)?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    var isRunning: Bool { onChange != nil }

    /// Follows the Wi-Fi interface's changes; `onChange` runs on the main queue.
    func start(onChange: @escaping () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event: CWEventType in [.ssidDidChange, .linkDidChange, .powerDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                logger.error("Wi-Fi events (\(event.rawValue, privacy: .public)) can't be followed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        guard onChange != nil else { return }
        onChange = nil
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringAllEvents()
        if client.delegate === self {
            client.delegate = nil
        }
    }

    /// What the Wi-Fi interface says now, as Wi-Fi triggers see it.
    static func reading(authorization: LocationAuthorization) -> WiFiReading {
        guard authorization.allowsNetworkNames else { return .unknown }
        let state = CWWiFiClient.shared().interface().map { interface in
            WiFiInterfaceState(
                isPoweredOn: interface.powerOn(),
                isAssociated: interface.interfaceMode() == .station,
                networkName: interface.ssid()
            )
        }
        return WiFiReading(interface: state, authorization: authorization)
    }

    // MARK: - CWEventDelegate (called on CoreWLAN's queue)

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    private nonisolated func changed() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }
}
