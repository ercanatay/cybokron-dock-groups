import AppKit
import DockGroupsCore
import Network
import OSLog

/// The network, for Ethernet and Wi-Fi triggers (triggers spec §1.5, §2.3, §5, TS-7, TS-8, TS-9):
/// read 5 seconds after the last change — roaming between access points, a DHCP renewal — and sent
/// as `TriggerSignal.network`.
///
/// - **Ethernet** (`NWPathMonitor`, no permission): connected while the network path is satisfied
///   and a wired interface — built in, an adapter, a dock — is among its available interfaces,
///   whether or not the Mac sends its traffic there first (TS-9).
/// - **Wi-Fi** (`WiFiSource`, only while Location access is allowed): the network's name.
///   Without it the Wi-Fi part is unknown, and unknown makes no edge.
/// - **VPN**: not watched. On this Mac ten `utun` interfaces exist with no VPN at all, and a
///   split-tunnel VPN never becomes the primary service, so nothing tells one reliably (TS-8):
///   `tunnelIsPrimary` stays unknown.
///
/// Nothing is read while the Mac sleeps, and the first reading after it wakes — or after the
/// source starts, at login too — waits 15 seconds, so a network that's still coming back isn't
/// "disconnected"; the reading is then compared with what was kept from before. Notifications and
/// the path monitor only, nothing polled. It runs only while a network trigger can run
/// (`TriggerSourceNeeds`).
@MainActor
final class NetworkSource {
    static let settle: Duration = .seconds(5)
    static let wakeSettle: Duration = .seconds(15)

    /// What the triggers need watched.
    struct Watching: Equatable {
        var ethernet = false
        /// Only with Location access.
        var wifi = false

        var isEmpty: Bool { !ethernet && !wifi }
    }

    private(set) var watching = Watching()

    private let send: (TriggerSignal) -> Void
    private let authorization: () -> LocationAuthorization
    private let wifi = WiFiSource()
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.cybokron.dockgroups.network-triggers", qos: .utility)
    /// Whether a wired connection has a network, from the latest path; `nil` before the first one.
    private var usesEthernet: Bool?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var isAsleep = false
    /// After the start or a wake, nothing is read before this, however the network changes meanwhile.
    private var notBefore: ContinuousClock.Instant?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// - Parameters:
    ///   - send: Gets the settled readings.
    ///   - authorization: Location access now (`LocationAccess.status`).
    init(send: @escaping (TriggerSignal) -> Void, authorization: @escaping () -> LocationAuthorization) {
        self.send = send
        self.authorization = authorization
    }

    var isRunning: Bool { monitor != nil }

    /// Watches what `watching` says, starting and stopping the path monitor and Wi-Fi's events.
    func watch(_ watching: Watching) {
        guard watching != self.watching else { return }
        let old = self.watching
        self.watching = watching
        guard !watching.isEmpty else {
            stop()
            return
        }
        if old.isEmpty {
            begin()
        }
        if watching.wifi, !old.wifi {
            wifi.start { [weak self] in self?.changed() }
        } else if !watching.wifi, old.wifi {
            wifi.stop()
        }
        // Look again with what's watched now (a Wi-Fi part just allowed, Ethernet just needed).
        changed()
    }

    private func begin() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallAsleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wired = path.status == .satisfied && path.availableInterfaces.contains { $0.type == .wiredEthernet }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.pathChanged(usesEthernet: wired) }
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        notBefore = .now + Self.wakeSettle
    }

    private func stop() {
        pending?.cancel()
        pending = nil
        monitor?.cancel()
        monitor = nil
        usesEthernet = nil
        wifi.stop()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        isAsleep = false
        notBefore = nil
    }

    private func pathChanged(usesEthernet: Bool) {
        self.usesEthernet = usesEthernet
        // A path changes with Wi-Fi too: whatever changed, look once it settled.
        changed()
    }

    private func changed() {
        schedule(after: Self.settle)
    }

    private func fallAsleep() {
        isAsleep = true
        pending?.cancel()
        pending = nil
    }

    private func wake() {
        isAsleep = false
        notBefore = .now + Self.wakeSettle
        schedule(after: Self.wakeSettle)
    }

    /// Reads after `delay` without a newer change — and not before the start or the wake settled;
    /// a change meanwhile starts the wait again.
    private func schedule(after delay: Duration) {
        guard !watching.isEmpty, !isAsleep else { return }
        pending?.cancel()
        var due = ContinuousClock.now + delay
        if let notBefore, notBefore > due {
            due = notBefore
        }
        pending = Task { @MainActor [weak self, due] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard let self, !Task.isCancelled, !self.isAsleep else { return }
            self.pending = nil
            self.notBefore = nil
            self.read()
        }
    }

    private func read() {
        let reading = NetworkReading(
            usesEthernet: watching.ethernet ? usesEthernet : nil,
            wifi: watching.wifi ? WiFiSource.reading(authorization: authorization()) : .unknown,
            // TS-8: no VPN is watched.
            tunnelIsPrimary: nil
        )
        guard reading != .unknown else { return }
        // Never the network's name (spec §4.5).
        let wifiKnown = reading.wifi != .unknown
        logger.debug("Network settled: Ethernet \(String(describing: reading.usesEthernet), privacy: .public), Wi-Fi known \(wifiKnown, privacy: .public)")
        send(.network(reading))
    }
}
