import Foundation
import OSLog

/// Loads and saves the triggers' runtime state.
public protocol TriggerStatePersisting {
    /// The saved state; a missing, unreadable or newer file is a fresh state (it only holds
    /// conveniences, nothing worth keeping aside).
    func loadState() -> TriggerState
    func saveState(_ state: TriggerState) throws
}

/// Stores the `TriggerState` as JSON, by default in
/// `~/Library/Application Support/Cybokron/DockGroups/trigger-state.json`. Kept apart from
/// `triggers.json` because it changes with every event, not with the user's choices, and never
/// part of a backup.
public struct JSONFileTriggerStatePersistence: TriggerStatePersisting {
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: "trigger-state.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileTriggerStatePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadState() -> TriggerState {
        guard let data = try? Data(contentsOf: fileURL) else { return TriggerState() }
        return Self.decode(data)
    }

    public func saveState(_ state: TriggerState) throws {
        try JSONFileSupport.write(state, to: fileURL)
    }

    /// The state in `data`; fresh when it isn't a state this version reads.
    static func decode(_ data: Data) -> TriggerState {
        struct Header: Decodable {
            var formatVersion: Int?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              (header.formatVersion ?? TriggerState.currentFormatVersion) <= TriggerState.currentFormatVersion,
              let state = try? JSONDecoder().decode(TriggerState.self, from: data)
        else { return TriggerState() }
        return state
    }
}

/// Keeps the triggers' runtime state and writes it at most once a second while it changes (triggers
/// spec §2.7, §5), and right away on `flushPendingSave()` (before the app quits).
@MainActor
public final class TriggerStateStore {
    public private(set) var state: TriggerState

    private let persistence: TriggerStatePersisting
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private var lastSaved: TriggerState?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// - Parameter saveDelay: How long changes are gathered before a write; `.zero` writes after
    ///   every change.
    public init(persistence: TriggerStatePersisting = JSONFileTriggerStatePersistence(), saveDelay: Duration = .seconds(1)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        state = persistence.loadState()
        lastSaved = state
    }

    /// Takes the new state; it's written once the changes of the next second are in. An unchanged
    /// state writes nothing.
    public func update(_ newState: TriggerState) {
        state = newState
        guard newState != lastSaved else { return }
        guard saveDelay > .zero else {
            writeToDisk()
            return
        }
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    /// Writes a pending change right away.
    public func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        writeToDisk()
    }

    private func writeToDisk() {
        pendingSave = nil
        guard state != lastSaved else { return }
        do {
            try persistence.saveState(state)
            lastSaved = state
        } catch {
            logger.error("Saving the triggers' state failed: \(String(describing: error), privacy: .public)")
        }
    }
}
