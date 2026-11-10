import AppKit
import ApplicationServices

// Read-only Accessibility adapter for the window layout planners (design spec H, slice described
// in `docs/design/window-layout-observer-slice.md`).
//
// It only reads. The calls it makes are the trust check without options, creating an
// application element, setting this process's own messaging timeout on an element, and copying
// attribute values. Nothing writes an attribute, performs an action, activates, raises,
// unminimizes or moves a window, and nothing asks macOS to show its permission request.
//
// Facts that have no public Accessibility attribute (visible on screen, current Space, full
// screen, a stable window identity) are always `.unknown`; nothing is guessed from geometry,
// minimized state or window order. Window titles are never read.
//
// Not connected to the app: no UI, feature or setting calls it yet.

/// Why one Accessibility read produced no usable value.
enum LayoutAccessibilityReadFailure: Equatable, Sendable {
    /// The element has no such attribute or no value for it: that one fact stays unknown.
    case missing
    /// The element no longer exists.
    case elementGone
    /// The app did not answer within the messaging timeout, or could not complete the request.
    case unresponsive
    /// Accessibility access is off for this process.
    case accessDenied
    /// Any other error.
    case failed

    init(_ error: AXError) {
        switch error {
        case .attributeUnsupported, .noValue: self = .missing
        case .invalidUIElement: self = .elementGone
        case .cannotComplete: self = .unresponsive
        case .apiDisabled: self = .accessDenied
        default: self = .failed
        }
    }
}

/// The result of one Accessibility read.
enum LayoutAccessibilityRead<Value> {
    case value(Value)
    case failure(LayoutAccessibilityReadFailure)
}

/// The only Accessibility calls `LayoutAccessibilityObserver` makes. Every requirement reads; the
/// protocol has no way to change another app. Tests supply fakes.
protocol LayoutAccessibilityReading {
    associatedtype Element

    /// Whether this process has Accessibility access, checked without asking for it.
    func isProcessTrusted() -> Bool
    /// The Accessibility element of the app with this process identifier.
    func application(processIdentifier: pid_t) -> Element
    /// The app's window list. An entry that is not an Accessibility element is `nil`, so the list's
    /// count stays the count the app reported.
    func windows(of application: Element) -> LayoutAccessibilityRead<[Element?]>
    /// One attribute of a window, as the raw value Accessibility returned.
    func attribute(_ name: String, of window: Element) -> LayoutAccessibilityRead<AnyObject>
}

/// `LayoutWindowObserving` backed by the Accessibility API, reading only.
///
/// For each bundle identifier it looks up the running instances; exactly one instance that is
/// not known to be protected has its windows read. Every read is validated by type; a missing
/// attribute or a value of another type leaves that fact unknown. A window that could not be read
/// at all (element gone, app not answering, any other error) is left out of `windows` while still
/// counted in `reportedWindowCount`, so the observation reports an incomplete snapshot. When
/// access turns out to be off mid-way, nothing further is read and the remaining apps report an
/// unknown window list.
struct LayoutAccessibilityObserver<Reader: LayoutAccessibilityReading>: LayoutWindowObserving {
    /// Windows read per app at most; any further window leaves the snapshot incomplete.
    static var maximumWindowCount: Int { 64 }

    /// What is known about an app's running instance.
    enum RunningInstances: Equatable, Sendable {
        case none
        case one(pid_t)
        case several
        /// The instances could not be looked up.
        case unknown
    }

    private let reader: Reader
    private let runningInstances: (String) -> RunningInstances
    private let protection: (String) -> WindowObservations.TriState
    private let appReadBudget: TimeInterval
    private let now: () -> TimeInterval

    /// - Parameters:
    ///   - runningInstances: the running instances of the app with a bundle identifier.
    ///   - protection: whether the app is protected from layout work; `.unknown` (the default)
    ///     keeps `appRunningUnprotected` unknown for a running app, which the planners skip.
    ///   - appReadBudget: the longest time spent on one app's windows; reading stops after it and
    ///     the snapshot is incomplete. Each call is separately bounded by the messaging timeout.
    ///   - now: a monotonic clock in seconds.
    init(
        reader: Reader,
        runningInstances: @escaping (String) -> RunningInstances,
        protection: @escaping (String) -> WindowObservations.TriState = { _ in .unknown },
        appReadBudget: TimeInterval = 2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.reader = reader
        self.runningInstances = runningInstances
        self.protection = protection
        self.appReadBudget = appReadBudget
        self.now = now
    }

    func accessibilityPermission() -> LayoutAccessibilityPermission {
        reader.isProcessTrusted() ? .granted : .denied
    }

    func observeWindows(bundleIdentifiers: [String]) -> [LayoutWindowObservation] {
        // Without access, or for more apps than a plan accepts, no Accessibility call is made.
        guard bundleIdentifiers.count <= LayoutCapturePlanner.maximumObservationCount,
              reader.isProcessTrusted()
        else { return bundleIdentifiers.map { Self.unread($0, running: .unknown) } }

        var accessLost = false
        return bundleIdentifiers.map { identifier in
            guard !accessLost else { return Self.unread(identifier, running: .unknown) }
            let instances = runningInstances(identifier)
            let protected = protection(identifier)
            let running: WindowObservations.TriState
            switch (instances, protected) {
            case (.none, _): running = .no
            case (_, .yes): running = .no
            case (.one, .no): running = .yes
            default: running = .unknown
            }
            guard case .one(let processIdentifier) = instances, protected != .yes else {
                return Self.unread(identifier, running: running)
            }
            let result = observe(identifier, processIdentifier: processIdentifier, running: running)
            accessLost = result.accessLost
            return result.observation
        }
    }

    private static func unread(_ identifier: String, running: WindowObservations.TriState) -> LayoutWindowObservation {
        LayoutWindowObservation(
            bundleIdentifier: identifier, appRunningUnprotected: running, reportedWindowCount: nil, windows: []
        )
    }

    private func observe(
        _ identifier: String,
        processIdentifier: pid_t,
        running: WindowObservations.TriState
    ) -> (observation: LayoutWindowObservation, accessLost: Bool) {
        let start = now()
        let application = reader.application(processIdentifier: processIdentifier)
        let elements: [Reader.Element?]
        switch reader.windows(of: application) {
        case .value(let list): elements = list
        case .failure(let failure):
            return (Self.unread(identifier, running: running), failure == .accessDenied)
        }

        var windows: [LayoutWindowObservation.Window] = []
        reading: for element in elements.prefix(Self.maximumWindowCount) {
            guard now() - start <= appReadBudget else { break }
            // An entry that is not an element is counted but not described.
            guard let element else { continue }
            switch readWindow(element) {
            case .value(let window):
                windows.append(window)
            case .failure(.accessDenied):
                return (Self.unread(identifier, running: running), true)
            case .failure(.unresponsive):
                // An app that stopped answering is not asked about its other windows.
                break reading
            case .failure:
                continue
            }
        }
        return (LayoutWindowObservation(
            bundleIdentifier: identifier,
            appRunningUnprotected: running,
            reportedWindowCount: elements.count,
            windows: windows
        ), false)
    }

    /// One window's facts. A missing attribute or a value of another type leaves that fact
    /// unknown; any other failure leaves the whole window unread.
    private func readWindow(_ element: Reader.Element) -> LayoutAccessibilityRead<LayoutWindowObservation.Window> {
        var values: [String: AnyObject] = [:]
        for name in Self.attributeNames {
            switch reader.attribute(name, of: element) {
            case .value(let value): values[name] = value
            case .failure(.missing): continue
            case .failure(let failure): return .failure(failure)
            }
        }
        let frame: CGRect?
        if let position = Self.point(values[kAXPositionAttribute]), let size = Self.size(values[kAXSizeAttribute]) {
            frame = CGRect(origin: position, size: size)
        } else {
            frame = nil
        }
        return .value(LayoutWindowObservation.Window(
            topLeftFrame: frame,
            role: Self.role(values[kAXRoleAttribute]),
            subrole: Self.subrole(values[kAXSubroleAttribute]),
            minimized: Self.boolean(values[kAXMinimizedAttribute]),
            // No public Accessibility attribute establishes these; they are never guessed.
            visible: .unknown,
            onCurrentSpace: .unknown,
            fullScreen: .unknown,
            identifiable: .unknown
        ))
    }

    /// The attributes read for each window, in order. No title, document or URL attribute.
    static var attributeNames: [String] {
        [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute]
    }

    // MARK: - Typed values

    private static func string(_ value: AnyObject?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func role(_ value: AnyObject?) -> LayoutWindowObservation.Role {
        guard let role = string(value) else { return .unknown }
        return role == kAXWindowRole ? .window : .other
    }

    static func subrole(_ value: AnyObject?) -> LayoutWindowObservation.Subrole {
        guard let subrole = string(value) else { return .unknown }
        switch subrole {
        case kAXStandardWindowSubrole: return .standardWindow
        case kAXDialogSubrole, kAXSystemDialogSubrole: return .dialog
        default: return .other
        }
    }

    /// A Core Foundation boolean only: a number is not read as a boolean.
    static func boolean(_ value: AnyObject?) -> WindowObservations.TriState {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unknown }
        return CFBooleanGetValue((value as! CFBoolean)) ? .yes : .no
    }

    private static func axValue(_ value: AnyObject?, type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    /// A finite point.
    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let axValue = axValue(value, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    /// A finite, non-negative size. A negative extent is not standardized into another rectangle.
    static func size(_ value: AnyObject?) -> CGSize? {
        guard let axValue = axValue(value, type: .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size),
              size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0
        else { return nil }
        return size
    }
}

// MARK: - Accessibility API

/// `LayoutAccessibilityReading` backed by `AXUIElement`. Reads only.
struct SystemLayoutAccessibilityReader: LayoutAccessibilityReading {
    /// Longest wait, in seconds, for one answer from another app. Set on this process's side of
    /// each element; it sends nothing to the app.
    static let messagingTimeout: Float = 1

    func isProcessTrusted() -> Bool {
        // The plain check: it never asks macOS to show its permission request.
        AXIsProcessTrusted()
    }

    func application(processIdentifier: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    func windows(of application: AXUIElement) -> LayoutAccessibilityRead<[AXUIElement?]> {
        switch copy(kAXWindowsAttribute, of: application) {
        case .failure(let failure): return .failure(failure)
        case .value(let value):
            guard CFGetTypeID(value) == CFArrayGetTypeID() else { return .failure(.failed) }
            let items = (value as! CFArray) as [AnyObject]
            return .value(items.map { item in
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
                let window = item as! AXUIElement
                AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
                return window
            })
        }
    }

    func attribute(_ name: String, of window: AXUIElement) -> LayoutAccessibilityRead<AnyObject> {
        copy(name, of: window)
    }

    private func copy(_ name: String, of element: AXUIElement) -> LayoutAccessibilityRead<AnyObject> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return .failure(LayoutAccessibilityReadFailure(error)) }
        guard let value else { return .failure(.missing) }
        return .value(value)
    }
}

extension LayoutAccessibilityObserver where Reader == SystemLayoutAccessibilityReader {
    /// The observer for the running system. Running instances that have terminated are ignored.
    /// Only plain bundle identifiers are looked up; a path, website or file identity (any "/" or
    /// ":") has unknown running instances and is not read.
    init(protection: @escaping (String) -> WindowObservations.TriState = { _ in .unknown }) {
        self.init(
            reader: SystemLayoutAccessibilityReader(),
            runningInstances: { identifier in
                guard !identifier.isEmpty, !identifier.contains("/"), !identifier.contains(":") else { return .unknown }
                let instances = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .filter { !$0.isTerminated }
                switch instances.count {
                case 0: return .none
                case 1: return .one(instances[0].processIdentifier)
                default: return .several
                }
            },
            protection: protection
        )
    }
}
