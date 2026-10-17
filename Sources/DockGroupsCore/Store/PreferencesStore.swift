import Combine
import Foundation
import OSLog

/// The single source of truth for the app-wide popup preferences.
///
/// Changes are saved shortly after they happen, coalescing quick successions into one write. A
/// preferences file that can't be read is moved aside and the defaults are used instead: unlike
/// the group list, preferences are cheap to set again, so the app never refuses to save them.
@MainActor
public final class PreferencesStore: ObservableObject {
    @Published public private(set) var preferences: PopupPreferences
    /// Describes the most recent failed save, `nil` once a save succeeds.
    @Published public private(set) var saveProblem: String?

    private let persistence: PreferencesPersisting
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "PreferencesStore")

    /// - Parameter saveDelay: How long to wait for further changes before writing. `.zero` writes
    ///   synchronously after every change.
    public init(persistence: PreferencesPersisting, saveDelay: Duration = .milliseconds(250)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        preferences = PopupPreferences()
        loadFromDisk()
    }

    /// Applies `change`; out-of-range values are replaced by their defaults.
    public func update(_ change: (inout PopupPreferences) -> Void) {
        var edited = preferences
        change(&edited)
        edited = edited.sanitized()
        guard edited != preferences else { return }
        preferences = edited
        scheduleSave()
    }

    /// Writes a pending change right away. Call before the app quits.
    public func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        writeToDisk()
    }

    private func loadFromDisk() {
        do {
            preferences = try persistence.loadPreferences()?.sanitized() ?? PopupPreferences()
        } catch {
            logger.error("Loading preferences failed: \(String(describing: error), privacy: .public)")
            do {
                if let backupURL = try persistence.preserveUnreadableData() {
                    logger.notice("Kept the unreadable preferences at \(backupURL.path, privacy: .public)")
                }
            } catch {
                logger.error("Preserving unreadable preferences failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard saveDelay > .zero else {
            writeToDisk()
            return
        }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    private func writeToDisk() {
        pendingSave = nil
        do {
            try persistence.savePreferences(preferences)
            saveProblem = nil
        } catch {
            logger.error("Saving preferences failed: \(String(describing: error), privacy: .public)")
            saveProblem = "Your settings couldn't be saved: \(error.localizedDescription)"
        }
    }
}
