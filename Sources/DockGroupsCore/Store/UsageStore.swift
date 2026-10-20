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
@MainActor
public final class UsageStore: ObservableObject {
    public nonisolated static let defaultSaveDelay: Duration = .seconds(3)

    @Published public private(set) var stats: UsageStats

    private var tracker: UsageTracker
    private let persistence: UsagePersisting
    private let saveDelay: Duration
    private let now: () -> Date
    private let isRecordingEnabled: @MainActor () -> Bool
    private var pendingSave: Task<Void, Never>?
    private let writeQueue = DispatchQueue(label: "com.cybokron.dockgroups.usage-writes", qos: .utility)
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "UsageStore")

    /// - Parameters:
    ///   - saveDelay: How long to wait for further launches before writing. `.zero` writes
    ///     synchronously after every change.
    ///   - now: The clock; tests pass their own.
    ///   - isRecordingEnabled: Asked at every launch and activation; while it's `false` nothing is
    ///     recorded.
    public init(
        persistence: UsagePersisting,
        sessionLength: TimeInterval = UsageTracker.defaultSessionLength,
        saveDelay: Duration = UsageStore.defaultSaveDelay,
        now: @escaping () -> Date = Date.init,
        isRecordingEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        self.now = now
        self.isRecordingEnabled = isRecordingEnabled
        tracker = UsageTracker(sessionLength: sessionLength)
        stats = UsageStats()
        loadFromDisk()
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
        guard isRecordingEnabled(), tracker.recordLaunch(of: app, at: now()) else { return false }
        stats = tracker.stats
        scheduleSave()
        return true
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

    /// Forgets every recorded launch and saves the empty statistics.
    public func clearHistory() {
        tracker.reset()
        stats = tracker.stats
        scheduleSave()
    }

    /// Writes a pending change right away and waits for it. Call before the app quits.
    public func flushPendingSave() {
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
