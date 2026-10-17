import AppKit
import ApplicationServices
import Combine
import DockGroupsCore
import OSLog

/// Watches for the global group shortcuts (the chosen modifiers plus 1…9) with two event monitors:
/// a local one for key presses while this app or its popup has the keyboard, and a global one for
/// key presses in other apps. macOS delivers other apps' key presses only to apps allowed under
/// Privacy & Security → Accessibility, so the monitor asks for that access — once, the first time
/// shortcuts are on — and keeps checking until it's granted.
///
/// A global monitor observes key presses without consuming them: the app in front receives the
/// key press as well.
@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    /// Whether the app may observe key presses in other apps.
    @Published private(set) var isAccessibilityTrusted: Bool

    /// Remembers that the system's Accessibility prompt was shown, so it appears only once.
    static let didPromptAccessibilityKey = "didPromptAccessibility"
    private static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let preferences: PreferencesStore
    private let defaults: UserDefaults
    private let onShortcut: (Int) -> Void
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Shortcuts")

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var trustTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    /// The settings the monitors were installed for.
    private var installed: (enabled: Bool, modifiers: ShortcutModifiers)?

    init(preferences: PreferencesStore, defaults: UserDefaults = .standard, onShortcut: @escaping (Int) -> Void) {
        self.preferences = preferences
        self.defaults = defaults
        self.onShortcut = onShortcut
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// Starts following the shortcut preferences. Call once the app has finished launching.
    func start() {
        // @Published fires before the value changes; the main-queue hop reads the new value.
        preferences.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshTrust() }
            .store(in: &subscriptions)
        applyPreferences()
    }

    /// Opens the Accessibility list in System Settings, where the app can be allowed.
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }

    // MARK: - Monitors

    private func applyPreferences() {
        let settings = (enabled: preferences.preferences.shortcutsEnabled, modifiers: preferences.preferences.shortcutModifiers)
        if let installed, installed == settings { return }
        installed = settings
        removeMonitors()
        guard settings.enabled else {
            stopWatchingTrust()
            logger.notice("Global shortcuts are off")
            return
        }
        promptForAccessibilityOnce()
        installMonitors(modifiers: settings.modifiers)
        if isAccessibilityTrusted {
            stopWatchingTrust()
        } else {
            startWatchingTrust()
        }
        logger.notice("Global shortcuts on: \(settings.modifiers.symbols, privacy: .public)1…9, accessibility \(self.isAccessibilityTrusted ? "granted" : "not granted", privacy: .public)")
    }

    private func installMonitors(modifiers: ShortcutModifiers) {
        // Monitors run on the main thread; only Sendable values cross into the isolated blocks.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let digit = GroupShortcuts.digit(keyCode: event.keyCode, modifierFlags: event.modifierFlags, modifiers: modifiers) else {
                return event
            }
            if !event.isARepeat {
                MainActor.assumeIsolated { self?.trigger(digit) }
            }
            return nil
        }
        installGlobalMonitor(modifiers: modifiers)
    }

    /// The global monitor is installed again once access is granted: one installed without access
    /// may stay deaf.
    private func installGlobalMonitor(modifiers: ShortcutModifiers) {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat,
                  let digit = GroupShortcuts.digit(keyCode: event.keyCode, modifierFlags: event.modifierFlags, modifiers: modifiers)
            else { return }
            MainActor.assumeIsolated { self?.trigger(digit) }
        }
    }

    private func removeMonitors() {
        for monitor in [localMonitor, globalMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }

    private func trigger(_ digit: Int) {
        logger.debug("Shortcut \(digit)")
        onShortcut(digit)
    }

    // MARK: - Accessibility access

    /// Shows the system's Accessibility prompt the first time shortcuts are on without access.
    private func promptForAccessibilityOnce() {
        refreshTrust()
        guard !isAccessibilityTrusted, !defaults.bool(forKey: Self.didPromptAccessibilityKey) else { return }
        defaults.set(true, forKey: Self.didPromptAccessibilityKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        logger.notice("Asked for Accessibility access for the global shortcuts")
    }

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        logger.notice("Accessibility access \(trusted ? "granted" : "revoked", privacy: .public)")
        guard let installed, installed.enabled else { return }
        if trusted {
            installGlobalMonitor(modifiers: installed.modifiers)
            stopWatchingTrust()
        } else {
            startWatchingTrust()
        }
    }

    /// Access is granted in System Settings, which doesn't notify the app; check every few seconds.
    private func startWatchingTrust() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
    }

    private func stopWatchingTrust() {
        trustTimer?.invalidate()
        trustTimer = nil
    }
}
