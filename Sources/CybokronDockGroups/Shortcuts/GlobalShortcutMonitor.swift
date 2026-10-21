import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Notices the global group shortcuts (the chosen modifiers plus 1…9).
///
/// They are registered as system-wide hot keys (`CarbonHotKeys`): those work in every app, this
/// one included, without Accessibility access, and take the key press, so the app in front doesn't
/// receive it. Nothing asks for Accessibility access then. (Versions that only watched key presses
/// asked for it once; the `didPromptAccessibility` default remembering that is left as it is.)
///
/// When a hot key doesn't register (`GlobalShortcutMode.eventMonitors`), the shortcuts fall back
/// to watching key presses with event monitors, as those versions did: a local one while this app
/// or its popup has the keyboard, and a global one for other apps, which macOS feeds only to apps
/// allowed under Privacy & Security → Accessibility. The fallback doesn't show the system's
/// Accessibility prompt: it would come out of the blue, without a word of why. Settings → Shortcuts
/// & Siri says why the access is needed and opens the list; meanwhile `AccessibilityTrustMonitor`
/// checks for it, and the global monitor is installed again once it's granted. Monitors observe key
/// presses without taking them: the app in front receives them as well. The hot keys are tried
/// again whenever the shortcut settings change.
@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    /// How the shortcuts are noticed now.
    @Published private(set) var mode: GlobalShortcutMode = .off
    /// Whether the app may observe key presses in other apps; matters only for `.eventMonitors`.
    @Published private(set) var isAccessibilityTrusted: Bool

    private let preferences: PreferencesStore
    private let trust: AccessibilityTrustMonitor
    private let hotKeys: GroupHotKeyRegistrar
    private let onShortcut: (Int) -> Void
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Shortcuts")

    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Whether this monitor asked `trust` to keep checking access.
    private var isWatchingTrust = false
    private var subscriptions: Set<AnyCancellable> = []
    /// The settings the shortcuts were set up for.
    private var installed: (enabled: Bool, modifiers: ShortcutModifiers)?

    /// - Parameters:
    ///   - trust: the access monitor; `AccessibilityTrustMonitor.shared` when `nil`.
    ///   - hotKeySystem: registers the hot keys; `CarbonHotKeys.shared` when `nil`.
    init(preferences: PreferencesStore, trust: AccessibilityTrustMonitor? = nil, hotKeySystem: HotKeyRegistering? = nil,
         onShortcut: @escaping (Int) -> Void) {
        self.preferences = preferences
        let trust = trust ?? .shared
        self.trust = trust
        hotKeys = GroupHotKeyRegistrar(system: hotKeySystem ?? CarbonHotKeys.shared)
        self.onShortcut = onShortcut
        isAccessibilityTrusted = trust.isTrusted
        hotKeys.onShortcut = { [weak self] digit in self?.trigger(digit) }
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

    // MARK: - Hot keys and monitors

    private func applyPreferences() {
        let settings = (enabled: preferences.preferences.shortcutsEnabled, modifiers: preferences.preferences.shortcutModifiers)
        if let installed, installed == settings { return }
        installed = settings
        removeMonitors()
        let mode = hotKeys.apply(enabled: settings.enabled, modifiers: settings.modifiers)
        self.mode = mode
        switch mode {
        case .off:
            stopWatchingTrust()
            logger.notice("Global shortcuts are off")
        case .hotKeys:
            stopWatchingTrust()
            logger.notice("Global shortcuts on as hot keys: \(settings.modifiers.symbols, privacy: .public)1…9")
        case .eventMonitors(let status):
            refreshTrust()
            installMonitors(modifiers: settings.modifiers)
            if isAccessibilityTrusted {
                stopWatchingTrust()
            } else {
                startWatchingTrust()
            }
            logger.error("Couldn't register the global shortcuts as hot keys (OSStatus \(status, privacy: .public)): watching key presses instead, Accessibility access \(self.isAccessibilityTrusted ? "granted" : "not granted", privacy: .public)")
        }
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

    // MARK: - Accessibility access (event monitors only)

    /// Reads access again now.
    func refreshTrust() {
        trust.refresh()
        trustChanged(to: trust.isTrusted)
    }

    private func trustChanged(to trusted: Bool) {
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        guard let installed, case .eventMonitors = mode else { return }
        logger.notice("Accessibility access for watching the global shortcuts \(trusted ? "granted" : "revoked", privacy: .public)")
        if trusted {
            if localMonitor != nil {
                installGlobalMonitor(modifiers: installed.modifiers)
            }
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
