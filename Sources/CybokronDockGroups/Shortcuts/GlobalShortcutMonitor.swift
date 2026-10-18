import AppKit
import ApplicationServices
import Combine
import DockGroupsCore
import OSLog

/// Watches for the global group shortcuts (the chosen modifiers plus 1…9) with two event monitors:
/// a local one for key presses while this app or its popup has the keyboard, and a global one for
/// key presses in other apps. macOS delivers other apps' key presses only to apps allowed under
/// Privacy & Security → Accessibility, so the monitor asks for that access — once, the first time
/// shortcuts are on — and keeps checking until it's granted (through `AccessibilityTrustMonitor`).
///
/// A global monitor observes key presses without consuming them: the app in front receives the
/// key press as well.
@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    /// Whether the app may observe key presses in other apps.
    @Published private(set) var isAccessibilityTrusted: Bool

    /// Remembers that the system's Accessibility prompt was shown, so it appears only once.
    static let didPromptAccessibilityKey = "didPromptAccessibility"

    private let preferences: PreferencesStore
    private let trust: AccessibilityTrustMonitor
    private let defaults: UserDefaults
    private let onShortcut: (Int) -> Void
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Shortcuts")

    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Whether this monitor asked `trust` to keep checking access.
    private var isWatchingTrust = false
    private var subscriptions: Set<AnyCancellable> = []
    /// The settings the monitors were installed for.
    private var installed: (enabled: Bool, modifiers: ShortcutModifiers)?

    /// - Parameter trust: the access monitor; `AccessibilityTrustMonitor.shared` when `nil`.
    init(preferences: PreferencesStore, trust: AccessibilityTrustMonitor? = nil, defaults: UserDefaults = .standard,
         onShortcut: @escaping (Int) -> Void) {
        self.preferences = preferences
        let trust = trust ?? .shared
        self.trust = trust
        self.defaults = defaults
        self.onShortcut = onShortcut
        isAccessibilityTrusted = trust.isTrusted
    }

    /// Starts following the shortcut preferences. Call once the app has finished launching.
    func start() {
        // @Published fires before the value changes; the main-queue hop reads the new value.
        preferences.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &subscriptions)
        // The monitor reads access again when the app becomes active and while it's watched.
        trust.$isTrusted
            .sink { [weak self] trusted in self?.trustChanged(to: trusted) }
            .store(in: &subscriptions)
        applyPreferences()
    }

    /// Opens the Accessibility list in System Settings, where the app can be allowed.
    func openAccessibilitySettings() {
        AccessibilityAccess.openSettings()
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
        AccessibilityAccess.promptOnce(rememberedBy: Self.didPromptAccessibilityKey, defaults: defaults)
        logger.notice("Asked for Accessibility access for the global shortcuts")
        refreshTrust()
    }

    /// Reads access again now.
    func refreshTrust() {
        trust.refresh()
        trustChanged(to: trust.isTrusted)
    }

    private func trustChanged(to trusted: Bool) {
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        logger.notice("Accessibility access for the global shortcuts \(trusted ? "granted" : "revoked", privacy: .public)")
        guard let installed, installed.enabled else { return }
        if trusted {
            installGlobalMonitor(modifiers: installed.modifiers)
            stopWatchingTrust()
        } else {
            startWatchingTrust()
        }
    }

    /// Access is granted in System Settings, which doesn't notify the app; `trust` checks every
    /// second while it's missing.
    private func startWatchingTrust() {
        guard !isWatchingTrust else { return }
        isWatchingTrust = true
        trust.beginObserving()
    }

    private func stopWatchingTrust() {
        guard isWatchingTrust else { return }
        isWatchingTrust = false
        trust.endObserving()
    }
}
