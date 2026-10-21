import AppKit
import ApplicationServices
import DockGroupsCore
import OSLog

/// Accessibility access (Privacy & Security → Accessibility): restoring a running app's minimized
/// windows needs it to reach them, and the global shortcuts, when they can't be hot keys and are
/// watched for instead, to notice key presses in other apps.
@MainActor
enum AccessibilityAccess {
    /// Remembers that the prompt was shown for restoring windows, so it appears only once.
    static let didPromptForWindowsKey = "didPromptAccessibilityForWindows"
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Accessibility")

    /// For an app that is already switched on in the list but still lacks access. macOS ties the
    /// entry to the app's code signature; an ad hoc signed build (as this one is unless notarized)
    /// gets a new signature with every build and update, so an older entry stops matching while its
    /// switch stays on.
    static var staleEntryHint: String { L10n.Accessibility.staleEntryHint(AppInfo.name) }

    /// Shows the system's Accessibility prompt, which also lists the app under Privacy & Security →
    /// Accessibility, unless access is granted or the prompt was shown for `key` before. Returns
    /// whether access is granted.
    @discardableResult
    static func promptOnce(rememberedBy key: String, defaults: UserDefaults = .standard) -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility list in System Settings, where the app can be allowed.
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Asks for access — once — when `app` runs and seems to have only minimized windows: it isn't
    /// hidden and shows no window on screen. That's when restoring its windows needs access;
    /// apps that only need to come forward or un-hide don't.
    static func promptOnceForRestoringWindows(of app: AppReference, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didPromptForWindowsKey),
              !AXIsProcessTrusted(),
              let running = RunningApplicationLookup.runningApplications(identifiedBy: app.bundleIdentifier)
                  .first(where: { !$0.isTerminated }),
              !running.isHidden,
              !hasWindowOnScreen(processIdentifier: running.processIdentifier)
        else { return }
        logger.notice("Asking for Accessibility access to restore the minimized windows of \(app.bundleIdentifier, privacy: .public)")
        promptOnce(rememberedBy: didPromptForWindowsKey, defaults: defaults)
    }

    /// Whether the process shows a regular window on screen (in the current Space). The window
    /// list's owner and layer fields don't need Screen Recording access.
    private static func hasWindowOnScreen(processIdentifier: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return true }
        return windows.contains { window in
            window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier
                && window[kCGWindowLayer as String] as? Int == 0
        }
    }
}
