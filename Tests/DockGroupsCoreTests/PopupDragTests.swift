import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Popup drag and drop")
struct PopupDragTests {
    private let metrics = PopupGridMetrics(cellWidth: 80, cellHeight: 90, spacing: 6, padding: 12)

    @Test func cellOriginsRunRowByRow() {
        let layout = PopupGridLayout(itemCount: 7, columns: .fixed(3), maxRows: 4)

        #expect(layout.cellOrigin(at: 0, metrics: metrics) == CGPoint(x: 12, y: 12))
        #expect(layout.cellOrigin(at: 2, metrics: metrics) == CGPoint(x: 12 + 2 * 86, y: 12))
        #expect(layout.cellOrigin(at: 3, metrics: metrics) == CGPoint(x: 12, y: 12 + 96))
        #expect(layout.cellOrigin(at: 6, metrics: metrics) == CGPoint(x: 12, y: 12 + 2 * 96))
    }

    @Test func everyCellCenterHitsItsOwnSlot() {
        let layout = PopupGridLayout(itemCount: 13, columns: .auto, maxRows: 2)
        for index in 0..<13 {
            let origin = layout.cellOrigin(at: index, metrics: metrics)
            let center = CGPoint(x: origin.x + metrics.cellWidth / 2, y: origin.y + metrics.cellHeight / 2)
            #expect(layout.slotIndex(at: center, metrics: metrics) == index)
        }
    }

    @Test func pointsBetweenOrBeyondCellsGoToTheNearestSlot() {
        let layout = PopupGridLayout(itemCount: 7, columns: .fixed(3), maxRows: 4)

        // Just left of the gap's middle between slots 0 and 1, and just right of it.
        #expect(layout.slotIndex(at: CGPoint(x: 12 + 80 + 2.9, y: 40), metrics: metrics) == 0)
        #expect(layout.slotIndex(at: CGPoint(x: 12 + 80 + 3.1, y: 40), metrics: metrics) == 1)
        // Above, left of and right of the grid.
        #expect(layout.slotIndex(at: CGPoint(x: 150, y: -200), metrics: metrics) == 1)
        #expect(layout.slotIndex(at: CGPoint(x: -50, y: 150), metrics: metrics) == 3)
        #expect(layout.slotIndex(at: CGPoint(x: 900, y: 150), metrics: metrics) == 5)
        // Past the last app (the empty end of the last row) and below the grid.
        #expect(layout.slotIndex(at: CGPoint(x: 250, y: 250), metrics: metrics) == 6)
        #expect(layout.slotIndex(at: CGPoint(x: 12, y: 2_000), metrics: metrics) == 6)
    }

    @Test func emptyGridHasNoSlots() {
        let layout = PopupGridLayout(itemCount: 0, columns: .auto, maxRows: 4)
        #expect(layout.slotIndex(at: CGPoint(x: 20, y: 20), metrics: metrics) == nil)
    }

    @Test func dropOutcomes() {
        #expect(PopupDrop(sourceIndex: 2, targetIndex: 2, isInRemovalArea: false) == .none)
        #expect(PopupDrop(sourceIndex: 2, targetIndex: 0, isInRemovalArea: false) == .move(to: 0))
        #expect(PopupDrop(sourceIndex: 2, targetIndex: 2, isInRemovalArea: true) == .remove)
        #expect(PopupDrop(sourceIndex: 0, targetIndex: 4, isInRemovalArea: true) == .remove)
    }

    @Test func removalAreaStartsBeyondTheMargin() {
        let frame = CGRect(x: 100, y: 50, width: 400, height: 300)
        #expect(!PopupDrag.isRemovalLocation(CGPoint(x: 300, y: 200), panelFrame: frame))
        #expect(!PopupDrag.isRemovalLocation(CGPoint(x: 95, y: 200), panelFrame: frame))
        #expect(!PopupDrag.isRemovalLocation(CGPoint(x: 300, y: 50 + 300 + PopupDrag.removalMargin - 1), panelFrame: frame))
        #expect(PopupDrag.isRemovalLocation(CGPoint(x: 100 - PopupDrag.removalMargin - 1, y: 200), panelFrame: frame))
        #expect(PopupDrag.isRemovalLocation(CGPoint(x: 300, y: 400), panelFrame: frame))
    }

    @Test func previewOrderMovesOrHidesTheDraggedApp() {
        let ids = ["a", "b", "c", "d"]
        #expect(PopupDrag.previewOrder(ids, moving: "a", to: 2) == ["b", "c", "a", "d"])
        #expect(PopupDrag.previewOrder(ids, moving: "d", to: 0) == ["d", "a", "b", "c"])
        #expect(PopupDrag.previewOrder(ids, moving: "b", to: 1) == ids)
        #expect(PopupDrag.previewOrder(ids, moving: "b", to: 99) == ["a", "c", "d", "b"])
        #expect(PopupDrag.previewOrder(ids, moving: "c", to: nil) == ["a", "b", "d"])
        #expect(PopupDrag.previewOrder(ids, moving: "x", to: 0) == ids)
    }
}

@Suite("Moving one app")
@MainActor
struct GroupStoreMoveAppTests {
    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let notes = AppReference(bundleIdentifier: "com.apple.Notes", name: "Notes")

    @Test func movedAppKeepsItsNewPlaceAfterARestart() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json"))
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addApps([Self.safari, Self.mail, Self.notes], toGroup: group.id)

        store.moveApp(bundleIdentifier: "com.apple.notes", inGroup: group.id, to: 0)
        #expect(store.group(withID: group.id)?.apps == [Self.notes, Self.safari, Self.mail])
        store.moveApp(bundleIdentifier: Self.notes.bundleIdentifier, inGroup: group.id, to: 99)
        #expect(store.group(withID: group.id)?.apps == [Self.safari, Self.mail, Self.notes])

        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.group(withID: group.id)?.apps == [Self.safari, Self.mail, Self.notes])
    }

    @Test func unknownAppsOrGroupsAndNoOpMovesDoNotSave() {
        let persistence = CountingPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addApps([Self.safari, Self.mail], toGroup: group.id)
        let saves = persistence.saveCount

        store.moveApp(bundleIdentifier: Self.mail.bundleIdentifier, inGroup: group.id, to: 1)
        store.moveApp(bundleIdentifier: "com.example.missing", inGroup: group.id, to: 0)
        store.moveApp(bundleIdentifier: Self.mail.bundleIdentifier, inGroup: UUID(), to: 0)

        #expect(persistence.saveCount == saves)
        #expect(store.group(withID: group.id)?.apps == [Self.safari, Self.mail])
    }

    @Test func quickReordersAreCoalescedIntoOneWrite() {
        let persistence = CountingPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .seconds(60))
        let group = store.addGroup(named: "Work")
        store.addApps([Self.safari, Self.mail, Self.notes], toGroup: group.id)

        store.moveApp(bundleIdentifier: Self.notes.bundleIdentifier, inGroup: group.id, to: 0)
        store.moveApp(bundleIdentifier: Self.mail.bundleIdentifier, inGroup: group.id, to: 0)
        #expect(persistence.saveCount == 0)

        store.flushPendingSave()
        #expect(persistence.saveCount == 1)
        #expect(persistence.saved?.first?.apps == [Self.mail, Self.notes, Self.safari])
    }
}

/// In-memory persistence that counts writes.
private final class CountingPersistence: GroupPersisting {
    private(set) var saveCount = 0
    private(set) var saved: [DockGroup]?

    func loadGroups() throws -> [DockGroup] { [] }
    func saveGroups(_ groups: [DockGroup]) throws {
        saveCount += 1
        saved = groups
    }
    func preserveUnreadableData() throws -> URL? { nil }
}
