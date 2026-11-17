import Combine
import Foundation
import OSLog

/// Keeps the usage statistics behind the Most Used list and saves them.
///
/// Launches and activations are recorded only while `isRecordingEnabled` says so — the app ties it
/// to the Most Used setting, asked at every event — so turning Most Used off stops recording at
/// once; what was recorded before is kept (Clear History deletes it), and turning it back on
/// records new events from then on.
///
/// Launches are recorded in memory right away and written in the background a few seconds later;
/// launches in quick succession (opening a whole group) are coalesced into one write. Statistics
/// that can't be read are moved aside and counting starts over: they're cheap to rebuild, so the
/// app never stops recording because of them.
///
/// It also keeps the Local Suggestions state (`SuggestionState`, `suggestions-state.json`): while
/// Suggestions are on, a recorded launch counts its local calendar day as an active day, once per
/// day. Clear History deletes that file too.
@MainActor
public final class UsageStore: ObservableObject {
    public nonisolated static let defaultSaveDelay: Duration = .seconds(3)

    @Published public private(set) var stats: UsageStats
    /// The Local Suggestions state; always fresh without a `suggestionPersistence`.
    @Published public private(set) var suggestionState: SuggestionState

    private var tracker: UsageTracker
    private let persistence: UsagePersisting
    private let saveDelay: Duration
    private let now: () -> Date
    private let isRecordingEnabled: @MainActor () -> Bool
    private let suggestionPersistence: SuggestionStatePersisting?
    private let areSuggestionsEnabled: @MainActor () -> Bool
    private let calendar: Calendar
    /// Set while `suggestionState` has a change that isn't written yet.
    private var suggestionStateNeedsSave = false
    private var pendingSave: Task<Void, Never>?
    private let writeQueue = DispatchQueue(label: "com.cybokron.dockgroups.usage-writes", qos: .utility)
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "UsageStore")

    /// - Parameters:
    ///   - saveDelay: How long to wait for further launches before writing. `.zero` writes
    ///     synchronously after every change.
    ///   - now: The clock; tests pass their own.
    ///   - isRecordingEnabled: Asked at every launch and activation; while it's `false` nothing is
    ///     recorded.
    ///   - suggestionPersistence: Where the Local Suggestions state is kept; without one it's
    ///     neither loaded nor saved.
    ///   - areSuggestionsEnabled: Whether Suggestions are on (`PopupPreferences.showsSuggestions`);
    ///     asked at every recorded launch.
    ///   - calendar: The local calendar active days are counted in; tests pass their own.
    public init(
        persistence: UsagePersisting,
        sessionLength: TimeInterval = UsageTracker.defaultSessionLength,
        saveDelay: Duration = UsageStore.defaultSaveDelay,
        now: @escaping () -> Date = Date.init,
        isRecordingEnabled: @escaping @MainActor () -> Bool = { true },
        suggestionPersistence: SuggestionStatePersisting? = nil,
        areSuggestionsEnabled: @escaping @MainActor () -> Bool = { false },
        calendar: Calendar = .current
    ) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        self.now = now
        self.isRecordingEnabled = isRecordingEnabled
        self.suggestionPersistence = suggestionPersistence
        self.areSuggestionsEnabled = areSuggestionsEnabled
        self.calendar = calendar
        tracker = UsageTracker(sessionLength: sessionLength)
        stats = UsageStats()
        suggestionState = SuggestionState()
        loadFromDisk()
        loadSuggestionState()
    }

    /// Seconds an app stays in the session after its last launch or activation.
    public var sessionLength: TimeInterval {
        get { tracker.sessionLength }
        set { tracker.sessionLength = newValue }
    }

    /// The apps of the current session (lowercased bundle identifiers).
    public var sessionMembers: Set<String> { tracker.sessionMembers(at: now()) }

    /// Whether launches and activations are recorded right now.
    public var isRecording: Bool { isRecordingEnabled() }

    /// Records a launch of `app`; untracked system processes are ignored, and so is everything
    /// while recording is off.
    @discardableResult
    public func recordLaunch(of app: AppReference) -> Bool {
        let moment = now()
        guard isRecordingEnabled(), tracker.recordLaunch(of: app, at: moment) else { return false }
        stats = tracker.stats
        scheduleSave()
        if areSuggestionsEnabled(), suggestionState.recordActivity(at: moment, calendar: calendar) {
            saveSuggestionState()
        }
        return true
    }

    /// Turns Suggestions on or off in `preferences`. Turning them on (from off) starts a new
    /// observation window now: `enabledAt` is reset and the active days start over; the dismissals
    /// stay. Turning them off keeps the state file.
    public func setSuggestionsEnabled(_ enabled: Bool, in preferences: PreferencesStore) {
        let wasEnabled = preferences.preferences.showsSuggestions
        preferences.update { $0.showsSuggestions = enabled }
        guard enabled, !wasEnabled else { return }
        suggestionState.start(at: now())
        saveSuggestionState()
    }

    /// Records that a running app came to the front (nothing while recording is off).
    public func recordActivation(bundleIdentifier: String) {
        guard isRecordingEnabled() else { return }
        tracker.recordActivation(bundleIdentifier: bundleIdentifier, at: now())
    }

    /// The best-ranked apps for which `isAvailable` holds. Computed from the current statistics on
    /// every call, so it never shows an outdated list.
    public func mostUsed(limit: Int, isAvailable: (AppReference) -> Bool = { _ in true }) -> [MostUsedEntry] {
        MostUsedRanking.rank(stats, limit: limit, isAvailable: isAvailable)
    }

    /// Forgets every recorded launch and saves the empty statistics, and deletes the Local
    /// Suggestions state. While Suggestions are on, a new observation window starts now; it's
    /// written with the next active day (or when the app quits).
    public func clearHistory() {
        tracker.reset()
        stats = tracker.stats
        scheduleSave()
        suggestionState = SuggestionState()
        suggestionStateNeedsSave = false
        if let suggestionPersistence {
            do {
                try suggestionPersistence.deleteState()
            } catch {
                logger.error("Deleting the suggestions state failed: \(String(describing: error), privacy: .public)")
            }
        }
        restartSuggestionWindowIfNeeded()
    }

    /// Writes a pending change right away and waits for it. Call before the app quits.
    public func flushPendingSave() {
        if suggestionStateNeedsSave {
            saveSuggestionState()
        }
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            let snapshot = stats
            let persistence = persistence
            writeQueue.sync { Self.write(snapshot, with: persistence) }
        } else {
            // A background write may still be running.
            writeQueue.sync {}
        }
    }

    private func loadFromDisk() {
        var loaded = UsageStats()
        do {
            loaded.apps = try persistence.loadLaunches()
        } catch {
            logger.error("Loading launch counts failed: \(String(describing: error), privacy: .public)")
            preserve("launch counts", persistence.preserveUnreadableLaunches)
        }
        do {
            loaded.cooccurrence = try persistence.loadCooccurrence()
        } catch {
            logger.error("Loading co-occurrence failed: \(String(describing: error), privacy: .public)")
            preserve("co-occurrence", persistence.preserveUnreadableCooccurrence)
        }
        tracker = UsageTracker(stats: loaded, sessionLength: tracker.sessionLength)
        stats = loaded
    }

    private func loadSuggestionState() {
        guard let suggestionPersistence else { return }
        do {
            var loaded = try suggestionPersistence.loadState()
            loaded.prune(now: now())
            suggestionState = loaded
        } catch {
            logger.error("Loading the suggestions state failed: \(String(describing: error), privacy: .public)")
            preserve("suggestions state", suggestionPersistence.preserveUnreadableState)
        }
        restartSuggestionWindowIfNeeded()
    }

    /// While Suggestions are on but the state has no `enabledAt` (none saved, unreadable, cleared),
    /// the observation window starts now, so they don't stay silent until turned off and on.
    private func restartSuggestionWindowIfNeeded() {
        guard suggestionPersistence != nil, suggestionState.enabledAt == nil, areSuggestionsEnabled() else { return }
        suggestionState.start(at: now())
        suggestionStateNeedsSave = true
    }

    /// Writes the suggestions state right away: it changes at most once a day and when the setting
    /// is turned on.
    private func saveSuggestionState() {
        suggestionStateNeedsSave = false
        guard let suggestionPersistence else { return }
        do {
            try suggestionPersistence.saveState(suggestionState)
        } catch {
            suggestionStateNeedsSave = true
            logger.error("Saving the suggestions state failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func preserve(_ what: String, _ move: () throws -> URL?) {
        do {
            if let backupURL = try move() {
                logger.notice("Kept the unreadable \(what, privacy: .public) at \(backupURL.path, privacy: .public)")
            }
        } catch {
            logger.error("Preserving unreadable \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard saveDelay > .zero else {
            pendingSave = nil
            Self.write(stats, with: persistence)
            return
        }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            let snapshot = self.stats
            let persistence = self.persistence
            self.writeQueue.async { Self.write(snapshot, with: persistence) }
        }
    }

    private nonisolated static func write(_ stats: UsageStats, with persistence: UsagePersisting) {
        do {
            try persistence.save(stats)
        } catch {
            Logger(subsystem: "com.cybokron.dockgroups", category: "UsageStore")
                .error("Saving usage statistics failed: \(String(describing: error), privacy: .public)")
        }
    }
}
