import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Dock tile list")
struct DockTileListTests {
    private let agentID = AgentIdentity.bundleIdentifier(for: UUID(uuidString: "1A2B3C4D-0000-4000-8000-00000000AAAA")!)
    private let agentURL = URL(fileURLWithPath: "/Users/me/Library/Application Support/Cybokron/DockGroups/Agents/work.app", isDirectory: true)

    /// A tile as the Dock writes it, with data this app doesn't know.
    private func dockWritten(bundleIdentifier: String, path: String, label: String) -> DockTileEntry {
        [
            "GUID": 1_234_567,
            "tile-type": "file-tile",
            "tile-data": [
                "book": Data([1, 2, 3]),
                "bundle-identifier": bundleIdentifier,
                "dock-extra": 0,
                "file-data": ["_CFURLString": URL(fileURLWithPath: path, isDirectory: true).absoluteString, "_CFURLStringType": 15],
                "file-label": label,
                "file-mod-date": 99,
                "file-type": 41,
                "parent-mod-date": 98,
            ] as [String: Any],
        ]
    }

    private var safari: DockTileEntry {
        dockWritten(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", label: "Safari")
    }

    @Test func newEntryIsAnApplicationFileTile() throws {
        let entry = DockTileList.makeEntry(bundleIdentifier: agentID, bundleURL: agentURL, label: "Work")
        #expect(entry["tile-type"] as? String == "file-tile")
        let data = try #require(entry["tile-data"] as? [String: Any])
        #expect(data["file-type"] as? Int == 41)
        #expect(data["file-label"] as? String == "Work")
        let fileData = try #require(data["file-data"] as? [String: Any])
        #expect(fileData["_CFURLStringType"] as? Int == 15)
        #expect(fileData["_CFURLString"] as? String == "file:///Users/me/Library/Application%20Support/Cybokron/DockGroups/Agents/work.app/")
        #expect(DockTileList.bundleIdentifier(of: entry) == agentID)
        #expect(DockTileList.fileURL(of: entry)?.path == agentURL.path)
        // The entry is a valid property list, as the Dock's preferences require.
        #expect(PropertyListSerialization.propertyList(entry, isValidFor: .binary))
    }

    @Test func upsertingAppendsANewTileAtTheEnd() throws {
        let updated = try #require(DockTileList.upserting(bundleIdentifier: agentID, bundleURL: agentURL, label: "Work", in: [safari]))
        #expect(updated.count == 2)
        #expect(DockTileList.bundleIdentifier(of: updated[0]) == "com.apple.Safari")
        #expect(DockTileList.bundleIdentifier(of: updated[1]) == agentID)
        #expect(DockTileList.agentBundleIdentifiers(in: updated) == [agentID])
    }

    @Test func upToDateTileIsNoChange() {
        let existing = dockWritten(bundleIdentifier: agentID, path: agentURL.path, label: "Work")
        #expect(DockTileList.upserting(bundleIdentifier: agentID, bundleURL: agentURL, label: "Work", in: [safari, existing]) == nil)
        #expect(DockTileList.updating(bundleIdentifier: agentID, bundleURL: agentURL, label: "Work", in: [safari, existing]) == nil)
    }

    @Test func movedAgentKeepsItsPlaceAndDropsStaleFileData() throws {
        let existing = dockWritten(bundleIdentifier: agentID.lowercased(), path: "/old/place/work.app", label: "Work")
        let renamed = agentURL.deletingLastPathComponent().appending(path: "office.app", directoryHint: .isDirectory)
        let updated = try #require(DockTileList.updating(bundleIdentifier: agentID, bundleURL: renamed, label: "Office", in: [existing, safari]))

        #expect(updated.count == 2)
        #expect(DockTileList.fileURL(of: updated[0])?.path == renamed.path)
        #expect(DockTileList.label(of: updated[0]) == "Office")
        let data = try #require(updated[0]["tile-data"] as? [String: Any])
        #expect(data["book"] == nil && data["file-mod-date"] == nil && data["parent-mod-date"] == nil)
        // What the Dock wrote that isn't about the file stays.
        #expect(updated[0]["GUID"] as? Int == 1_234_567)
        #expect(data["dock-extra"] as? Int == 0)
    }

    @Test func relabelingKeepsTheFileData() throws {
        let existing = dockWritten(bundleIdentifier: agentID, path: agentURL.path, label: "Work")
        let updated = try #require(DockTileList.updating(bundleIdentifier: agentID, bundleURL: agentURL, label: "WORK", in: [existing]))
        let data = try #require(updated[0]["tile-data"] as? [String: Any])
        #expect(data["file-label"] as? String == "WORK")
        #expect(data["book"] as? Data == Data([1, 2, 3]))
    }

    @Test func updatingNeverAddsATile() {
        #expect(DockTileList.updating(bundleIdentifier: agentID, bundleURL: agentURL, label: "Work", in: [safari]) == nil)
    }

    @Test func removingTakesOutOnlyTheGivenTiles() throws {
        let existing = dockWritten(bundleIdentifier: agentID, path: agentURL.path, label: "Work")
        let entries = [safari, existing, ["tile-type": "spacer-tile", "tile-data": [String: Any]()]]
        let updated = try #require(DockTileList.removing(bundleIdentifiers: [agentID.lowercased()], from: entries))
        #expect(updated.count == 2)
        #expect(DockTileList.bundleIdentifiers(in: updated) == ["com.apple.Safari"])
        #expect(DockTileList.removing(bundleIdentifiers: [agentID], from: updated) == nil)
    }

    @Test func pathStringTilesAreUnderstood() {
        let entry: DockTileEntry = [
            "tile-data": ["file-data": ["_CFURLString": "/Applications/Mail.app", "_CFURLStringType": 0]] as [String: Any],
        ]
        #expect(DockTileList.fileURL(of: entry)?.path == "/Applications/Mail.app")
        #expect(DockTileList.bundleIdentifier(of: entry) == nil)
    }
}

/// Keeps the Dock's list in memory, as `SystemDockTileStore` keeps it in the Dock's preferences.
final class InMemoryDockTileStore: DockTileStoring {
    var entries: [DockTileEntry]
    private(set) var saveCount = 0

    init(entries: [DockTileEntry] = []) {
        self.entries = entries
    }

    func loadPersistentApps() -> [DockTileEntry] { entries }

    func savePersistentApps(_ entries: [DockTileEntry]) throws {
        self.entries = entries
        saveCount += 1
    }
}

@Suite("Dock tile store round trip")
struct DockTileStoreRoundTripTests {
    @Test func addingThenRemovingRestoresTheList() throws {
        let store = InMemoryDockTileStore(entries: [
            DockTileList.makeEntry(bundleIdentifier: "com.apple.Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"), label: "Safari"),
        ])
        let id = AgentIdentity.bundleIdentifier(for: UUID())
        let url = URL(fileURLWithPath: "/tmp/Agents/work.app", isDirectory: true)

        try store.savePersistentApps(#require(DockTileList.upserting(bundleIdentifier: id, bundleURL: url, label: "Work", in: store.loadPersistentApps())))
        #expect(DockTileList.agentBundleIdentifiers(in: store.loadPersistentApps()) == [id])

        try store.savePersistentApps(#require(DockTileList.removing(bundleIdentifiers: [id], from: store.loadPersistentApps())))
        #expect(DockTileList.bundleIdentifiers(in: store.loadPersistentApps()) == ["com.apple.Safari"])
        #expect(store.saveCount == 2)
    }
}
