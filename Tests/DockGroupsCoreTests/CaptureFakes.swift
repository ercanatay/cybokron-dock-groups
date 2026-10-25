import CoreGraphics
import Foundation
@testable import DockGroupsCore

/// The running apps and the window list, as a test sets them (`OpenAppsReading`).
@MainActor
final class FakeOpenAppsReader: OpenAppsReading {
    var apps: [OpenApp]
    var windowSnapshot: WindowSnapshot?
    private(set) var readCount = 0

    init(apps: [OpenApp] = [], windows: WindowSnapshot? = nil) {
        self.apps = apps
        windowSnapshot = windows
    }

    func openApps() -> [OpenApp] {
        readCount += 1
        return apps
    }

    func windows() -> WindowSnapshot? { windowSnapshot }
}

/// Running apps for the planner, by hand.
enum CaptureApps {
    /// A regular app at "/Applications/<name>.app" unless `path` says otherwise; `launched` is
    /// seconds after 2026-10-01.
    static func app(
        _ bundleIdentifier: String?,
        _ name: String,
        pid: pid_t,
        path: String? = nil,
        regular: Bool = true,
        hidden: Bool = false,
        launched: TimeInterval? = nil
    ) -> OpenApp {
        OpenApp(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: path ?? "/Applications/\(name).app", isDirectory: true),
            name: name,
            isRegular: regular,
            isHidden: hidden,
            launchDate: launched.map { Date(timeIntervalSince1970: 1_790_812_800 + $0) }
        )
    }

    static let xcode = app("com.apple.dt.Xcode", "Xcode", pid: 101)
    static let safari = app("com.apple.Safari", "Safari", pid: 102)
    static let terminal = app("com.apple.Terminal", "Terminal", pid: 103, path: "/System/Applications/Utilities/Terminal.app")
    static let mail = app("com.apple.mail", "Mail", pid: 104, path: "/System/Applications/Mail.app")
    static let music = app("com.apple.Music", "Music", pid: 105, path: "/System/Applications/Music.app")

    /// A snapshot where every listed pid has a window on screen, front to back in `onScreen`.
    static func windows(onScreen: [pid_t], offScreen: [pid_t] = []) -> WindowSnapshot {
        WindowSnapshot(processesWithWindows: Set(onScreen + offScreen), onScreenOrder: onScreen)
    }

    /// One entry of `CGWindowListCopyWindowInfo`'s list, as the window server writes it.
    /// `onScreen` writes `kCGWindowIsOnscreen` as the window server does: `true` when on screen,
    /// absent otherwise.
    static func window(
        pid: pid_t, layer: Int = 0, x: Double = 120, y: Double = 80, width: Double = 800, height: Double = 600,
        alpha: Double? = 1, onScreen: Bool = false, name: String? = nil
    ) -> [String: Any] {
        var window: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: ["X": NSNumber(value: x), "Y": NSNumber(value: y), "Width": NSNumber(value: width), "Height": NSNumber(value: height)],
            kCGWindowNumber as String: NSNumber(value: Int(pid) * 10),
        ]
        if let alpha { window[kCGWindowAlpha as String] = NSNumber(value: alpha) }
        if onScreen { window[kCGWindowIsOnscreen as String] = NSNumber(value: true) }
        if let name { window[kCGWindowName as String] = name }
        return window
    }
}
