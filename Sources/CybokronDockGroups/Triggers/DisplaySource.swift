import AppKit
import CoreGraphics
import DockGroupsCore
import OSLog

/// The connected displays, for display triggers (triggers spec §1.4, §2.3, TS-5, TS-6): read 2
/// seconds after the last `didChangeScreenParameters`, so a monitor that flickers or a resolution
/// change counts once or not at all, and sent as `TriggerSignal.displays`.
///
/// Nothing is read while the screens or the Mac sleep — some monitors leave the screen list while
/// they sleep — and the first reading after they wake waits 5 seconds: a monitor that stayed
/// connected through the sleep is then compared with the set kept from before it, and makes no
/// edge. Notifications only, nothing polled, nothing that needs a permission: the identities are
/// what CoreGraphics and `NSScreen` report (vendor, model and serial numbers, the name, whether
/// it's built in).
@MainActor
final class DisplaySource {
    static let settle: Duration = .seconds(2)
    static let wakeSettle: Duration = .seconds(5)

    private let send: (TriggerSignal) -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: Task<Void, Never>?
    private var isAsleep = false
    /// After a wake, nothing is read before this, however the displays change meanwhile.
    private var notBefore: ContinuousClock.Instant?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    init(send: @escaping (TriggerSignal) -> Void) {
        self.send = send
    }

    var isRunning: Bool { !observers.isEmpty }

    /// Starts watching; the first reading comes once the displays settled.
    func start() {
        guard observers.isEmpty else { return }
        isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.schedule(after: Self.settle)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(workspace, name) { [weak self] in self?.fallAsleep() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { [weak self] in self?.wake() }
        }
        schedule(after: Self.settle)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func fallAsleep() {
        isAsleep = true
        pending?.cancel()
        pending = nil
    }

    private func wake() {
        // A display wake can follow a Mac wake: the later one decides.
        isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        guard !isAsleep else { return }
        notBefore = .now + Self.wakeSettle
        schedule(after: Self.wakeSettle)
    }

    /// Reads after `delay` without a newer change — and not before the wake settled; a change
    /// meanwhile starts the wait again.
    private func schedule(after delay: Duration) {
        guard !isAsleep else { return }
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
            let displays = Self.connectedDisplays()
            self.logger.debug("Displays settled: \(displays?.count ?? -1, privacy: .public)")
            self.send(.displays(displays))
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, observer))
    }

    /// The displays connected now, as `NSScreen` lists them; `nil` when none can be read (while the
    /// display configuration changes, or with no display at all), which changes nothing.
    static func connectedDisplays() -> [DisplayIdentity]? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displays = NSScreen.screens.compactMap { screen -> DisplayIdentity? in
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayIdentity(
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0
            )
        }
        return displays.isEmpty ? nil : displays
    }
}
