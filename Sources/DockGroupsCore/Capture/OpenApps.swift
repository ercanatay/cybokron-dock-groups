import AppKit
import CoreGraphics

/// A running app as capturing the open apps reads it: copied once from `NSRunningApplication`, so
/// nothing stays live and a plan can be made (and tested) from plain values.
public struct OpenApp: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    /// `localizedName`.
    public let name: String?
    /// Whether it's a regular app (`activationPolicy == .regular`): a Dock icon and a menu bar
    /// while it runs. Only those are ever listed.
    public let isRegular: Bool
    public let isHidden: Bool
    /// When LaunchServices started it; `nil` for apps started another way.
    public let launchDate: Date?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        bundleURL: URL?,
        name: String?,
        isRegular: Bool = true,
        isHidden: Bool = false,
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
        self.launchDate = launchDate
    }
}

/// Which processes have windows, from the window server's window list — its owner, layer, bounds,
/// alpha and on-screen fields only. Those need no permission and reading them never asks for one
/// (the window server only checks, without asking, whether to add names); a window's name (Screen
/// Recording) is never read.
///
/// A window counts when it's on the normal layer (0), not fully transparent, and at least
/// `minimumSize` points wide and high; a window off screen also must not be a square at the left
/// edge of the screen (x = 0). Every app keeps such invisible helper windows off screen — strips
/// as wide as the screen and 30 points high for its menu bar, and squares of 64, 370 or 500 points
/// at x = 0 (docs/design/capture-spike.md) — while the windows a hidden app, a minimized window or
/// another Space keeps off screen sit where they were shown. It's a guess without the Accessibility
/// API, which is why capturing uses it only for the first selection, never to decide which apps are
/// listed (spec Decision 4).
public struct WindowSnapshot: Equatable, Sendable {
    /// The smallest width and height of a window that counts, in points.
    public static let minimumSize: Double = 50

    /// Processes with at least one window that counts, on screen or not (hidden apps' windows,
    /// minimized windows and windows on other Spaces are off screen).
    public let processesWithWindows: Set<pid_t>
    /// Processes by their frontmost window on screen that counts, front first, each once.
    public let onScreenOrder: [pid_t]

    public init(processesWithWindows: Set<pid_t>, onScreenOrder: [pid_t]) {
        self.processesWithWindows = processesWithWindows
        self.onScreenOrder = onScreenOrder
    }

    /// The snapshot of two window lists as `CGWindowListCopyWindowInfo` returns them: `onScreen`,
    /// front to back (`.optionOnScreenOnly`), and `all` windows, on screen or not (`.optionAll`).
    /// Entries without an owner, a layer or bounds don't count.
    public init(onScreen: [[String: Any]], all: [[String: Any]]) {
        var order: [pid_t] = []
        var seen = Set<pid_t>()
        var withWindows = Set<pid_t>()
        for window in onScreen {
            guard let owner = Self.countingOwner(of: window, isOnScreen: true) else { continue }
            withWindows.insert(owner)
            if seen.insert(owner).inserted {
                order.append(owner)
            }
        }
        for window in all {
            if let owner = Self.countingOwner(of: window, isOnScreen: Self.isOnScreen(window)) {
                withWindows.insert(owner)
            }
        }
        processesWithWindows = withWindows
        onScreenOrder = order
    }

    /// The process owning `window` when the window counts (see the type's description), else `nil`.
    /// Reads `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowAlpha` and `kCGWindowBounds` only;
    /// `isOnScreen` comes from `kCGWindowIsOnscreen` (`isOnScreen(_:)`).
    static func countingOwner(of window: [String: Any], isOnScreen: Bool) -> pid_t? {
        guard let owner = number(window[kCGWindowOwnerPID as String]),
              let layer = number(window[kCGWindowLayer as String]), layer == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = number(bounds["Width"]), let height = number(bounds["Height"]),
              width >= minimumSize, height >= minimumSize
        else { return nil }
        // The header lists alpha among the keys every window has; one without it is opaque.
        if let alpha = number(window[kCGWindowAlpha as String]), alpha <= 0 {
            return nil
        }
        if !isOnScreen, number(bounds["X"]) == 0, width == height {
            return nil
        }
        return pid_t(exactly: owner)
    }

    /// Whether the window list says `window` is on screen (`kCGWindowIsOnscreen`; absent: it isn't).
    static func isOnScreen(_ window: [String: Any]) -> Bool {
        (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// A number from the window list (an `NSNumber` there, a Swift number in tests).
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let value as Int: return Double(value)
        case let value as Int32: return Double(value)
        case let value as Double: return value
        case let value as CGFloat: return Double(value)
        default: return nil
        }
    }
}

/// Everything a capture is planned from, read at one moment: before the app comes to the front, so
/// the app the user was working in is the most recent one (spec §2.6).
public struct OpenAppsSnapshot: Equatable, Sendable {
    public let apps: [OpenApp]
    /// `nil` when the window server didn't answer: nothing is then known about windows, and the
    /// window option can't be used.
    public let windows: WindowSnapshot?
    public let history: ActivationHistory

    public init(apps: [OpenApp], windows: WindowSnapshot?, history: ActivationHistory = ActivationHistory()) {
        self.apps = apps
        self.windows = windows
        self.history = history
    }
}

/// Reads the running apps and the window list for capturing. The app's implementation asks
/// `NSWorkspace` and the window server; tests use a fake.
@MainActor
public protocol OpenAppsReading: AnyObject {
    /// The apps running now, terminated ones left out, in the order macOS lists them. Apps that
    /// aren't regular may be left out too: they're never listed or counted.
    func openApps() -> [OpenApp]
    /// The window list, or `nil` when the window server didn't answer.
    func windows() -> WindowSnapshot?
}

extension OpenAppsReading {
    /// The running apps and the window list now, with `history` as it is.
    public func snapshot(history: ActivationHistory) -> OpenAppsSnapshot {
        OpenAppsSnapshot(apps: openApps(), windows: windows(), history: history)
    }
}

/// `OpenAppsReading` backed by `NSWorkspace.runningApplications` and `CGWindowListCopyWindowInfo`.
/// Neither needs a permission or asks for one: the window list withholds the windows' names from
/// an app without Screen Recording access, and those are never read anyway. Nothing here uses the
/// Accessibility API.
@MainActor
public final class SystemOpenAppsReader: OpenAppsReading {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    /// Regular apps only: capturing never lists the others, and skipping them before reading
    /// anything else of theirs takes the read from about 10 ms to under 1 ms on a Mac with 325
    /// processes (docs/design/capture-spike.md).
    public func openApps() -> [OpenApp] {
        workspace.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular, !application.isTerminated else { return nil }
            return OpenApp(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                name: application.localizedName,
                isRegular: true,
                isHidden: application.isHidden,
                launchDate: application.launchDate
            )
        }
    }

    /// Two reads of the window list: the windows on screen, which the window server lists front to
    /// back, and all windows, for the ones off screen.
    public func windows() -> WindowSnapshot? {
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return WindowSnapshot(onScreen: onScreen, all: all)
    }
}
