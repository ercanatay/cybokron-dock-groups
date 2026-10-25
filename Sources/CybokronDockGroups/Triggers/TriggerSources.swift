import AppKit
import CoreGraphics
import DockGroupsCore
import OSLog

/// The clock for time triggers (triggers spec §2.4, TS-1): one one-shot timer for the next due time,
/// none while no time can run. Timers fire at the end of their tolerance (TS-1), so it's 1 second: a
/// 9:00 trigger looks at 9:00:01. Times are looked at again — `onTick` — when the timer fires, after
/// a wake, and when the day, the clock or the time zone changes; then the timer is armed anew.
///
/// App Nap: the app has no window most of the time, so macOS may slow its timers down. TS-1 measured
/// no extra delay over a quarter of an hour in the background on AC power; a laptop on battery is a
/// manual gate (`docs/design/triggers-spike.md`).
@MainActor
final class ClockSource {
    static let tolerance: TimeInterval = 1

    private let nextDue: () -> Date?
    private let onTick: () -> Void
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// - Parameters:
    ///   - nextDue: When a time is due next (`TriggerCoordinator.nextDue`).
    ///   - onTick: Looks at the times (sends `TriggerSignal.clock`).
    init(nextDue: @escaping () -> Date?, onTick: @escaping () -> Void) {
        self.nextDue = nextDue
        self.onTick = onTick
    }

    func start() {
        guard observers.isEmpty else { return }
        let local = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observe(local, name) { [weak self] in
                if name == .NSSystemTimeZoneDidChange {
                    NSTimeZone.resetSystemTimeZone()
                }
                self?.tick()
            }
        }
        // Timers stand still while the Mac sleeps: look right after it wakes.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.tick() }
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    /// Arms the timer for the next due time, or none.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let due = nextDue() else { return }
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.debug("Next trigger time: \(due.formatted(.iso8601), privacy: .public)")
    }

    private func tick() {
        onTick()
        reschedule()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, observer))
    }
}

/// The screens and the session (triggers spec §1.3): the displays sleeping and waking — the Mac's
/// own sleep counts as the screens sleeping, and after it wakes the main display says whether
/// they're awake — and the user's session becoming the active one or not (fast user switching).
/// Notifications only; nothing is polled, and nothing needs a permission.
@MainActor
final class WorkspaceSource {
    private let send: (TriggerSignal) -> Void
    private var observers: [NSObjectProtocol] = []

    init(send: @escaping (TriggerSignal) -> Void) {
        self.send = send
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let signals: [(Notification.Name, () -> TriggerSignal)] = [
            (NSWorkspace.screensDidSleepNotification, { .screens(asleep: true) }),
            (NSWorkspace.screensDidWakeNotification, { .screens(asleep: false) }),
            (NSWorkspace.willSleepNotification, { .screens(asleep: true) }),
            (NSWorkspace.didWakeNotification, { .screens(asleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0) }),
            (NSWorkspace.sessionDidResignActiveNotification, { .session(active: false) }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { .session(active: true) }),
        ]
        for (name, signal) in signals {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(signal()) }
            })
        }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}

/// What the app can tell about how it was opened (TS-3): whether the open-application event says
/// it was opened as a login item, and when the user's console login session began.
enum LaunchSignals {
    /// Whether the event being handled — read in `applicationDidFinishLaunching`, where it's the
    /// open-application event of a normal launch — says the app was opened as a login item.
    @MainActor
    static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return property.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// When this user's console login session began (the latest one), from the login records.
    static func consoleSessionStart(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent() {
            let record = entry.pointee
            guard record.ut_type == USER_PROCESS, text(of: record.ut_line) == "console", text(of: record.ut_user) == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec) + TimeInterval(record.ut_tv.tv_usec) / 1_000_000)
            if latest.map({ date > $0 }) ?? true {
                latest = date
            }
        }
        return latest
    }

    /// A fixed-size C character field as text, up to its first NUL (which a full field doesn't have).
    private static func text<Field>(of field: Field) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
