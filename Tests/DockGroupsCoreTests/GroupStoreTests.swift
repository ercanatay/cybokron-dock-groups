import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group store")
@MainActor
struct GroupStoreTests {
    private let directory: TemporaryDirectory
    private let fileURL: URL

    init() throws {
        directory = try TemporaryDirectory()
        fileURL = directory.url.appending(components: "DockGroups", "groups.json")
    }

    private func makeStore(saveDelay: Duration = .zero) -> GroupStore {
        GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: saveDelay)
    }

    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let notes = AppReference(bundleIdentifier: "com.apple.Notes", name: "Notes")

    @Test func startsEmptyWithoutCreatingSampleGroups() {
        defer { directory.remove() }
        let store = makeStore()
        #expect(store.groups.isEmpty)
        #expect(store.issue == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func defaultFileLivesInApplicationSupport() {
        defer { directory.remove() }
        let path = JSONFileGroupPersistence.defaultFileURL.path
        #expect(path.hasSuffix("/Library/Application Support/Cybokron/DockGroups/groups.json"))
    }

    @Test func groupsAndAppsSurviveRestart() throws {
        defer { directory.remove() }
        let store = makeStore()
        let work = store.addGroup(named: "Work", emoji: "💼")
        store.addApps([Self.safari, Self.mail], toGroup: work.id)
        let play = store.addGroup(named: "Play")
        store.updateGroup(play.id) {
            $0.tile.kind = .grid
            $0.isPinned = true
            $0.popup.anchor = .dockIcon
        }

        let reloaded = makeStore()

        #expect(reloaded.groups == store.groups)
        #expect(reloaded.groups.map(\.name) == ["Work", "Play"])
        #expect(reloaded.group(withID: work.id)?.apps == [Self.safari, Self.mail])
        #expect(reloaded.group(withID: play.id)?.tile.kind == .grid)
        #expect(reloaded.group(withID: play.id)?.isPinned == true)
    }

    @Test func fileHasFormatVersionAndGroups() throws {
        defer { directory.remove() }
        let store = makeStore()
        store.addGroup(named: "Work")

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == 1)
        #expect((object?["groups"] as? [[String: Any]])?.first?["name"] as? String == "Work")
    }

    @Test func newGroupsGetUniqueDefaultNames() {
        defer { directory.remove() }
        let store = makeStore()
        store.addGroup()
        store.addGroup()
        store.addGroup(named: "   ")
        #expect(store.groups.map(\.name) == ["New Group", "New Group 2", "New Group 3"])
    }

    @Test func renameTrimsAndRejectsBlankNames() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Work")

        #expect(store.renameGroup(group.id, to: "  Office  "))
        #expect(store.group(withID: group.id)?.name == "Office")
        #expect(!store.renameGroup(group.id, to: "  "))
        #expect(store.group(withID: group.id)?.name == "Office")
        #expect(!store.renameGroup(UUID(), to: "Ghost"))
        #expect(makeStore().group(withID: group.id)?.name == "Office")
    }

    @Test func updateKeepsInvariants() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Work", emoji: "💼")
        store.addApps([Self.safari], toGroup: group.id)

        store.updateGroup(group.id) {
            $0.name = ""
            $0.emoji = "  "
            $0.apps.append(AppReference(bundleIdentifier: "COM.APPLE.SAFARI", name: "Safari again"))
        }

        let updated = store.group(withID: group.id)
        #expect(updated?.name == "Work")
        #expect(updated?.emoji == "💼")
        #expect(updated?.apps == [Self.safari])
    }

    @Test func deleteRemovesOnlyThatGroup() {
        defer { directory.remove() }
        let store = makeStore()
        let work = store.addGroup(named: "Work")
        let play = store.addGroup(named: "Play")

        store.deleteGroup(work.id)

        #expect(store.groups.map(\.id) == [play.id])
        #expect(makeStore().groups.map(\.id) == [play.id])
    }

    @Test func reorderingGroupsIsPersisted() {
        defer { directory.remove() }
        let store = makeStore()
        let a = store.addGroup(named: "A")
        let b = store.addGroup(named: "B")
        let c = store.addGroup(named: "C")

        store.moveGroups(fromOffsets: [2], toOffset: 0)

        #expect(store.groups.map(\.id) == [c.id, a.id, b.id])
        #expect(makeStore().groups.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func addingAppsSkipsDuplicates() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Work")

        #expect(store.addApps([Self.safari, Self.mail, Self.safari], toGroup: group.id) == 2)
        #expect(store.addApps([AppReference(bundleIdentifier: "com.apple.safari", name: "Safari")], toGroup: group.id) == 0)
        #expect(store.addApps([Self.notes], toGroup: UUID()) == 0)
        #expect(store.group(withID: group.id)?.apps == [Self.safari, Self.mail])
    }

    @Test func removingAndReorderingAppsIsPersisted() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Work")
        store.addApps([Self.safari, Self.mail, Self.notes], toGroup: group.id)

        store.moveApps(inGroup: group.id, fromOffsets: [0], toOffset: 3)
        store.removeApp(bundleIdentifier: "com.apple.MAIL", fromGroup: group.id)

        #expect(store.group(withID: group.id)?.apps == [Self.notes, Self.safari])
        #expect(makeStore().group(withID: group.id)?.apps == [Self.notes, Self.safari])
    }

    @Test func coalescedChangesAreWrittenOnFlush() {
        defer { directory.remove() }
        let store = makeStore(saveDelay: .seconds(60))
        let group = store.addGroup(named: "Work")
        store.renameGroup(group.id, to: "Office")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        store.flushPendingSave()

        #expect(makeStore().groups.map(\.name) == ["Office"])
    }

    @Test func coalescedChangesAreWrittenAfterTheDelay() async throws {
        defer { directory.remove() }
        let store = makeStore(saveDelay: .milliseconds(20))
        store.addGroup(named: "Work")

        try await Task.sleep(for: .milliseconds(300))

        #expect(makeStore().groups.map(\.name) == ["Work"])
    }

    @Test func unreadableFileIsKeptAsideAndReported() throws {
        defer { directory.remove() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)

        let store = makeStore()

        #expect(store.groups.isEmpty)
        #expect(store.issue != nil)
        #expect(!store.isSavingSuspended)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        let backups = siblings.filter { $0.hasPrefix("groups.unreadable-") }
        #expect(backups.count == 1)

        store.addGroup(named: "Fresh")
        let backupData = try Data(contentsOf: fileURL.deletingLastPathComponent().appending(path: backups[0]))
        #expect(String(decoding: backupData, as: UTF8.self) == "{ not json")
        #expect(makeStore().groups.map(\.name) == ["Fresh"])
    }

    @Test func newerFormatIsNotOverwritten() throws {
        defer { directory.remove() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{ "formatVersion": 99, "groups": [] }"#.utf8).write(to: fileURL)

        let store = makeStore()

        #expect(store.issue != nil)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("groups.unreadable-") })
    }

    @Test func savingIsSuspendedWhenUnreadableFileCannotBeMovedAside() {
        defer { directory.remove() }
        let persistence = StubPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)

        #expect(store.isSavingSuspended)
        #expect(store.issue != nil)
        store.addGroup(named: "Work")
        #expect(persistence.saveCount == 0)
    }
}

/// Persistence whose data can be neither read nor moved.
private final class StubPersistence: GroupPersisting {
    struct Failure: Error {}
    private(set) var saveCount = 0

    func loadGroups() throws -> [DockGroup] { throw Failure() }
    func saveGroups(_ groups: [DockGroup]) throws { saveCount += 1 }
    func preserveUnreadableData() throws -> URL? { throw Failure() }
}

@Suite("Array moving")
struct ArrayMoveTests {
    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a", "d"]),
        (IndexSet([3]), 0, ["d", "a", "b", "c"]),
        (IndexSet([1, 2]), 4, ["a", "d", "b", "c"]),
        (IndexSet([0, 3]), 2, ["b", "a", "d", "c"]),
        (IndexSet([1]), 1, ["a", "b", "c", "d"]),
        (IndexSet([7]), 0, ["a", "b", "c", "d"]),
    ])
    func matchesOnMoveSemantics(source: IndexSet, destination: Int, expected: [String]) {
        var values = ["a", "b", "c", "d"]
        values.moveElements(fromOffsets: source, toOffset: destination)
        #expect(values == expected)
    }
}
