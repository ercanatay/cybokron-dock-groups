import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: the store and its files")
@MainActor
struct TriggerStoreTests {
    private static let work = DockGroup.of("Work", ["com.apple.mail"])
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])

    private func store(_ triggers: [GroupTrigger] = []) -> (TriggerStore, MemoryTriggerPersistence) {
        let persistence = MemoryTriggerPersistence(triggers)
        return (TriggerStore(persistence: persistence, saveDelay: .zero), persistence)
    }

    @Test func addingKeepsTheLimits() {
        let (store, persistence) = store()
        for _ in 0..<GroupTrigger.maximumPerGroup {
            #expect(store.add(.on(.login, group: Self.work)) != .groupLimitReached)
        }
        let eleventh = store.add(.on(.login, group: Self.work))
        #expect(eleventh == .groupLimitReached)
        #expect(eleventh.message == "A group can have up to 10 triggers.")
        #expect(store.triggers(ofGroup: Self.work.id).count == 10)
        #expect(persistence.saveCount == 10)

        let (full, _) = self.store((0..<100).map { _ in GroupTrigger.on(.login, group: DockGroup.of("G", [])) })
        #expect(full.triggers.count == 100)
        let past = full.add(.on(.login, group: Self.design))
        #expect(past == .limitReached)
        #expect(past.message == "You can have up to 100 triggers.")
    }

    @Test func updatingEnablingAndDeleting() throws {
        let login = GroupTrigger.on(.login, group: Self.work)
        let (store, persistence) = store([login])
        var changed = login
        changed.action = .openAll
        #expect(store.update(changed))
        #expect(store.trigger(withID: login.id)?.action == .openAll)
        #expect(!store.update(.on(.login, group: Self.work)))

        #expect(store.setEnabled(false, forTrigger: login.id))
        #expect(store.trigger(withID: login.id)?.isEnabled == false)
        #expect(store.enabledCount == 0)
        // A trigger that can't run can't be turned on.
        let broken = GroupTrigger(groupID: Self.work.id, event: .login, action: .finish, isEnabled: false)
        store.add(broken)
        #expect(!store.setEnabled(true, forTrigger: broken.id))

        store.delete(login.id)
        #expect(store.triggers.map(\.id) == [broken.id])
        #expect(persistence.saved == store.triggers)
    }

    @Test func movingToAFullGroupChangesNothing() {
        let full = (0..<10).map { _ in GroupTrigger.on(.login, group: Self.design) }
        let mine = GroupTrigger.on(.login, group: Self.work)
        let (store, _) = store(full + [mine])
        var moved = mine
        moved.groupID = Self.design.id
        #expect(!store.update(moved))
        #expect(store.trigger(withID: mine.id)?.groupID == Self.work.id)
    }

    /// Archived groups keep their triggers (they don't run); deleted ones lose them — unless the
    /// groups couldn't be loaded.
    @Test func pruningFollowsTheGroups() throws {
        let groupsPersistence = MemoryGroupPersistence()
        try groupsPersistence.saveGroups([Self.work, Self.design])
        let groups = GroupStore(persistence: groupsPersistence, saveDelay: .zero)
        let work = GroupTrigger.on(.login, group: Self.work)
        let design = GroupTrigger.on(.login, group: Self.design)
        let (store, _) = store([work, design])

        _ = groups.archiveGroup(Self.design.id)
        #expect(store.pruneTriggers(for: groups) == 0)
        #expect(store.triggers.count == 2)

        groups.deleteGroup(Self.work.id)
        #expect(store.pruneTriggers(for: groups) == 1)
        #expect(store.triggers.map(\.id) == [design.id])

        // An unreadable groups file: the store starts empty, but no trigger goes.
        let broken = GroupStore(persistence: FailingGroupLoad(), saveDelay: .zero)
        #expect(broken.loadFailed && broken.groups.isEmpty)
        #expect(store.pruneTriggers(for: broken) == 0)
        #expect(store.triggers.count == 1)
    }

    @Test func anUnreadableFileIsMovedAside() {
        let persistence = MemoryTriggerPersistence()
        persistence.failsToLoad = true
        let store = TriggerStore(persistence: persistence, saveDelay: .zero)
        #expect(store.triggers.isEmpty && persistence.movedAside)
        #expect(store.issue?.title == "Your triggers couldn't be loaded")
        #expect(store.issue?.message.contains("A copy was kept at") == true)

        let stuck = MemoryTriggerPersistence([.on(.login, group: Self.work)])
        stuck.failsToLoad = true
        stuck.failsToMoveAside = true
        let suspended = TriggerStore(persistence: stuck, saveDelay: .zero)
        #expect(suspended.isSavingSuspended)
        suspended.add(.on(.login, group: Self.design))
        #expect(stuck.saveCount == 0)
    }

    @Test func aFailedSaveIsSaid() {
        let persistence = MemoryTriggerPersistence()
        persistence.failsToSave = true
        let store = TriggerStore(persistence: persistence, saveDelay: .zero)
        store.add(.on(.login, group: Self.work))
        #expect(store.issue?.title == "Your triggers couldn't be saved")
    }

    @Test func replacingAndMerging() throws {
        let mine = GroupTrigger.on(.login, group: Self.work)
        let (store, persistence) = store([mine])
        let incoming = GroupTrigger.on(.appOpens, group: Self.design, action: .showPopup)
        #expect(try store.mergeTriggers([mine, incoming]) == [incoming])
        #expect(store.triggers.map(\.id) == [mine.id, incoming.id])
        #expect(try store.mergeTriggers([mine]).isEmpty)
        #expect(persistence.copies == ["pre-import"])

        try store.replaceTriggers(with: [incoming])
        #expect(store.triggers == [incoming])
        #expect(persistence.copies == ["pre-import", "pre-import"])
    }

    // MARK: - Files

    @Test func theFileRoundTripsAndKeepsWhatItCantRead() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "triggers.json")
        let file = #"""
        {
          "formatVersion" : 1,
          "triggers" : [
            {
              "action" : "start",
              "enabled" : true,
              "event" : {
                "kind" : "geofence",
                "radius" : 150
              },
              "groupID" : "0C0D1E00-0000-4000-8000-000000000080",
              "id" : "7A1660E0-0000-4000-8000-000000000011",
              "runMode" : "notice"
            },
            {
              "action" : "showPopup",
              "enabled" : false,
              "event" : {
                "kind" : "login"
              },
              "groupID" : "0C0D1E00-0000-4000-8000-000000000080",
              "id" : "7A1660E0-0000-4000-8000-000000000012",
              "runMode" : "immediately"
            }
          ]
        }
        """#
        try Data(file.utf8).write(to: url)
        let persistence = JSONFileTriggerPersistence(fileURL: url)
        let triggers = try persistence.loadTriggers()
        #expect(triggers.count == 2)
        #expect(triggers[0].event.isUnsupported && !triggers[0].canRun)
        try persistence.saveTriggers(triggers)
        #expect(try String(contentsOf: url, encoding: .utf8) == file)
    }

    @Test func aNewerFileIsntRead() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.url.appending(path: "triggers.json")
        try Data(#"{"formatVersion": 2, "triggers": []}"#.utf8).write(to: url)
        #expect(throws: TriggerPersistenceError.unsupportedFormatVersion(2)) {
            try JSONFileTriggerPersistence(fileURL: url).loadTriggers()
        }
        #expect(TriggerPersistenceError.unsupportedFormatVersion(2).localizedDescription.contains("newer version"))
        #expect(try JSONFileTriggerPersistence(fileURL: directory.url.appending(path: "none.json")).loadTriggers().isEmpty)
    }

    // MARK: - The state file

    @Test func theStateRoundTrips() throws {
        let id = UUID()
        let state = TriggerState(
            entries: [id: TriggerState.Entry(
                lastRunAt: Date(timeIntervalSince1970: 1_800_000_000),
                lastOutcome: .skipped(.notNow),
                lastOutcomeAt: Date(timeIntervalSince1970: 1_800_000_100),
                lastHandledOccurrence: Date(timeIntervalSince1970: 1_799_999_000),
                condition: 2
            )],
            pausedUntil: .distantFuture,
            pauseReason: .budget,
            lastLoginSession: Date(timeIntervalSince1970: 1_799_990_000),
            quietLaunchUntil: Date(timeIntervalSince1970: 1_800_000_120),
            recentRuns: [Date(timeIntervalSince1970: 1_800_000_000)]
        )
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileTriggerStatePersistence(fileURL: directory.url.appending(path: "trigger-state.json"))
        try persistence.saveState(state)
        #expect(persistence.loadState() == state)
        for outcome in [TriggerOutcome.ran(.finish), .missed(.appNotOpen), .skipped(.budget)] {
            #expect(try JSONDecoder().decode(TriggerOutcome.self, from: JSONEncoder().encode(outcome)) == outcome)
        }
    }

    /// A missing, unreadable or newer file, and crafted values: a fresh state, or values left out.
    @Test(arguments: [
        "",
        "not json",
        #"[1, 2]"#,
        #"{"formatVersion": 2, "pausedUntil": 1800000000}"#,
    ])
    func aStateThatCantBeReadIsFresh(text: String) {
        #expect(JSONFileTriggerStatePersistence.decode(Data(text.utf8)) == TriggerState())
    }

    @Test func craftedStateValuesAreLeftOut() {
        let id = UUID()
        let text = #"""
        {"formatVersion": 1, "pausedUntil": "forever", "lastLoginSession": 1e300, "recentRuns": [1800000000, "x"],
         "triggers": {"not-a-uuid": {"lastRunAt": 1}, "\#(id.uuidString)": {"lastOutcome": {"ran": "quit"}, "condition": -3, "lastRunAt": 1800000000, "command": "/bin/sh"}}}
        """#
        let state = JSONFileTriggerStatePersistence.decode(Data(text.utf8))
        #expect(state.pausedUntil == nil && state.lastLoginSession == nil)
        #expect(state.recentRuns.isEmpty)
        #expect(state.entries.keys.map { $0 } == [id])
        #expect(state.entry(for: id) == TriggerState.Entry(lastRunAt: Date(timeIntervalSince1970: 1_800_000_000)))
        // A pause without a reason is the user's.
        let paused = JSONFileTriggerStatePersistence.decode(Data(#"{"pausedUntil": 1800000000}"#.utf8))
        #expect(paused.pauseReason == .user)
    }

    @Test func theStateStoreWritesOnlyChanges() async {
        let persistence = MemoryTriggerStatePersistence()
        let store = TriggerStateStore(persistence: persistence, saveDelay: .zero)
        store.update(TriggerState())
        #expect(persistence.saveCount == 0)
        var state = TriggerState()
        state.pause(until: Date(timeIntervalSince1970: 1_800_000_000), reason: .user)
        store.update(state)
        #expect(persistence.saveCount == 1)
        store.update(state)
        #expect(persistence.saveCount == 1)

        let delayed = MemoryTriggerStatePersistence()
        let gathered = TriggerStateStore(persistence: delayed, saveDelay: .seconds(60))
        gathered.update(state)
        state.resume()
        state.lastLoginSession = Date(timeIntervalSince1970: 1_800_000_000)
        gathered.update(state)
        #expect(delayed.saveCount == 0)
        gathered.flushPendingSave()
        #expect(delayed.saveCount == 1)
        #expect(delayed.saved == state)
        #expect(TriggerStateStore(persistence: delayed).state == state)
    }
}

/// A groups file that can't be read (moved aside fine).
private final class FailingGroupLoad: GroupPersisting {
    struct Failure: Error {}

    func loadGroups() throws -> [DockGroup] { throw Failure() }
    func saveGroups(_ groups: [DockGroup]) throws {}
    func preserveUnreadableData() throws -> URL? { nil }
}
