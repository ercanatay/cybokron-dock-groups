import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Notices the global shortcuts: the number shortcuts (the chosen modifiers plus 1…9) and the
/// groups' own shortcuts.
///
/// Both are registered as system-wide hot keys (`CarbonHotKeys`, through one
/// `GroupHotKeyRegistrar`): those work in every app, this one included, without Accessibility
/// access, and take the key press, so the app in front doesn't receive it. Nothing asks for
/// Accessibility access then. (Versions that only watched key presses asked for it once; the
/// `didPromptAccessibility` default remembering that is left as it is.)
///
/// When a number shortcut's hot key doesn't register (`GlobalShortcutMode.eventMonitors`), the
/// number shortcuts fall back to watching key presses with event monitors, as those versions did:
/// a local one while this app or its popup has the keyboard, and a global one for other apps,
/// which macOS feeds only to apps allowed under Privacy & Security → Accessibility. The fallback
/// doesn't show the system's Accessibility prompt: it would come out of the blue, without a word
/// of why. Settings → Shortcuts & Siri says why the access is needed and opens the list; meanwhile
/// `AccessibilityTrustMonitor` checks for it, and the global monitor is installed again once it's
/// granted. Monitors observe key presses without taking them: the app in front receives them as
/// well. The hot keys are tried again whenever the shortcut settings change.
///
/// Group shortcuts never fall back: each is registered on its own, from a plan of the active groups
/// (`GroupShortcutPlanner`; archived groups are never in `store.groups`), and one macOS refuses is
/// shown as off (`groupStatuses`). The plan is made again when a group's shortcut changes, when the
/// number shortcuts change, and when macOS's own shortcuts are read again (`refreshSystemShortcuts`).
/// While a shortcut is being recorded (`beginRecording`), every hot key and monitor is let go, so
/// the recorder receives the keys; `endRecording` brings them back.
@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    /// How the number shortcuts are noticed now.
    @Published private(set) var mode: GlobalShortcutMode = .off
    /// Whether the app may observe key presses in other apps; matters only for `.eventMonitors`.
    @Published private(set) var isAccessibilityTrusted: Bool
    /// The status of every active group's shortcut.
    @Published private(set) var groupStatuses: [DockGroup.ID: GroupShortcutStatus] = [:]
    /// Whether a shortcut is being recorded, with every hot key let go.
    @Published private(set) var isRecording = false

    private let preferences: PreferencesStore
    private let store: GroupStore
    private let trust: AccessibilityTrustMonitor
    private let systemShortcuts: SystemShortcutListing
    private let hotKeys: GroupHotKeyRegistrar
    private let onShortcut: (Int) -> Void
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Shortcuts")

    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Whether this monitor asked `trust` to keep checking access.
    private var isWatchingTrust = false
    private var subscriptions: Set<AnyCancellable> = []
    /// The settings the number shortcuts were set up for.
    private var installed: (enabled: Bool, modifiers: ShortcutModifiers)?
    /// macOS's own shortcuts as last read (rule K4).
    private var systemCombinations: Set<KeyCombination> = []
    /// The plan the group shortcuts were last registered with.
    private var lastPlan: GroupShortcutPlan?

    /// - Parameters:
    ///   - trust: the access monitor; `AccessibilityTrustMonitor.shared` when `nil`.
    ///   - hotKeySystem: registers the hot keys; `CarbonHotKeys.shared` when `nil`.
    ///   - systemShortcuts: macOS's own shortcuts; `SystemShortcuts` when `nil`.
    ///   - onGroupShortcut: called with the group and action of a pressed group shortcut.
    init(
        preferences: PreferencesStore,
        store: GroupStore,
        trust: AccessibilityTrustMonitor? = nil,
        hotKeySystem: HotKeyRegistering? = nil,
        systemShortcuts: SystemShortcutListing? = nil,
        onShortcut: @escaping (Int) -> Void,
        onGroupShortcut: @escaping (DockGroup.ID, GroupShortcutAction) -> Void
    ) {
        self.preferences = preferences
        self.store = store
        let trust = trust ?? .shared
        self.trust = trust
        self.systemShortcuts = systemShortcuts ?? SystemShortcuts()
        hotKeys = GroupHotKeyRegistrar(system: hotKeySystem ?? CarbonHotKeys.shared)
        self.onShortcut = onShortcut
        isAccessibilityTrusted = trust.isTrusted
        hotKeys.onShortcut = { [weak self] digit in self?.trigger(digit) }
        hotKeys.onGroupShortcut = { [weak self] id, action in
            self?.logger.debug("Group shortcut of \(id, privacy: .public): \(action.rawValue, privacy: .public)")
            onGroupShortcut(id, action)
        }
    }

    /// Starts following the shortcut preferences and the groups' shortcuts. Call once the app has
    /// finished launching.
    func start() {
        systemCombinations = systemShortcuts.enabledCombinations()
        // @Published fires before the value changes; the main-queue hop reads the new value.
        preferences.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &subscriptions)
        // Only the groups' shortcuts and their order matter: typing a name doesn't register again.
        store.$groups
            .map { groups in groups.compactMap { group in group.shortcut.map { ShortcutAssignment(groupID: group.id, shortcut: $0) } } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyGroupShortcuts() }
            .store(in: &subscriptions)
        // The monitor reads access again when the app becomes active and while it's watched.
        trust.$isTrusted
            .sink { [weak self] trusted in self?.trustChanged(to: trusted) }
            .store(in: &subscriptions)
        applyPreferences()
        applyGroupShortcuts()
    }

    /// Opens the Accessibility list in System Settings, where the app can be allowed.
    func openAccessibilitySettings() {
        AccessibilityAccess.openSettings()
    }

    // MARK: - Group shortcuts

    /// Why `keys` can't be `group`'s shortcut now (rules K1–K6); `nil` when they can. For the
    /// recorder: the same rules as the plan, with macOS's shortcuts as last read.
    func refusal(for keys: KeyCombination, group: DockGroup.ID) -> GroupShortcutRefusal? {
        GroupShortcutPlanner.refusal(
            for: keys,
            group: group,
            groups: store.groups,
            numbers: NumberShortcutSettings(preferences.preferences),
            system: systemCombinations
        )
    }

    /// Reads macOS's own shortcuts again — the user may have changed them in System Settings — and
    /// plans the group shortcuts again when they changed. Called when the group window or the
    /// Shortcuts pane shows.
    func refreshSystemShortcuts() {
        let combinations = systemShortcuts.enabledCombinations()
        guard combinations != systemCombinations else { return }
        systemCombinations = combinations
        applyGroupShortcuts()
    }

    /// Lets go of every hot key and monitor, so a shortcut recorder receives the keys they take.
    /// Every `beginRecording` needs its `endRecording`.
    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        systemCombinations = systemShortcuts.enabledCombinations()
        removeMonitors()
        hotKeys.suspend()
        groupStatuses = hotKeys.groupStatuses
        logger.notice("Recording a shortcut: the hot keys are let go")
    }

    /// Registers the hot keys again after `beginRecording`, with the settings and groups as they
    /// are now.
    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        // The number shortcuts as the settings are now: they may have changed while recording.
        adopt(hotKeys.resume(), modifiers: installed?.modifiers ?? preferences.preferences.shortcutModifiers)
        applyGroupShortcuts()
        logger.notice("Recording ended: the hot keys are back")
    }

    private func applyGroupShortcuts() {
        let plan = GroupShortcutPlanner.plan(
            groups: store.groups,
            numbers: NumberShortcutSettings(preferences.preferences),
            system: systemCombinations
        )
        if plan != lastPlan {
            lastPlan = plan
            hotKeys.applyGroupShortcuts(plan)
            let off = hotKeys.groupStatuses.values.filter { !$0.isOn && $0 != .paused }.count
            logger.notice("Group shortcuts: \(plan.registrations.count, privacy: .public) planned, \(off, privacy: .public) off")
            for (id, status) in hotKeys.groupStatuses {
                if case .unavailable(let code) = status {
                    logger.error("The shortcut of group \(id, privacy: .public) couldn't be registered (OSStatus \(code, privacy: .public))")
                }
            }
        }
        groupStatuses = hotKeys.groupStatuses
    }

    // MARK: - Hot keys and monitors

    private func applyPreferences() {
        let settings = (enabled: preferences.preferences.shortcutsEnabled, modifiers: preferences.preferences.shortcutModifiers)
        if let installed, installed == settings { return }
        installed = settings
        removeMonitors()
        let mode = hotKeys.apply(enabled: settings.enabled, modifiers: settings.modifiers)
        if isRecording {
            // Applied when the recording ends.
            return
        }
        adopt(mode, modifiers: settings.modifiers)
        // The number shortcuts' keys are rule K5's.
        applyGroupShortcuts()
    }

    /// Follows how the number shortcuts are noticed: nothing more for hot keys, event monitors
    /// (and the Accessibility check) when a hot key couldn't be registered.
    private func adopt(_ mode: GlobalShortcutMode, modifiers: ShortcutModifiers) {
        self.mode = mode
        switch mode {
        case .off:
            stopWatchingTrust()
            logger.notice("Global shortcuts are off")
        case .hotKeys:
            stopWatchingTrust()
            logger.notice("Global shortcuts on as hot keys: \(modifiers.symbols, privacy: .public)1…9")
        case .eventMonitors(let status):
            refreshTrust()
            installMonitors(modifiers: modifiers)
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
        guard let installed, case .eventMonitors = mode, !isRecording else { return }
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

/// A group's shortcut as the hot keys see it, for noticing when one changes.
private struct ShortcutAssignment: Equatable {
    let groupID: DockGroup.ID
    let shortcut: GroupShortcut
}
