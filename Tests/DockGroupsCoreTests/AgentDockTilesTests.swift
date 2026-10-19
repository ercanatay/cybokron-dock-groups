import Foundation
import Testing
@testable import DockGroupsCore

/// `AgentDockTiles`: the standalone groups' tiles in the Dock's app list, with an unreadable or
/// unwritable list, and the copies taken before each change.
@Suite("Agent Dock tiles")
struct AgentDockTilesTests {
    private let temporary: TemporaryDirectory
    private let backups: DockTileBackups

    init() throws {
        temporary = try TemporaryDirectory()
        backups = DockTileBackups(directory: temporary.url.appending(path: "dock-backups", directoryHint: .isDirectory))
    }

    private static let safari = DockTileList.makeEntry(
        bundleIdentifier: "com.apple.Safari",
        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
        label: "Safari"
    )

    private func group(_ name: String, standalone: Bool = true) -> DockGroup {
        DockGroup(name: name, isStandalone: standalone)
    }

    private func agentURL(_ name: String) -> URL {
        temporary.url.appending(components: "Agents", "\(name).app", directoryHint: .isDirectory)
    }

    private func tile(for group: DockGroup, installed: Bool = true) -> AgentTile {
        AgentTile(
            groupID: group.id,
            bundleIdentifier: AgentIdentity.bundleIdentifier(for: group.id),
            label: group.name,
            bundleURL: installed ? agentURL(group.name.lowercased()) : nil
        )
    }

    private func entry(for group: DockGroup) -> DockTileEntry {
        DockTileList.makeEntry(bundleIdentifier: AgentIdentity.bundleIdentifier(for: group.id), bundleURL: agentURL(group.name.lowercased()), label: group.name)
    }

    private func bundleIdentifiers(_ store: InMemoryDockTileStore) -> Set<String> {
        DockTileList.bundleIdentifiers(in: store.entries)
    }

    // MARK: - Unreadable list

    @Test func anUnreadableListTurnsNoGroupOffAndWritesNothing() {
        defer { temporary.remove() }
        let work = group("Work")
        let mail = group("Mail")
        let store = InMemoryDockTileStore(entries: [Self.safari, entry(for: work)])
        store.isReadable = false
        let tiles = AgentDockTiles(store: store, backups: backups)

        // "Can't read the Dock" isn't "the tiles are gone".
        #expect(tiles.groupsRemovedFromDock(among: [work, mail]) == nil)
        #expect(tiles.agentBundleIdentifiersInDock() == nil)

        tiles.requestAddition(of: mail.id)
        #expect(tiles.apply([tile(for: work), tile(for: mail)], standaloneGroupIDs: [work.id, mail.id]) == .unreadable)
        // Nor are tiles of agents that are gone removed from a list that couldn't be read.
        #expect(tiles.apply([], standaloneGroupIDs: []) == .unreadable)
        #expect(store.saveCount == 0 && store.failedSaveCount == 0)
        #expect(backups.copies().isEmpty)
        #expect(store.entries.count == 2, "the list wasn't touched")

        // The addition waits for a readable list.
        store.isReadable = true
        tiles.requestAddition(of: mail.id)
        #expect(tiles.apply([tile(for: work), tile(for: mail)], standaloneGroupIDs: [work.id, mail.id]) == .saved(previousCount: 2, count: 3))
        #expect(bundleIdentifiers(store).contains(AgentIdentity.bundleIdentifier(for: mail.id)))
    }

    @Test func plannerTurnsNoGroupOffWithoutTheDocksList() {
        defer { temporary.remove() }
        #expect(AgentPlanner.groupsRemovedFromDock(standaloneGroupIDs: [UUID(), UUID()], dockBundleIdentifiers: nil).isEmpty)
    }

    @Test func groupsWhoseTileWasDraggedOutAreFound() throws {
        defer { temporary.remove() }
        let kept = group("Kept")
        let removed = group("Removed")
        let waiting = group("Waiting")
        let store = InMemoryDockTileStore(entries: [Self.safari, entry(for: kept)])
        let tiles = AgentDockTiles(store: store, backups: backups)
        tiles.requestAddition(of: waiting.id)

        #expect(tiles.groupsRemovedFromDock(among: [kept, removed, waiting, group("Plain", standalone: false)]) == [removed.id])
        #expect(try #require(tiles.agentBundleIdentifiersInDock()) == [AgentIdentity.bundleIdentifier(for: kept.id).lowercased()])
    }

    // MARK: - Applying

    @Test func pendingGroupsGetTilesAndOthersAreOnlyUpdated() throws {
        defer { temporary.remove() }
        let work = group("Work")
        let renamed = group("Renamed")
        let notInDock = group("NotInDock")
        let gone = UUID()
        let goneEntry = DockTileList.makeEntry(bundleIdentifier: AgentIdentity.bundleIdentifier(for: gone), bundleURL: agentURL("gone"), label: "Gone")
        var oldName = entry(for: renamed)
        oldName = try #require(DockTileList.updating(bundleIdentifier: AgentIdentity.bundleIdentifier(for: renamed.id), bundleURL: agentURL("renamed"), label: "Old Name", in: [oldName])?.first)
        let store = InMemoryDockTileStore(entries: [Self.safari, goneEntry, oldName])
        let tiles = AgentDockTiles(store: store, backups: backups)
        tiles.requestAddition(of: work.id)

        let outcome = tiles.apply([tile(for: work), tile(for: renamed), tile(for: notInDock)], standaloneGroupIDs: [work.id, renamed.id, notInDock.id])

        #expect(outcome == .saved(previousCount: 3, count: 3))
        #expect(bundleIdentifiers(store) == [
            "com.apple.Safari",
            AgentIdentity.bundleIdentifier(for: renamed.id),
            AgentIdentity.bundleIdentifier(for: work.id),
        ], "the gone agent's tile went, the pending one was added, the tile the user removed didn't come back")
        #expect(store.entries.compactMap(DockTileList.label(of:)).contains("Renamed"))
        #expect(tiles.pendingAdditions.isEmpty)
        #expect(tiles.apply([tile(for: work), tile(for: renamed)], standaloneGroupIDs: [work.id, renamed.id]) == .unchanged)
        #expect(store.saveCount == 1)
    }

    @Test func aFailedSaveKeepsThePendingAdditions() {
        defer { temporary.remove() }
        let work = group("Work")
        let store = InMemoryDockTileStore(entries: [Self.safari])
        store.failsToSave = true
        let tiles = AgentDockTiles(store: store, backups: backups)
        tiles.requestAddition(of: work.id)

        let outcome = tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id])

        #expect(outcome == .saveFailed(message: DockTileStoreError.saveFailed.localizedDescription, groupIDs: [work.id]))
        #expect(tiles.pendingAdditions == [work.id], "the next pass tries again")
        #expect(store.entries.count == 1)

        store.failsToSave = false
        #expect(tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id]) == .saved(previousCount: 1, count: 2))
        #expect(tiles.pendingAdditions.isEmpty)
    }

    @Test func pendingAdditionsWaitForTheAgentAndEndWithTheGroup() {
        defer { temporary.remove() }
        let work = group("Work")
        let store = InMemoryDockTileStore(entries: [Self.safari])
        let tiles = AgentDockTiles(store: store, backups: backups)
        tiles.requestAddition(of: work.id)

        // Not installed yet: no tile, still pending.
        #expect(tiles.apply([tile(for: work, installed: false)], standaloneGroupIDs: [work.id]) == .unchanged)
        #expect(tiles.pendingAdditions == [work.id])
        // Turned off meanwhile: no longer pending.
        #expect(tiles.apply([], standaloneGroupIDs: []) == .unchanged)
        #expect(tiles.pendingAdditions.isEmpty)

        tiles.requestAddition(of: work.id)
        tiles.cancelAddition(of: work.id)
        #expect(tiles.pendingAdditions.isEmpty)
    }

    // MARK: - Restored groups

    @MainActor
    private func stores() -> (GroupStore, PreferencesStore) {
        (
            GroupStore(persistence: JSONFileGroupPersistence(fileURL: temporary.url.appending(path: "groups.json")), saveDelay: .zero),
            PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: temporary.url.appending(path: "preferences.json")), saveDelay: .zero)
        )
    }

    @MainActor
    @Test func restoredStandaloneGroupsGetTheirTilesInsteadOfBeingTurnedOff() throws {
        defer { temporary.remove() }
        let kept = group("Kept")
        let work = group("Work")
        let notes = group("Notes", standalone: false)
        let (groups, preferences) = stores()
        let backup = try SettingsBackup.decode(from: SettingsBackup(appVersion: "0.6.1", groups: [kept, work, notes], preferences: PopupPreferences()).encoded())
        try backup.restore(to: groups, preferences: preferences)
        let store = InMemoryDockTileStore(entries: [Self.safari, entry(for: kept)])
        let tiles = AgentDockTiles(store: store, backups: backups)

        // Without being adopted, the restored group would count as dragged out of the Dock.
        #expect(tiles.groupsRemovedFromDock(among: groups.groups) == [work.id])

        tiles.adoptRestored(groups.groups)

        #expect(tiles.pendingAdditions == [work.id], "the group whose tile is there keeps it as it is")
        #expect(tiles.groupsRemovedFromDock(among: groups.groups) == [], "no group is turned off")

        // The pass that follows the restore adds the missing tile.
        let standalone = groups.groups.filter(\.isStandalone)
        let outcome = tiles.apply(standalone.map { tile(for: $0) }, standaloneGroupIDs: Set(standalone.map(\.id)))

        #expect(outcome == .saved(previousCount: 2, count: 3))
        #expect(bundleIdentifiers(store) == ["com.apple.Safari", AgentIdentity.bundleIdentifier(for: kept.id), AgentIdentity.bundleIdentifier(for: work.id)])
        #expect(tiles.pendingAdditions.isEmpty)
        #expect(tiles.groupsRemovedFromDock(among: groups.groups) == [])
        #expect(groups.groups.filter(\.isStandalone).map(\.id) == [kept.id, work.id])
    }

    @MainActor
    @Test func mergedStandaloneGroupsGetTheirTiles() throws {
        defer { temporary.remove() }
        let (groups, _) = stores()
        groups.addGroup(named: "Mine")
        let merged = group("Merged")
        let result = try SettingsBackup(appVersion: "0.6.1", groups: [merged], preferences: PopupPreferences()).merge(into: groups)
        let store = InMemoryDockTileStore(entries: [Self.safari])
        let tiles = AgentDockTiles(store: store, backups: backups)

        tiles.adoptRestored(result.addedGroups)

        #expect(tiles.pendingAdditions == [merged.id])
        #expect(tiles.groupsRemovedFromDock(among: groups.groups) == [])
        #expect(tiles.apply([tile(for: merged)], standaloneGroupIDs: [merged.id]) == .saved(previousCount: 1, count: 2))
    }

    @Test func restoredGroupsWaitForAnUnreadableDock() {
        defer { temporary.remove() }
        let work = group("Work")
        let store = InMemoryDockTileStore(entries: [Self.safari, entry(for: work)])
        store.isReadable = false
        let tiles = AgentDockTiles(store: store, backups: backups)

        tiles.adoptRestored([work, group("Notes", standalone: false)])

        // Adding updates a tile that's there, so waiting for every standalone group is safe.
        #expect(tiles.pendingAdditions == [work.id])
        store.isReadable = true
        #expect(tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id]) == .unchanged)
        #expect(store.entries.count == 2, "no second tile")
    }

    // MARK: - Backups

    @Test func theListIsCopiedBeforeEachChange() throws {
        defer { temporary.remove() }
        let work = group("Work")
        let store = InMemoryDockTileStore(entries: [Self.safari])
        let tiles = AgentDockTiles(store: store, backups: backups)
        tiles.requestAddition(of: work.id)

        #expect(tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id]) == .saved(previousCount: 1, count: 2))

        let copy = try #require(backups.copies().first)
        #expect(backups.copies().count == 1)
        #expect(copy.lastPathComponent.hasPrefix("persistent-apps-") && copy.pathExtension == "plist")
        let saved = try #require(DockTileBackups.entries(in: copy))
        #expect(DockTileList.bundleIdentifiers(in: saved) == ["com.apple.Safari"], "the list as it was before the change")

        // Nothing changes, nothing is copied.
        #expect(tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id]) == .unchanged)
        #expect(backups.copies().count == 1)
    }

    @Test func aFailedBackupDoesntStopTheChange() throws {
        defer { temporary.remove() }
        let blocked = temporary.url.appending(path: "not-a-folder")
        try Data("file".utf8).write(to: blocked)
        let work = group("Work")
        let store = InMemoryDockTileStore(entries: [Self.safari])
        let tiles = AgentDockTiles(store: store, backups: DockTileBackups(directory: blocked))
        tiles.requestAddition(of: work.id)

        #expect(tiles.apply([tile(for: work)], standaloneGroupIDs: [work.id]) == .saved(previousCount: 1, count: 2))
    }

    @Test func onlyTheNewestCopiesAreKept() throws {
        defer { temporary.remove() }
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_792_400_000)
        }
        let clock = Clock()
        let backups = DockTileBackups(directory: temporary.url.appending(path: "kept"), keep: 6, now: { clock.now })
        var written: [URL] = []
        for index in 0..<8 {
            clock.now = Date(timeIntervalSince1970: 1_792_400_000 + Double(index) * 60)
            written.append(try backups.save([Self.safari]))
        }
        // Two in the same millisecond still make two copies.
        written.append(try backups.save([Self.safari]))

        let copies = backups.copies()
        #expect(copies.count == 6)
        #expect(copies.first?.lastPathComponent == written.last?.lastPathComponent, "newest first")
        #expect(copies.map(\.lastPathComponent) == written.suffix(6).reversed().map(\.lastPathComponent))
        #expect(written[7].lastPathComponent == "persistent-apps-20261019-090020-000.plist")
        #expect(written[8].lastPathComponent == "persistent-apps-20261019-090020-000-01.plist")
    }
}
