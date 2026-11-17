import Foundation
import Testing
@testable import DockGroupsCore

/// Builds the planner's input: apps with launch counts, symmetric pairs, a state past the cold
/// start, Suggestions and Most Used on, every app installed.
private struct Fixture {
    static let day: TimeInterval = 86_400
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var apps: [String: AppUsage] = [:]
    var pairs: [String: [String: Int]] = [:]
    var state: SuggestionState
    var groups: [DockGroup] = []
    var preferences = PopupPreferences(showsSuggestions: true)
    var notInstalled: Set<String> = []

    init() {
        state = SuggestionState(enabledAt: now.addingTimeInterval(-8 * Self.day), activeDays: 6)
    }

    static func id(_ short: String) -> String { "com.example.\(short)" }

    static func item(_ short: String) -> GroupItem {
        GroupItem(bundleIdentifier: id(short), name: short.uppercased(), path: "/Applications/\(short.uppercased()).app")
    }

    mutating func app(_ short: String, launches: Int = 20, daysAgo: Double = 1) {
        rawApp(Self.id(short), launches: launches, lastLaunchedAt: now.addingTimeInterval(-daysAgo * Self.day))
    }

    mutating func rawApp(_ bundleIdentifier: String, key: String? = nil, launches: Int = 20, lastLaunchedAt: Date?) {
        let name = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        apps[key ?? bundleIdentifier.lowercased()] = AppUsage(
            app: AppReference(bundleIdentifier: bundleIdentifier, name: name, path: "/Applications/\(name).app"),
            launchCount: launches,
            lastLaunchedAt: lastLaunchedAt
        )
    }

    mutating func pair(_ lhs: String, _ rhs: String, _ count: Int) {
        rawPair(Self.id(lhs), Self.id(rhs), count)
    }

    mutating func rawPair(_ lhs: String, _ rhs: String, _ count: Int) {
        pairs[lhs, default: [:]][rhs] = count
        pairs[rhs, default: [:]][lhs] = count
    }

    /// `shorts` launched `launches` times each, every two of them together `count` times.
    mutating func clique(_ shorts: [String], launches: Int = 20, count: Int = 15) {
        for short in shorts { app(short, launches: launches) }
        for (index, lhs) in shorts.enumerated() {
            for rhs in shorts[(index + 1)...] { pair(lhs, rhs, count) }
        }
    }

    mutating func group(_ shorts: [String], id: UUID = UUID()) -> UUID {
        groups.append(DockGroup(id: id, name: "Group", apps: shorts.map(Self.item)))
        return id
    }

    var stats: UsageStats { UsageStats(apps: apps, cooccurrence: pairs) }

    func plan() -> [SuggestionPlan] {
        SuggestionPlanner.plan(
            stats: stats, state: state, groups: groups, preferences: preferences, now: now,
            isInstalled: { !notInstalled.contains($0.normalizedBundleIdentifier) }
        )
    }

    func eligible() -> [String] {
        SuggestionPlanner.eligibleApps(
            in: stats, protectedApps: preferences.protectedApps, now: now,
            isInstalled: { !notInstalled.contains($0.normalizedBundleIdentifier) }
        ).keys.sorted()
    }
}

private func ids(_ shorts: [String]) -> [String] { shorts.map(Fixture.id) }

@Suite("Suggestions: cold start")
struct SuggestionPlannerColdStartTests {
    private func routine() -> Fixture {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"])
        return fixture
    }

    @Test func aRoutinePastTheGatesIsSuggested() {
        let plans = routine().plan()
        #expect(plans.count == 1)
        #expect(plans.first?.kind == .newGroup)
        #expect(plans.first?.appKeys == ids(["a", "b", "c"]))
    }

    @Test func noDataMeansNoSuggestion() {
        var fixture = Fixture()
        fixture.apps = [:]
        fixture.pairs = [:]
        #expect(fixture.plan().isEmpty)
    }

    @Test func neverTurnedOnMeansNoSuggestion() {
        var fixture = routine()
        fixture.state = SuggestionState(activeDays: 30)
        #expect(fixture.plan().isEmpty)
    }

    @Test func theObservationWindowIsSevenDaysFromTurningOn() {
        var fixture = routine()
        fixture.state.enabledAt = fixture.now.addingTimeInterval(-7 * Fixture.day + 1)
        #expect(fixture.plan().isEmpty)
        fixture.state.enabledAt = fixture.now.addingTimeInterval(-7 * Fixture.day)
        #expect(fixture.plan().count == 1)
        // Turned on "in the future" (the clock went back): not ready.
        fixture.state.enabledAt = fixture.now.addingTimeInterval(Fixture.day)
        #expect(fixture.plan().isEmpty)
    }

    @Test func fiveActiveDaysAreNeeded() {
        var fixture = routine()
        fixture.state.activeDays = 4
        #expect(fixture.plan().isEmpty)
        fixture.state.activeDays = 5
        #expect(fixture.plan().count == 1)
    }

    @Test func fiftyLaunchesInAllAreNeeded() {
        // 6 / 17 ≥ 0.35, so the pairs stay strong.
        var fixture = Fixture()
        fixture.app("a", launches: 17)
        fixture.app("b", launches: 16)
        fixture.app("c", launches: 16)
        fixture.pair("a", "b", 6)
        fixture.pair("a", "c", 6)
        fixture.pair("b", "c", 6)
        #expect(fixture.plan().isEmpty)
        fixture.app("b", launches: 17)
        #expect(fixture.plan().count == 1)
    }

    @Test func bothSwitchesMustBeOn() {
        var fixture = routine()
        fixture.preferences.showsSuggestions = false
        #expect(fixture.plan().isEmpty)
        fixture.preferences.showsSuggestions = true
        fixture.preferences.showsMostUsed = false
        #expect(fixture.plan().isEmpty)
    }
}

@Suite("Suggestions: eligible apps")
struct SuggestionPlannerEligibilityTests {
    @Test func fiveLaunchesAreNeeded() {
        var fixture = Fixture()
        fixture.app("few", launches: 4)
        fixture.app("enough", launches: 5)
        #expect(fixture.eligible() == ids(["enough"]))
    }

    @Test func appsNotLaunchedForFourteenDaysAreLeftOut() {
        var fixture = Fixture()
        fixture.app("recent", daysAgo: 14)
        fixture.app("stale", daysAgo: 14.01)
        fixture.rawApp(Fixture.id("undated"), lastLaunchedAt: nil)
        #expect(fixture.eligible() == ids(["recent"]))
    }

    @Test func appsThatArentInstalledAreLeftOut() {
        var fixture = Fixture()
        fixture.app("here")
        fixture.app("gone")
        fixture.notInstalled = [Fixture.id("gone")]
        #expect(fixture.eligible() == ids(["here"]))
    }

    @Test func protectedThisAppItsAgentsFinderAndUntrackedAppsAreLeftOut() {
        var fixture = Fixture()
        fixture.app("kept")
        fixture.app("listed")
        fixture.preferences.protectedApps = ProtectedApps([Fixture.item("listed")])
        let now = fixture.now
        fixture.rawApp(ProtectedApps.hostBundleIdentifier, lastLaunchedAt: now)
        fixture.rawApp(AgentIdentity.bundleIdentifierPrefix + UUID().uuidString, lastLaunchedAt: now)
        fixture.rawApp(ProtectedApps.finderBundleIdentifier, lastLaunchedAt: now)
        fixture.rawApp("com.apple.spotlight", lastLaunchedAt: now)
        #expect(fixture.eligible() == ids(["kept"]))
    }

    @Test func appsThatCantBeAppItemsOrDontMatchTheirKeyAreLeftOut() {
        var fixture = Fixture()
        let now = fixture.now
        fixture.app("kept")
        fixture.rawApp("com.example:odd", lastLaunchedAt: now)
        fixture.rawApp("/tmp/tool.command", lastLaunchedAt: now)
        fixture.rawApp("https://example.com", lastLaunchedAt: now)
        fixture.rawApp(Fixture.id("other"), key: Fixture.id("elsewhere"), lastLaunchedAt: now)
        fixture.rawApp("com.example.Upper", key: "com.example.Upper", lastLaunchedAt: now)
        #expect(fixture.eligible() == ids(["kept"]))
    }

    @Test func installationIsAskedOnlyAboutAppsThatPassedTheOtherChecks() {
        var fixture = Fixture()
        fixture.app("kept")
        fixture.app("stale", daysAgo: 30)
        fixture.app("few", launches: 1)
        fixture.app("listed")
        fixture.preferences.protectedApps = ProtectedApps([Fixture.item("listed")])
        var asked: [String] = []
        _ = SuggestionPlanner.eligibleApps(in: fixture.stats, protectedApps: fixture.preferences.protectedApps, now: fixture.now) {
            asked.append($0.normalizedBundleIdentifier)
            return true
        }
        #expect(asked == ids(["kept"]))
    }
}

@Suite("Suggestions: pairs and new groups")
struct SuggestionPlannerNewGroupTests {
    @Test func pairsNeedFiveSessionsTogether() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"], launches: 10, count: 6)
        fixture.app("filler", launches: 50)
        fixture.pair("a", "b", 4)
        #expect(fixture.plan().isEmpty)
        fixture.pair("a", "b", 5)
        #expect(fixture.plan().first?.appKeys == ids(["a", "b", "c"]))
    }

    @Test func pairsNeedAMutualStrengthOf35Percent() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"], launches: 20, count: 7)
        #expect(fixture.plan().count == 1)
        fixture.pair("b", "c", 6)
        #expect(fixture.plan().isEmpty)
    }

    @Test func aPairMustBeCountedBothWays() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"])
        fixture.pairs[Fixture.id("b")]?[Fixture.id("a")] = nil
        #expect(fixture.plan().isEmpty)
        fixture.pairs[Fixture.id("b")]?[Fixture.id("a")] = 7
        #expect(fixture.plan().first?.weakestPairCount == 7)
    }

    @Test func aHubAppLaunchedWithEverythingIsntPulledIn() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"], launches: 25, count: 20)
        fixture.app("hub", launches: 300)
        for short in ["a", "b", "c"] { fixture.pair("hub", short, 20) }
        let plans = fixture.plan()
        #expect(plans.count == 1)
        #expect(plans.first?.appKeys == ids(["a", "b", "c"]))
        #expect(!plans.flatMap(\.appKeys).contains(Fixture.id("hub")))
    }

    @Test func loginItemsThatStartTogetherAreSuggestedUntilProtectedOrDismissed() {
        // Known risk (§7, D6): apps launched together at every login look like a routine.
        var fixture = Fixture()
        fixture.clique(["login1", "login2", "login3"], launches: 30, count: 30)
        let plans = fixture.plan()
        #expect(plans.map(\.appKeys) == [ids(["login1", "login2", "login3"])])

        var protected = fixture
        protected.preferences.protectedApps = ProtectedApps([Fixture.item("login2")])
        #expect(protected.plan().isEmpty)

        var dismissed = fixture
        dismissed.state.addDismissal(plans[0].dismissal(until: nil), now: fixture.now)
        #expect(dismissed.plan().isEmpty)
    }

    @Test func anAppStrongWithOnlySomeMembersIsntAdded() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"])
        fixture.app("d")
        fixture.pair("d", "a", 10)
        fixture.pair("d", "b", 10)
        #expect(fixture.plan().map(\.appKeys) == [ids(["a", "b", "c"])])
    }

    @Test func aGroupHasAtMostSixApps() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c", "d", "e", "f", "g", "h"])
        let plans = fixture.plan()
        #expect(plans.count == 1)
        #expect(plans.first?.apps.count == 6)
        #expect(plans.first?.appKeys == ids(["a", "b", "c", "d", "e", "f"]))
    }

    @Test func twoAppsArentAGroup() {
        var fixture = Fixture()
        fixture.clique(["a", "b"], count: 20)
        fixture.app("c")
        #expect(fixture.plan().isEmpty)
    }

    @Test func appsAreOrderedByLaunchesThenIdentifier() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c", "d"], launches: 20, count: 15)
        fixture.app("c", launches: 40)
        fixture.pair("c", "a", 15)
        fixture.pair("c", "b", 15)
        fixture.pair("c", "d", 15)
        #expect(fixture.plan().first?.appKeys == ids(["c", "a", "b", "d"]))
    }

    @Test func tiesGoToTheSmallerIdentifier() {
        // b and c join a–z equally strongly, but not each other: the first one wins.
        var fixture = Fixture()
        fixture.app("a")
        fixture.app("z")
        fixture.app("c")
        fixture.app("b")
        fixture.pair("a", "z", 19)
        for short in ["b", "c"] {
            fixture.pair(short, "a", 10)
            fixture.pair(short, "z", 10)
        }
        #expect(fixture.plan().map(\.appKeys) == [ids(["a", "b", "z"])])
    }

    @Test func atMostTwoNewGroupsStrongestFirst() {
        var fixture = Fixture()
        fixture.clique(["a1", "a2", "a3"], count: 10)
        fixture.clique(["b1", "b2", "b3"], count: 18)
        fixture.clique(["c1", "c2", "c3"], count: 14)
        let plans = fixture.plan()
        #expect(plans.map(\.appKeys) == [ids(["b1", "b2", "b3"]), ids(["c1", "c2", "c3"])])
        #expect(plans.allSatisfy { $0.kind == .newGroup && $0.group == nil && $0.target == .newGroup })
        #expect(plans.first?.weakestPairCount == 18)
        #expect(plans.first?.totalPairCount == 54)
    }

    @Test func anExistingGroupWithThreeQuartersOfTheAppsSuppressesIt() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c", "d"])
        _ = fixture.group(["a", "b", "c", "other"])
        #expect(fixture.plan().filter { $0.kind == .newGroup }.isEmpty)

        var half = Fixture()
        half.clique(["a", "b", "c", "d"])
        _ = half.group(["a", "b"])
        #expect(half.plan().filter { $0.kind == .newGroup }.map(\.appKeys) == [ids(["a", "b", "c", "d"])])
    }

    @Test func onlyTheGroupsPassedCountSoArchivedOnesDont() {
        // The caller passes the active groups; an archived group isn't among them.
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"])
        #expect(fixture.plan().count == 1)
        _ = fixture.group(["a", "b", "c"])
        #expect(fixture.plan().isEmpty)
    }

    @Test func websitesInAGroupArentCountedAsItsApps() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"])
        var group = DockGroup(name: "Web", apps: [Fixture.item("a")])
        group.apps.append(GroupItem(websiteURL: URL(string: "https://com.example.b")!))
        group.apps.append(GroupItem(websiteURL: URL(string: "https://com.example.c")!))
        fixture.groups = [group]
        #expect(fixture.plan().filter { $0.kind == .newGroup }.count == 1)
    }
}

@Suite("Suggestions: add to group")
struct SuggestionPlannerAddToGroupTests {
    @Test func anAppPairedWithTwoThirdsOfAGroupIsSuggested() {
        var fixture = Fixture()
        for short in ["a", "b", "c", "x"] { fixture.app(short) }
        let group = fixture.group(["a", "b", "c"])
        fixture.pair("x", "a", 10)
        fixture.pair("x", "b", 12)
        let plans = fixture.plan()
        #expect(plans.count == 1)
        #expect(plans.first?.kind == .addToGroup)
        #expect(plans.first?.group == group)
        #expect(plans.first?.target == .group(group))
        #expect(plans.first?.appKeys == ids(["x"]))
        #expect(plans.first?.weakestPairCount == 10)
        #expect(plans.first?.totalPairCount == 22)

        var once = fixture
        once.pairs[Fixture.id("b")]?[Fixture.id("x")] = nil
        #expect(once.plan().isEmpty)
    }

    @Test func twoThirdsIsRoundedUp() {
        // Six eligible apps: four links are needed.
        var fixture = Fixture()
        let members = ["a", "b", "c", "d", "e", "f"]
        for short in members + ["x"] { fixture.app(short) }
        _ = fixture.group(members)
        for short in members.prefix(3) { fixture.pair("x", short, 10) }
        #expect(fixture.plan().isEmpty)
        fixture.pair("x", "d", 10)
        #expect(fixture.plan().map(\.appKeys) == [ids(["x"])])
    }

    @Test func atLeastTwoEligibleGroupAppsAreNeeded() {
        var fixture = Fixture()
        for short in ["a", "b", "c", "x"] { fixture.app(short) }
        fixture.notInstalled = Set(ids(["b", "c"]))
        _ = fixture.group(["a", "b", "c"])
        fixture.pair("x", "a", 10)
        #expect(fixture.plan().isEmpty)

        var single = Fixture()
        single.app("a")
        single.app("x")
        single.app("filler", launches: 50)
        _ = single.group(["a"])
        single.pair("x", "a", 10)
        #expect(single.plan().isEmpty)
    }

    @Test func oneAppPerGroupTheStrongestThenTheSmallerIdentifier() {
        var fixture = Fixture()
        for short in ["a", "b", "x", "y"] { fixture.app(short) }
        _ = fixture.group(["a", "b"])
        fixture.pair("x", "a", 10)
        fixture.pair("x", "b", 10)
        fixture.pair("y", "a", 12)
        fixture.pair("y", "b", 12)
        #expect(fixture.plan().map(\.appKeys) == [ids(["y"])])
        fixture.pair("x", "a", 12)
        fixture.pair("x", "b", 12)
        #expect(fixture.plan().map(\.appKeys) == [ids(["x"])])
    }

    @Test func atMostTwoAddToGroupSuggestionsStrongestFirst() {
        var fixture = Fixture()
        var groups: [String: UUID] = [:]
        for (name, count) in [("p", 10), ("q", 16), ("r", 13)] {
            for short in ["\(name)1", "\(name)2", "\(name)x"] { fixture.app(short) }
            groups[name] = fixture.group(["\(name)1", "\(name)2"])
            fixture.pair("\(name)x", "\(name)1", count)
            fixture.pair("\(name)x", "\(name)2", count)
        }
        let plans = fixture.plan()
        #expect(plans.map(\.group) == [groups["q"], groups["r"]])
        #expect(plans.allSatisfy { $0.kind == .addToGroup })
    }

    @Test func atMostThreeInAllNewGroupsFirst() {
        var fixture = Fixture()
        fixture.clique(["a1", "a2", "a3"], count: 10)
        fixture.clique(["b1", "b2", "b3"], count: 12)
        for name in ["p", "q"] {
            for short in ["\(name)1", "\(name)2", "\(name)x"] { fixture.app(short) }
            _ = fixture.group(["\(name)1", "\(name)2"])
            fixture.pair("\(name)x", "\(name)1", 18)
            fixture.pair("\(name)x", "\(name)2", 18)
        }
        let plans = fixture.plan()
        #expect(plans.count == SuggestionPlanner.maximumSuggestions)
        #expect(plans.map(\.kind) == [.newGroup, .newGroup, .addToGroup])
    }
}

@Suite("Suggestions: dismissals")
struct SuggestionPlannerDismissalTests {
    private func routine() -> Fixture {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c", "d"])
        return fixture
    }

    @Test func dontSuggestAgainIsPermanent() {
        var fixture = routine()
        let plan = fixture.plan()[0]
        fixture.state.addDismissal(plan.dismissal(until: nil), now: fixture.now)
        #expect(fixture.plan().isEmpty)
        fixture.now = fixture.now.addingTimeInterval(365 * Fixture.day)
        fixture.state.enabledAt = fixture.now.addingTimeInterval(-8 * Fixture.day)
        for short in ["a", "b", "c", "d"] { fixture.app(short) }
        #expect(fixture.plan().isEmpty)
    }

    @Test func notNowHoldsUntilItsMomentAndNotAfter() {
        var fixture = routine()
        let plan = fixture.plan()[0]
        let until = fixture.now.addingTimeInterval(SuggestionPlanner.shortSnooze)
        fixture.state.addDismissal(plan.dismissal(until: until), now: fixture.now)
        #expect(fixture.plan().isEmpty)
        fixture.now = until.addingTimeInterval(-1)
        #expect(fixture.plan().isEmpty)
        fixture.now = until
        #expect(fixture.plan().map(\.appKeys) == [plan.appKeys])
    }

    @Test func aDismissalMatchesSetsOverlappingByThreeQuarters() {
        var close = routine()
        close.state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ids(["a", "b", "c"])), now: close.now)
        #expect(close.plan().isEmpty)

        var far = routine()
        far.state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ids(["a", "b", "c", "e"])), now: far.now)
        #expect(far.plan().count == 1)

        var otherKind = routine()
        otherKind.state.addDismissal(DismissedSuggestion(kind: .addToGroup, apps: ids(["a", "b", "c", "d"]), group: UUID()), now: otherKind.now)
        #expect(otherKind.plan().count == 1)
    }

    @Test func anAddToGroupDismissalMatchesTheSameGroupAndAppOnly() {
        var fixture = Fixture()
        for short in ["a", "b", "x", "y"] { fixture.app(short) }
        let group = fixture.group(["a", "b"])
        for short in ["a", "b"] {
            fixture.pair("x", short, 12)
            fixture.pair("y", short, 10)
        }
        #expect(fixture.plan().map(\.appKeys) == [ids(["x"])])

        var otherGroup = fixture
        otherGroup.state.addDismissal(DismissedSuggestion(kind: .addToGroup, apps: ids(["x"]), group: UUID()), now: fixture.now)
        #expect(otherGroup.plan().map(\.appKeys) == [ids(["x"])])

        var newGroupKind = fixture
        newGroupKind.state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ids(["x"])), now: fixture.now)
        #expect(newGroupKind.plan().map(\.appKeys) == [ids(["x"])])

        // The dismissed app gives way to the next one.
        fixture.state.addDismissal(fixture.plan()[0].dismissal(until: nil), now: fixture.now)
        #expect(fixture.plan().map(\.appKeys) == [ids(["y"])])
        #expect(fixture.plan().first?.group == group)
    }

    @Test func snoozeLengthsAreAWeekAndAMonth() {
        #expect(SuggestionPlanner.shortSnooze == 7 * Fixture.day)
        #expect(SuggestionPlanner.longSnooze == 30 * Fixture.day)
    }
}

@Suite("Suggestions: determinism and crafted data")
struct SuggestionPlannerSafetyTests {
    private func scenario(order: [String]) -> Fixture {
        var fixture = Fixture()
        // Insert in the given order so the dictionaries are built differently.
        for short in order { fixture.app(short, launches: short.hasPrefix("g") ? 30 : 20) }
        for (index, lhs) in ["a", "b", "c", "d"].enumerated() {
            for rhs in ["a", "b", "c", "d"][(index + 1)...] { fixture.pair(lhs, rhs, 15) }
        }
        for (index, lhs) in ["e", "f", "h"].enumerated() {
            for rhs in ["e", "f", "h"][(index + 1)...] { fixture.pair(lhs, rhs, 15) }
        }
        fixture.groups = [DockGroup(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "G", apps: ["g1", "g2"].map(Fixture.item))]
        for short in ["g1", "g2"] {
            fixture.pair("x", short, 15)
            fixture.pair("y", short, 15)
        }
        return fixture
    }

    @Test func theSameInputGivesTheSameSuggestionsInTheSameOrder() {
        let shorts = ["a", "b", "c", "d", "e", "f", "h", "g1", "g2", "x", "y"]
        let expected = scenario(order: shorts).plan()
        #expect(expected.map(\.appKeys) == [ids(["a", "b", "c", "d"]), ids(["e", "f", "h"]), ids(["x"])])
        for order in [shorts.reversed(), shorts.sorted { $0.hashValue < $1.hashValue }, shorts.shuffled()] {
            for _ in 0..<5 {
                #expect(scenario(order: Array(order)).plan() == expected)
            }
        }
    }

    @Test func planningChangesNothing() {
        let fixture = scenario(order: ["a", "b", "c", "d", "e", "f", "h", "g1", "g2", "x", "y"])
        let before = (fixture.stats, fixture.state, fixture.groups)
        _ = fixture.plan()
        #expect(fixture.stats == before.0)
        #expect(fixture.state == before.1)
        #expect(fixture.groups == before.2)
    }

    @Test func hugeSelfAndNegativeCountsDontTrapAndStayGated() {
        var fixture = Fixture()
        fixture.clique(["a", "b", "c"], launches: Int.max, count: Int.max)
        fixture.app("d", launches: Int.max, daysAgo: 30)
        fixture.app("e")
        fixture.rawPair(Fixture.id("a"), Fixture.id("a"), 1_000)
        fixture.rawPair(Fixture.id("e"), Fixture.id("a"), -50)
        fixture.rawPair(Fixture.id("d"), Fixture.id("a"), Int.max)
        let plans = fixture.plan()
        #expect(plans.map(\.appKeys) == [ids(["a", "b", "c"])])
        #expect(plans.first?.totalPairCount == Int.max)
    }

    @Test func ratiosCompareExactly() {
        let ratio = SuggestionPlanner.Ratio(2, 3)
        #expect(ratio.minimumPart(of: 3) == 2)
        #expect(ratio.minimumPart(of: 4) == 3)
        #expect(ratio.minimumPart(of: 6) == 4)
        #expect(ratio.minimumPart(of: 0) == 0)
        #expect(SuggestionPlanner.minimumMutualStrength.isMet(by: 7, of: 20))
        #expect(!SuggestionPlanner.minimumMutualStrength.isMet(by: 6, of: 20))
        #expect(!ratio.isMet(by: 1, of: 0))
        #expect(ratio.isMet(by: Int.max, of: Int.max))
    }

    @Test func thresholdsMatchTheDesign() {
        #expect(SuggestionPlanner.observationWindow == 7 * Fixture.day)
        #expect(SuggestionPlanner.minimumActiveDays == 5)
        #expect(SuggestionPlanner.minimumTotalLaunches == 50)
        #expect(SuggestionPlanner.minimumAppLaunches == 5)
        #expect(SuggestionPlanner.maximumLaunchAge == 14 * Fixture.day)
        #expect(SuggestionPlanner.minimumPairCount == 5)
        #expect(SuggestionPlanner.minimumMutualStrength == SuggestionPlanner.Ratio(35, 100))
        #expect(SuggestionPlanner.minimumGroupSize == 3)
        #expect(SuggestionPlanner.maximumGroupSize == 6)
        #expect(SuggestionPlanner.existingGroupOverlap == SuggestionPlanner.Ratio(3, 4))
        #expect(SuggestionPlanner.addToGroupShare == SuggestionPlanner.Ratio(2, 3))
        #expect(SuggestionPlanner.minimumAddToGroupLinks == 2)
        #expect(SuggestionPlanner.maximumNewGroupSuggestions == 2)
        #expect(SuggestionPlanner.maximumAddToGroupSuggestions == 2)
        #expect(SuggestionPlanner.maximumSuggestions == 3)
        #expect(SuggestionPlanner.dismissalOverlap == SuggestionPlanner.Ratio(3, 4))
    }

    @Test func aPlansDismissalRecordsItsKindAppsAndGroup() {
        let group = UUID()
        let plan = SuggestionPlan(kind: .addToGroup, apps: [Fixture.item("X")], group: group, weakestPairCount: 5, totalPairCount: 10)
        let dismissal = plan.dismissal(until: nil)
        #expect(dismissal == DismissedSuggestion(kind: .addToGroup, apps: ["com.example.x"], group: group, until: nil))
        let newGroup = SuggestionPlan(kind: .newGroup, apps: [Fixture.item("a")], group: group, weakestPairCount: 5, totalPairCount: 5)
        #expect(newGroup.group == nil)
        #expect(newGroup.target == .newGroup)
    }
}
