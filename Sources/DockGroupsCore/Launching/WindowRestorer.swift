import AppKit
import ApplicationServices

/// A running app whose hidden windows can be brought back. `NSRunningApplication` is one.
public protocol RestorableApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isHidden: Bool { get }
    /// Un-hides the app, as clicking it in the Dock would. Returns `false` when that wasn't possible.
    func unhide() -> Bool
}

extension NSRunningApplication: RestorableApplication {}

/// One of another app's windows, as the Accessibility API reports it.
@MainActor
public protocol AccessibleWindow: AnyObject {
    /// Whether the window is minimized into the Dock.
    var isMinimized: Bool { get }
    /// Whether it's a regular window, not a panel, sheet, dialog or palette.
    var isStandard: Bool { get }
    /// Brings the window back from the Dock. Returns `false` when the app refused.
    func restore() -> Bool
    /// Puts the window in front of the app's other windows.
    func raise()
}

/// Reads and changes other apps' windows, which needs Accessibility access (Privacy & Security →
/// Accessibility).
@MainActor
public protocol WindowAccessibility: AnyObject {
    /// Whether this app has Accessibility access.
    var isTrusted: Bool { get }
    /// The windows of the app with this process identifier, front to back; `nil` when they can't be
    /// read.
    func windows(ofProcess processIdentifier: pid_t) -> [any AccessibleWindow]?
}

/// Brings back a running app's windows, as clicking its Dock icon does: un-hides the app and, when
/// every one of its windows is minimized, restores them from the Dock. Restoring minimized windows
/// needs Accessibility access; without it the app is only un-hidden.
@MainActor
public final class WindowRestorer {
    /// What `restore(_:)` did.
    public struct Outcome: Equatable, Sendable {
        /// The app was hidden and has been un-hidden.
        public var unhid: Bool
        /// How many minimized windows came back.
        public var restoredWindowCount: Int

        public init(unhid: Bool, restoredWindowCount: Int) {
            self.unhid = unhid
            self.restoredWindowCount = restoredWindowCount
        }
    }

    private let accessibility: WindowAccessibility

    public init(accessibility: WindowAccessibility) {
        self.accessibility = accessibility
    }

    public convenience init() {
        self.init(accessibility: SystemWindowAccessibility())
    }

    /// Whether minimized windows can be restored at all (Accessibility access is granted).
    public var canRestoreMinimizedWindows: Bool { accessibility.isTrusted }

    public func restore(_ app: any RestorableApplication) -> Outcome {
        let unhid = app.isHidden && app.unhide()
        guard accessibility.isTrusted, let windows = accessibility.windows(ofProcess: app.processIdentifier) else {
            return Outcome(unhid: unhid, restoredWindowCount: 0)
        }
        // Back to front, so the frontmost of them ends up in front.
        let restored = Self.windowsToRestore(windows).reversed().filter { $0.restore() }
        restored.last?.raise()
        return Outcome(unhid: unhid, restoredWindowCount: restored.count)
    }

    /// The windows a click on the app's Dock icon brings back: all of its minimized windows when
    /// none of its standard windows is left out of the Dock, and none when one is. A hidden app's
    /// windows aren't minimized; un-hiding brings them back.
    public static func windowsToRestore(_ windows: [any AccessibleWindow]) -> [any AccessibleWindow] {
        guard !windows.contains(where: { $0.isStandard && !$0.isMinimized }) else { return [] }
        return windows.filter(\.isMinimized)
    }
}

// MARK: - Accessibility API

/// `WindowAccessibility` backed by the Accessibility API (`AXUIElement`).
@MainActor
public final class SystemWindowAccessibility: WindowAccessibility {
    /// Longest wait for an app that doesn't answer, so a hung app can't stall this one for long.
    private static let messagingTimeout: Float = 1

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func windows(ofProcess processIdentifier: pid_t) -> [any AccessibleWindow]? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return nil }
        return elements.map { AXWindow(element: $0) }
    }
}

@MainActor
private final class AXWindow: AccessibleWindow {
    private let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    var isMinimized: Bool {
        attribute(kAXMinimizedAttribute) as? Bool ?? false
    }

    var isStandard: Bool {
        attribute(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }

    func restore() -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
