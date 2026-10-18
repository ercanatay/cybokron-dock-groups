import Foundation
import Testing
@testable import DockGroupsCore

private func app(_ name: String) -> AppReference {
    AppReference(bundleIdentifier: "com.example.\(name.lowercased())", name: name, path: "/Applications/\(name).app")
}

/// Keeps the groups in memory and counts the saves.
private final class CountingPersistence: GroupPersisting {
    private(set) var saved: [DockGroup] = []
    private(set) var saveCount = 0

    func loadGroups() throws -> [DockGroup] { saved }

    func saveGroups(_ groups: [DockGroup]) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}

@Suite("Moving apps between groups")
@MainActor
struct MoveBetweenGroupsTests {
    private func makeStore(_ persistence: GroupPersisting = CountingPersistence()) -> (GroupStore, work: DockGroup.ID, play: DockGroup.ID) {
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let work = store.addGroup(named: "Work")
        let play = store.addGroup(named: "Play")
        store.addApps([app("Safari"), app("Mail"), app("Notes")], toGroup: work.id)
        store.addApps([app("Music"), app("TV")], toGroup: play.id)
        return (store, work.id, play.id)
    }

    @Test func movedAppLeavesTheSourceAndJoinsTheEndOfTheDestination() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json"))
        let (store, work, play) = makeStore(persistence)

        #expect(store.moveApp(bundleIdentifier: "com.example.mail", fromGroup: work, toGroup: play))

        #expect(store.group(withID: work)?.apps.map(\.name) == ["Safari", "Notes"])
        #expect(store.group(withID: play)?.apps.map(\.name) == ["Music", "TV", "Mail"])
        // The app keeps what was known about it.
        #expect(store.group(withID: play)?.apps.last == app("Mail"))
        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.groups == store.groups)
    }

    @Test func appTheDestinationAlreadyHasIsNotDuplicated() {
        let (store, work, play) = makeStore()
        store.addApps([AppReference(bundleIdentifier: "COM.EXAMPLE.SAFARI", name: "Safari (old)")], toGroup: play)

        #expect(store.moveApp(bundleIdentifier: "com.example.safari", fromGroup: work, toGroup: play))

        #expect(store.group(withID: work)?.apps.map(\.name) == ["Mail", "Notes"])
        // Only the destination's own copy is left, where it was.
        #expect(store.group(withID: play)?.apps.map(\.name) == ["Music", "TV", "Safari (old)"])
    }

    @Test func bundleIdentifiersMatchIgnoringCase() {
        let (store, work, play) = makeStore()
        #expect(store.moveApp(bundleIdentifier: "Com.Example.Notes", fromGroup: work, toGroup: play))
        #expect(store.group(withID: play)?.apps.map(\.name) == ["Music", "TV", "Notes"])
    }

    @Test func bothGroupsChangeInOneSave() {
        let persistence = CountingPersistence()
        let (store, work, play) = makeStore(persistence)
        let saves = persistence.saveCount

        store.moveApp(bundleIdentifier: "com.example.safari", fromGroup: work, toGroup: play)

        #expect(persistence.saveCount == saves + 1)
        #expect(persistence.saved == store.groups)
    }

    @Test func nothingChangesForTheSameGroupOrUnknownGroupsAndApps() {
        let persistence = CountingPersistence()
        let (store, work, play) = makeStore(persistence)
        let before = store.groups
        let saves = persistence.saveCount

        #expect(!store.moveApp(bundleIdentifier: "com.example.safari", fromGroup: work, toGroup: work))
        #expect(!store.moveApp(bundleIdentifier: "com.example.safari", fromGroup: UUID(), toGroup: play))
        #expect(!store.moveApp(bundleIdentifier: "com.example.safari", fromGroup: work, toGroup: UUID()))
        #expect(!store.moveApp(bundleIdentifier: "com.example.music", fromGroup: work, toGroup: play))

        #expect(store.groups == before)
        #expect(persistence.saveCount == saves)
    }

    @Test func freeLayoutCellOfTheMovedAppIsCleared() throws {
        let (store, work, play) = makeStore()
        // Work in Free Layout: Safari in cell 0, Mail in cell 4, Notes in cell 9.
        store.arrangeApps(inGroup: work, freeLayoutSlots: ["com.example.safari": 0, "com.example.mail": 4, "com.example.notes": 9])
        // Play in Free Layout with a gap: Music in cell 0, TV in cell 2.
        store.arrangeApps(inGroup: play, freeLayoutSlots: ["com.example.music": 0, "com.example.tv": 2])

        store.moveApp(bundleIdentifier: "com.example.mail", fromGroup: work, toGroup: play)

        let source = try #require(store.group(withID: work))
        #expect(source.freeLayoutSlots == ["com.example.safari": 0, "com.example.notes": 9])
        let destination = try #require(store.group(withID: play))
        // It joins the list without a cell of its own …
        #expect(destination.freeLayoutSlots == ["com.example.music": 0, "com.example.tv": 2])
        #expect(destination.apps.last?.name == "Mail")
        // … so the popup puts it in the first free cell.
        let layout = FreeLayout(apps: destination.apps, savedSlots: destination.freeLayoutSlots, slotCount: 5)
        #expect(layout.slot(of: app("Mail")) == 1)
    }
}

@Suite("Siri phrases and links of a group")
struct GroupInvocationsTests {
    @Test func siriPhrasesNameTheGroupAndTheApp() {
        let phrases = GroupInvocations.siriPhrases(groupName: "Work", appName: "Cybokron Dock Groups")
        #expect(phrases.map(\.title) == ["Show Group", "Launch Group", "Quit Group"])
        #expect(phrases.map(\.text) == [
            "Show Work in Cybokron Dock Groups",
            "Launch Work in Cybokron Dock Groups",
            "Quit Work in Cybokron Dock Groups",
        ])
    }

    @Test func linksUseTheSlugAndWorkAsURLCommands() throws {
        let group = DockGroup(name: "Çalışma Alanı")
        let links = GroupInvocations.links(for: group, in: [group])

        #expect(links.map(\.title) == ["Show Popup", "Open All", "Hide All", "Close All"])
        #expect(links.map(\.text) == [
            "cybokrondockgroups://open/calisma-alani",
            "cybokrondockgroups://launch/calisma-alani",
            "cybokrondockgroups://hide/calisma-alani",
            "cybokrondockgroups://quit/calisma-alani",
        ])
        let commands = try links.map { try #require(URL(string: $0.text).flatMap(URLCommand.init(url:))) }
        #expect(commands == [
            .showGroup("calisma-alani"),
            .launchGroup("calisma-alani"),
            .hideGroup("calisma-alani"),
            .quitGroup("calisma-alani", .graceful),
        ])
    }

    @Test func groupsTheSlugDoesNotFindAreLinkedByIdentifier() {
        let first = DockGroup(name: "Work")
        let second = DockGroup(name: "work!")
        let emoji = DockGroup(name: "🎮")
        let groups = [first, second, emoji]

        #expect(GroupInvocations.linkToken(for: first, in: groups) == "work")
        // "work" already finds the first group.
        #expect(GroupInvocations.linkToken(for: second, in: groups) == second.id.uuidString)
        #expect(GroupInvocations.linkToken(for: emoji, in: groups) == emoji.id.uuidString)

        for group in groups {
            let token = GroupInvocations.linkToken(for: group, in: groups)
            #expect(GroupLookup.group(matching: token, in: groups)?.id == group.id)
        }
    }
}

@Suite("Standalone Dock menus")
struct StandaloneDockMenuPreferenceTests {
    @Test func onByDefaultAndSavedUnderItsKey() throws {
        #expect(PopupPreferences().showsStandaloneDockMenus)

        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PopupPreferences(showsStandaloneDockMenus: false))
        ) as? [String: Any]
        #expect(object?["standaloneDockMenu"] as? Bool == false)

        let decoded = try JSONDecoder().decode(PopupPreferences.self, from: Data(#"{ "standaloneDockMenu": false }"#.utf8))
        #expect(decoded.showsStandaloneDockMenus == false)
        // Files from earlier versions, and unreadable values, get the default.
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: Data("{}".utf8)).showsStandaloneDockMenus)
        let fallback = try JSONDecoder().decode(PopupPreferences.self, from: Data(#"{ "standaloneDockMenu": "no" }"#.utf8))
        #expect(fallback.showsStandaloneDockMenus)
    }

    @Test func standaloneGroupAppsGetTheSetting() throws {
        let configuration = AgentConfiguration(group: DockGroup(name: "Work"), preferences: PopupPreferences(showsStandaloneDockMenus: false))
        #expect(try AgentConfiguration.decode(from: configuration.encoded()).preferences.showsStandaloneDockMenus == false)
    }

    @Test func launchesOfStandaloneGroupAppsAreNotCounted() {
        let agent = AgentIdentity.bundleIdentifier(for: UUID())
        #expect(!UsageTracker.isTracked(bundleIdentifier: agent))
        #expect(!UsageTracker.isTracked(bundleIdentifier: agent.uppercased()))
        #expect(UsageTracker.isTracked(bundleIdentifier: "com.cybokron.dockgroups.agentish"))
    }
}

@Suite("Free layout with a fixed column count")
struct FreeLayoutColumnChangeTests {
    private static let apps = ["A", "B", "C", "D", "E", "F", "G"].map(app)

    @Test func cellsAreKeptByNumberAndThoseBeyondTheGridMoveToTheFirstFreeCells() {
        // Arranged with Auto (5) columns: two rows, ten cells; G sits in the last one.
        let saved = FreeLayout(apps: Self.apps, savedSlots: [:], slotCount: 10).moving(app("G"), to: 9).slots
        #expect(saved[app("G").normalizedBundleIdentifier] == 9)

        // Three fixed columns: three rows, nine cells. A–F keep their cell numbers, which now read
        // three to a row; G's cell 9 is past the grid, so it takes the first free cell, 6.
        let grid = PopupGridLayout(itemCount: Self.apps.count, columns: .fixed(3), maxRows: 4)
        #expect(grid.slotCount == 9)
        let layout = FreeLayout(apps: Self.apps, savedSlots: saved, slotCount: grid.slotCount)
        #expect(Self.apps.map { layout.slot(of: $0) } == [0, 1, 2, 3, 4, 5, 6])

        // Back to Auto, the saved cells still apply.
        let restored = FreeLayout(apps: Self.apps, savedSlots: saved, slotCount: 10)
        #expect(restored.slot(of: app("G")) == 9)
    }

    @Test func groupOverridesDecideTheGrid() {
        let defaults = PopupPreferences(columns: .auto, maxRows: 4)
        let settings = defaults.resolved(with: PopupOverrides(columns: .fixed(2), maxRows: 1))
        let grid = PopupGridLayout(itemCount: 5, columns: settings.columns, maxRows: settings.maxRows)

        #expect(grid.columns == 2)
        #expect(grid.rows == 3)
        #expect(grid.visibleRows == 1)
        #expect(grid.scrolls)
        #expect(grid.slotCount == 6)
    }
}
