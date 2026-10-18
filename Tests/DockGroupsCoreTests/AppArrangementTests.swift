import Foundation
import Testing
@testable import DockGroupsCore

private func app(_ name: String) -> AppReference {
    AppReference(bundleIdentifier: "com.example.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", name: name)
}

@Suite("Sorting apps by name")
@MainActor
struct SortAppsTests {
    @Test func sortsLikeFinderAndKeepsTiesInOrder() {
        let first = AppReference(bundleIdentifier: "com.example.first", name: "Notes")
        let second = AppReference(bundleIdentifier: "com.example.second", name: "Notes")
        let apps = [app("Safari"), second, app("App 10"), first, app("mail"), app("App 9")]

        let sorted = DockGroup.sortedByName(apps)
        #expect(sorted.map(\.name) == ["App 9", "App 10", "mail", "Notes", "Notes", "Safari"])
        #expect(sorted.filter { $0.name == "Notes" } == [second, first])
    }

    @Test func sortedOrderIsSaved() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json"))
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addApps([app("Safari"), app("Mail"), app("Calendar")], toGroup: group.id)

        store.sortAppsByName(inGroup: group.id)

        #expect(store.group(withID: group.id)?.apps.map(\.name) == ["Calendar", "Mail", "Safari"])
        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.group(withID: group.id)?.apps.map(\.name) == ["Calendar", "Mail", "Safari"])
    }

    @Test func sortingASortedGroupChangesNothing() throws {
        let persistence = MemoryPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addApps([app("Calendar"), app("Mail")], toGroup: group.id)
        let saves = persistence.saveCount

        store.sortAppsByName(inGroup: group.id)
        store.sortAppsByName(inGroup: UUID())

        #expect(persistence.saveCount == saves)
    }
}

/// Keeps the groups in memory and counts the saves.
private final class MemoryPersistence: GroupPersisting {
    private(set) var saved: [DockGroup] = []
    private(set) var saveCount = 0

    func loadGroups() throws -> [DockGroup] { saved }

    func saveGroups(_ groups: [DockGroup]) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}
