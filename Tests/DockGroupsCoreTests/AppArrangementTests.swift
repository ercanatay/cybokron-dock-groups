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

@Suite("Free layout")
@MainActor
struct FreeLayoutTests {
    private static let apps = ["A", "B", "C", "D", "E", "F", "G"].map(app)

    private func id(_ name: String) -> String { app(name).normalizedBundleIdentifier }

    /// Names by cell, `nil` for empty cells.
    private func cells(_ layout: FreeLayout) -> [String?] {
        let byID = Dictionary(uniqueKeysWithValues: Self.apps.map { ($0.normalizedBundleIdentifier, $0.name) })
        var cells = [String?](repeating: nil, count: layout.slotCount)
        for (key, slot) in layout.slots {
            cells[slot] = byID[key]
        }
        return cells
    }

    @Test func gridKeepsThePopupShape() {
        // 7 apps in 5 columns: 2 rows, so 3 empty cells at the end of the second row.
        let grid = PopupGridLayout(itemCount: 7, columns: .auto, maxRows: 4)
        #expect(grid.slotCount == 10)
        #expect(PopupGridLayout(itemCount: 3, columns: .fixed(10), maxRows: 4).slotCount == 3)

        let layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: grid.slotCount)
        #expect(cells(layout) == ["A", "B", "C", "D", "E", "F", "G", nil, nil, nil])
    }

    @Test func emptyCellsPastTheLastAppCanBeHit() {
        let metrics = PopupGridMetrics(cellWidth: 80, cellHeight: 90, spacing: 6, padding: 12)
        let grid = PopupGridLayout(itemCount: 7, columns: .fixed(3), maxRows: 4)
        let lastCell = grid.cellOrigin(at: 8, metrics: metrics)
        let center = CGPoint(x: lastCell.x + 40, y: lastCell.y + 45)

        #expect(grid.freeSlotIndex(at: center, metrics: metrics) == 8)
        #expect(grid.slotIndex(at: center, metrics: metrics) == 6)
        #expect(PopupGridLayout(itemCount: 0, columns: .auto, maxRows: 4).freeSlotIndex(at: center, metrics: metrics) == nil)
    }

    @Test func movingOneAppNeverShiftsTheOthers() {
        var layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10)

        // Three apps on top, four below: D and E go to the end of the second row.
        layout = layout.moving(app("D"), to: 8).moving(app("E"), to: 9)
        #expect(cells(layout) == ["A", "B", "C", nil, nil, "F", "G", nil, "D", "E"])

        // Dropping on another app swaps the two.
        layout = layout.moving(app("A"), to: 2)
        #expect(cells(layout) == ["C", "B", "A", nil, nil, "F", "G", nil, "D", "E"])

        // Out-of-range cells are clamped; dropping an app on its own cell changes nothing.
        #expect(cells(layout.moving(app("G"), to: 99)) == ["C", "B", "A", nil, nil, "F", "E", nil, "D", "G"])
        #expect(layout.moving(app("B"), to: 1) == layout)
        #expect(layout.moving(app("Z"), to: 0) == layout)

        // Removing an app leaves the others where they are.
        #expect(cells(layout.removing(app("B"))) == ["C", nil, "A", nil, nil, "F", "G", nil, "D", "E"])
    }

    @Test func savedCellsAreKeptAndTheRestFillTheFirstFreeCells() {
        let saved = [id("A"): 4, id("B"): 4, id("C"): 12, id("D"): 0, id("E"): -1]
        let layout = FreeLayout(apps: Array(Self.apps.prefix(5)), savedSlots: saved, slotCount: 5)

        // A keeps cell 4 (B, later in the list, loses it), D keeps 0; B, C (beyond the grid) and
        // E (invalid) fill the free cells in list order.
        #expect(cells(layout) == ["D", "B", "C", "E", "A"])
    }

    @Test func gridNeverHasFewerCellsThanApps() {
        let layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 2)
        #expect(layout.slotCount == 7)
        #expect(Set(layout.slots.values) == Set(0..<7))
    }

    // MARK: - Store

    private func makeStore(_ persistence: GroupPersisting = MemoryPersistence()) -> (GroupStore, DockGroup.ID) {
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addApps(Self.apps, toGroup: group.id)
        return (store, group.id)
    }

    @Test func arrangingSavesTheCellsAndListsTheAppsInReadingOrder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json"))
        let (store, groupID) = makeStore(persistence)
        let layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10)
            .moving(app("A"), to: 9)
            .moving(app("C"), to: 1)

        store.arrangeApps(inGroup: groupID, freeLayoutSlots: layout.slots)

        let group = try #require(store.group(withID: groupID))
        #expect(group.freeLayoutSlots == layout.slots)
        #expect(group.apps.map(\.name) == ["C", "B", "D", "E", "F", "G", "A"])
        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.group(withID: groupID) == group)
        #expect(FreeLayout(apps: group.apps, savedSlots: group.freeLayoutSlots, slotCount: 10) == layout)
    }

    @Test func arrangingTheSameCellsAgainDoesNotSave() {
        let persistence = MemoryPersistence()
        let (store, groupID) = makeStore(persistence)
        let slots = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10).moving(app("G"), to: 9).slots
        store.arrangeApps(inGroup: groupID, freeLayoutSlots: slots)
        let saves = persistence.saveCount

        store.arrangeApps(inGroup: groupID, freeLayoutSlots: slots)
        store.arrangeApps(inGroup: UUID(), freeLayoutSlots: slots)

        #expect(persistence.saveCount == saves)
    }

    @Test func reorderingTheListKeepsTheArrangementsShape() throws {
        let (store, groupID) = makeStore()
        let layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10)
            .moving(app("D"), to: 8)
            .moving(app("E"), to: 9)
        store.arrangeApps(inGroup: groupID, freeLayoutSlots: layout.slots)
        let occupied = Set(layout.slots.values)

        store.moveApp(bundleIdentifier: app("G").bundleIdentifier, inGroup: groupID, to: 0)
        var group = try #require(store.group(withID: groupID))
        #expect(Set(group.freeLayoutSlots.values) == occupied)
        #expect(group.freeLayoutSlots[id("G")] == 0)
        #expect(group.freeLayoutSlots[id("E")] == 9)

        store.sortAppsByName(inGroup: groupID)
        group = try #require(store.group(withID: groupID))
        #expect(Set(group.freeLayoutSlots.values) == occupied)
        #expect(group.apps.map { group.freeLayoutSlots[$0.normalizedBundleIdentifier]! } == occupied.sorted())
    }

    @Test func removingAnAppLeavesTheOthersInTheirCells() throws {
        let (store, groupID) = makeStore()
        let layout = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10).moving(app("G"), to: 9)
        store.arrangeApps(inGroup: groupID, freeLayoutSlots: layout.slots)

        store.removeApp(bundleIdentifier: app("B").bundleIdentifier, fromGroup: groupID)
        store.updateGroup(groupID) { $0.apps.removeAll { $0.name == "C" } }

        let group = try #require(store.group(withID: groupID))
        var expected = layout.slots
        expected[id("B")] = nil
        expected[id("C")] = nil
        #expect(group.freeLayoutSlots == expected)
    }

    // MARK: - Coding

    @Test func groupsWithoutCellsAreSavedAsBefore() throws {
        let group = DockGroup(name: "Work", apps: Array(Self.apps.prefix(2)))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any]
        #expect(object?.keys.contains("freeLayoutSlots") == false)
        #expect(object?.keys.contains("apps") == true)
    }

    @Test func cellsSurviveARoundTripAndBadOnesAreDropped() throws {
        let group = DockGroup(name: "Work", apps: Array(Self.apps.prefix(3)), freeLayoutSlots: [id("A"): 2, id("B"): 0])
        let decoded = try JSONDecoder().decode(DockGroup.self, from: JSONEncoder().encode(group))
        #expect(decoded == group)
        #expect(decoded.freeLayoutSlots == [id("A"): 2, id("B"): 0])

        let json = """
        {
          "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B",
          "name": "Edited",
          "apps": [
            { "bundleIdentifier": "com.example.a", "name": "A" },
            { "bundleIdentifier": "com.example.b", "name": "B" }
          ],
          "freeLayoutSlots": { "COM.EXAMPLE.A": 3, "com.example.b": 3, "com.example.gone": 1, "x": -2 }
        }
        """
        let edited = try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        #expect(edited.freeLayoutSlots == ["com.example.a": 3])

        let broken = #"{ "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Broken", "freeLayoutSlots": "nope" }"#
        #expect(try JSONDecoder().decode(DockGroup.self, from: Data(broken.utf8)).freeLayoutSlots.isEmpty)
    }

    @Test func preferenceIsSavedAsFreeLayoutAndOffByDefault() throws {
        #expect(PopupPreferences().usesFreeLayout == false)

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PopupPreferences(usesFreeLayout: true))) as? [String: Any]
        #expect(object?["freeLayout"] as? Bool == true)

        let decoded = try JSONDecoder().decode(PopupPreferences.self, from: Data(#"{ "freeLayout": true }"#.utf8))
        #expect(decoded.usesFreeLayout)
        let fallback = try JSONDecoder().decode(PopupPreferences.self, from: Data(#"{ "freeLayout": "yes" }"#.utf8))
        #expect(fallback.usesFreeLayout == false)

        // Standalone group apps show the popup the same way.
        let configuration = AgentConfiguration(group: DockGroup(name: "Work"), preferences: PopupPreferences(usesFreeLayout: true))
        #expect(try AgentConfiguration.decode(from: configuration.encoded()).preferences.usesFreeLayout)
    }
}
