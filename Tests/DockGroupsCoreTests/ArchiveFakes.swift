import Foundation
@testable import DockGroupsCore

/// Keeps active and archived groups in memory, as the groups file does, and counts the saves.
final class MemoryStoredGroupsPersistence: GroupPersisting {
    private(set) var saveCount = 0
    private(set) var saved = StoredGroups()

    init(_ stored: StoredGroups = StoredGroups()) {
        saved = stored
    }

    func loadGroups() throws -> [DockGroup] { saved.active }

    func saveGroups(_ groups: [DockGroup]) throws {
        try saveStoredGroups(StoredGroups(active: groups))
    }

    func loadStoredGroups() throws -> StoredGroups { saved }

    func saveStoredGroups(_ groups: StoredGroups) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}

extension GroupStore {
    /// A store over `stored`, saving at once.
    @MainActor
    static func archiving(_ stored: StoredGroups = StoredGroups()) -> (GroupStore, MemoryStoredGroupsPersistence) {
        let persistence = MemoryStoredGroupsPersistence(stored)
        return (GroupStore(persistence: persistence, saveDelay: .zero), persistence)
    }
}
