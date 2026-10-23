import Combine
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: presence in the group window")
@MainActor
struct ItemPresenceCacheTests {
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!)
    private static let found = ItemPresence.available(URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"))

    @Test func checksWhenAskedAndRowsOnlyRead() {
        let locator = ScriptedLocator()
        locator.set(Self.found, for: Self.report)
        let cache = ItemPresenceCache(locator: locator)

        #expect(cache.presence(of: Self.report) == nil)
        cache.track([Self.report, Self.projects, Self.github])
        #expect(locator.presenceChecks.count == 3)

        // Reading never checks.
        for _ in 0..<5 {
            #expect(cache.presence(of: Self.report) == Self.found)
            #expect(cache.presence(of: Self.projects) == .missing)
            #expect(cache.presence(of: Self.github) == .online)
        }
        #expect(locator.presenceChecks.count == 3)
    }

    /// A refresh (the window coming to the front, a volume connected) sees what changed.
    @Test func refreshSeesChangesAndPublishesOnlyThen() {
        let locator = ScriptedLocator()
        locator.set(Self.found, for: Self.report)
        let cache = ItemPresenceCache(locator: locator)
        var changes = 0
        let subscription = cache.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        cache.track([Self.report])
        #expect(changes == 1)
        cache.refresh()
        #expect(changes == 1)

        locator.set(.missing, for: Self.report)
        cache.refresh()
        #expect(changes == 2)
        #expect(cache.presence(of: Self.report) == .missing)
        #expect(locator.presenceChecks.count == 3)
    }

    /// The group's items change (added, removed, located): the new list replaces the old one.
    @Test func trackingAnotherListForgetsTheOldOne() {
        let locator = ScriptedLocator()
        let cache = ItemPresenceCache(locator: locator)
        cache.track([Self.report, Self.projects])
        cache.track([Self.projects])

        #expect(cache.presence(of: Self.report) == nil)
        #expect(cache.presence(of: Self.projects) == .missing)
    }

    /// Show in Finder and Quick Look check their item again, and the row follows.
    @Test func checkingOneItemUpdatesItsRow() {
        let locator = ScriptedLocator()
        let cache = ItemPresenceCache(locator: locator)
        cache.track([Self.report])
        #expect(cache.presence(of: Self.report) == .missing)

        locator.set(Self.found, for: Self.report)
        #expect(cache.check(Self.report) == Self.found)
        #expect(cache.presence(of: Self.report) == Self.found)
        // An item that isn't listed is checked but not kept.
        #expect(cache.check(Self.projects) == .missing)
        #expect(cache.presence(of: Self.projects) == nil)
    }
}
