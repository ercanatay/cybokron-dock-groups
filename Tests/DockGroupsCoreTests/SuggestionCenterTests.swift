import Foundation
import Testing
@testable import DockGroupsCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func id(_ short: String) -> String { "com.example.\(short)" }

private func item(_ short: String) -> GroupItem {
    GroupItem(bundleIdentifier: id(short), name: short.uppercased(), path: "/Applications/\(short.uppercased()).app")
}

/// Usage statistics in which `shorts` are launched `launches` times each, every two together
/// `count` times, last launched yesterday.
private func routine(_ shorts: [String], launches: Int = 20, count: Int = 15) -> UsageStats {
    var apps: [String: AppUsage] = [:]
    var pairs: [String: [String: Int]] = [:]
    for short in shorts {
        apps[id(short)] = AppUsage(app: item(short), launchCount: launches, lastLaunchedAt: now.addingTimeInterval(-day))
    }
    for lhs in shorts {
        for rhs in shorts where rhs != lhs { pairs[id(lhs), default: [:]][id(rhs)] = count }
    }
    return UsageStats(apps: apps, cooccurrence: pairs)
}

/// The app's pieces around a `SuggestionCenter`, saved in a temporary directory: statistics and a
/// state past the cold start, Suggestions and Most Used as given.
@MainActor
private final class Harness {
    let directory: TemporaryDirectory
    let preferences: PreferencesStore
    let groups: GroupStore
    var usage: UsageStore
    var center: SuggestionCenter
    var clock = now
    /// How many times the center asked whether an app is installed.
    var installChecks = 0

    init(
        stats: UsageStats = routine(["a", "b", "c"]),
        state: SuggestionState = SuggestionState(enabledAt: now.addingTimeInterval(-8 * day), activeDays: 6),
        suggestionsOn: Bool = true,
        mostUsedOn: Bool = true
    ) throws {
        directory = try TemporaryDirectory()
        try JSONFileUsagePersistence(directory: directory.url).save(stats)
        try JSONFileSuggestionStatePersistence(directory: directory.url).saveState(state)
        preferences = PreferencesStore(
            persistence: JSONFilePreferencesPersistence(fileURL: directory.url.appending(path: "preferences.json")),
            saveDelay: .zero
        )
        preferences.update {
            $0.showsSuggestions = suggestionsOn
            $0.showsMostUsed = mostUsedOn
        }
        groups = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        // Placeholders, replaced right away: `makeUsage` and `makeCenter` need `self`.
        usage = UsageStore(persistence: JSONFileUsagePersistence(directory: directory.url), saveDelay: .zero)
        center = SuggestionCenter(usage: usage, preferences: preferences, groups: groups, isInstalled: { _ in true })
        reload()
    }

    /// A new store and center reading what's saved, as after a relaunch.
    func reload() {
        let preferences = preferences
        usage = UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            now: { [unowned self] in self.clock },
            isRecordingEnabled: { preferences.preferences.showsMostUsed },
            suggestionPersistence: JSONFileSuggestionStatePersistence(directory: directory.url),
            areSuggestionsEnabled: { preferences.preferences.showsSuggestions }
        )
        center = SuggestionCenter(
            usage: usage,
            preferences: preferences,
            groups: groups,
            isInstalled: { [unowned self] _ in
                self.installChecks += 1
                return true
            },
            now: { [unowned self] in self.clock }
        )
    }

    deinit { directory.remove() }
}

@Suite("Suggestions: the app's center")
@MainActor
struct SuggestionCenterTests {
    @Test func aRoutineIsSuggestedWhileBothSwitchesAreOn() throws {
        let harness = try Harness()
        let plans = harness.center.suggestions()
        #expect(plans.map(\.appKeys) == [[id("a"), id("b"), id("c")].sorted()])
        #expect(harness.center.status() == .available(1))
        #expect(harness.center.isActive)
    }

    @Test func nothingIsComputedWhileSuggestionsAreOff() throws {
        let harness = try Harness(suggestionsOn: false)
        #expect(harness.center.suggestions().isEmpty)
        #expect(harness.center.menuRows().isEmpty)
        #expect(harness.center.status() == .off)
        #expect(!harness.center.isActive)
        #expect(harness.installChecks == 0)
    }

    @Test func mostUsedOffSilencesSuggestions() throws {
        let harness = try Harness(mostUsedOn: false)
        #expect(harness.center.suggestions().isEmpty)
        #expect(harness.center.menuRows().isEmpty)
        #expect(harness.center.status() == .needsMostUsed)
        #expect(harness.installChecks == 0)

        // Turning Most Used off later silences them at once.
        let on = try Harness()
        #expect(!on.center.suggestions().isEmpty)
        on.preferences.update { $0.showsMostUsed = false }
        #expect(on.center.suggestions().isEmpty)
        #expect(on.center.status() == .needsMostUsed)
    }

    @Test func statusWatchesUntilEnoughActiveDays() throws {
        let harness = try Harness(state: SuggestionState(enabledAt: now.addingTimeInterval(-2 * day), activeDays: 3))
        #expect(harness.center.status() == .watching(activeDays: 3, of: SuggestionPlanner.minimumActiveDays))
        #expect(harness.center.suggestions().isEmpty)

        // On without a saved window (cleared, unreadable): watching from now.
        let fresh = try Harness(state: SuggestionState())
        #expect(fresh.center.status() == .watching(activeDays: 0, of: 5))
        #expect(!harness.center.needsExplanation)

        // Never turned on: the explanation comes first, once; after that it doesn't.
        let never = try Harness(state: SuggestionState(), suggestionsOn: false)
        #expect(never.center.needsExplanation)
        never.center.setEnabled(true)
        never.center.setEnabled(false)
        #expect(!never.center.needsExplanation)
    }

    @Test func tooLittleDataMeansNoSuggestionsRightNow() throws {
        // Past the active days, but too few launches.
        let harness = try Harness(stats: routine(["a", "b", "c"], launches: 10, count: 9))
        #expect(harness.center.suggestions().isEmpty)
        #expect(harness.center.status() == .none)
    }

    @Test func turningOnStartsAWindowAndCreatesNothing() throws {
        let harness = try Harness(state: SuggestionState(), suggestionsOn: false)
        harness.center.setEnabled(true)
        #expect(harness.preferences.preferences.showsSuggestions)
        #expect(harness.usage.suggestionState.enabledAt == now)
        #expect(harness.center.suggestions().isEmpty)
        #expect(harness.groups.groups.isEmpty)
    }

    @Test func notNowSnoozesForAWeek() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        harness.center.dismiss(plan, for: .week)

        let dismissal = try #require(harness.usage.suggestionState.dismissed.last)
        #expect(dismissal.until == now.addingTimeInterval(7 * day))
        #expect(dismissal.kind == .newGroup)
        #expect(dismissal.apps == plan.appKeys.sorted())
        #expect(harness.center.suggestions().isEmpty)
        #expect(harness.groups.groups.isEmpty)

        // Kept across a relaunch, and back once the week is over.
        harness.reload()
        #expect(harness.center.suggestions().isEmpty)
        harness.clock = now.addingTimeInterval(7 * day - 1)
        #expect(harness.center.suggestions().isEmpty)
        harness.clock = now.addingTimeInterval(7 * day)
        #expect(harness.center.suggestions() == [plan])
    }

    @Test func notNowForAMonthSnoozesForThirtyDays() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        harness.center.dismiss(plan, for: .month)
        #expect(harness.usage.suggestionState.dismissed.last?.until == now.addingTimeInterval(30 * day))
    }

    @Test func dontSuggestThisAgainIsPermanent() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        harness.center.dismiss(plan, for: .forever)
        let dismissal = try #require(harness.usage.suggestionState.dismissed.last)
        #expect(dismissal.until == nil)

        harness.reload()
        #expect(harness.usage.suggestionState.dismissed.last?.until == nil)
        #expect(harness.usage.suggestionState.dismissed.last?.hasExpired(at: .distantFuture) == false)
        // Past a week's snooze, while the routine is still current: still not suggested.
        harness.clock = now.addingTimeInterval(12 * day)
        #expect(harness.center.suggestions().isEmpty)
        #expect(!harness.center.isCurrent(plan))
    }

    @Test func resetDismissedBringsSuggestionsBack() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        harness.center.dismiss(plan, for: .forever)
        #expect(harness.center.dismissedCount == 1)
        harness.center.resetDismissed()
        #expect(harness.center.dismissedCount == 0)
        harness.reload()
        #expect(harness.center.dismissedCount == 0)
        #expect(harness.center.suggestions() == [plan])
    }

    @Test func clearHistoryForgetsDismissals() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        harness.center.dismiss(plan, for: .forever)
        harness.usage.clearHistory()
        #expect(harness.center.dismissedCount == 0)
        #expect(harness.center.suggestions().isEmpty)
    }

    @Test func archivedGroupsAreNotPassedToThePlanner() throws {
        let harness = try Harness()
        let group = harness.groups.addGroup(named: "Work", items: [item("a"), item("b"), item("c")])
        #expect(harness.center.suggestions().isEmpty, "an active group with the apps suppresses it")
        _ = harness.groups.archiveGroup(group.id)
        #expect(harness.center.suggestions().count == 1, "an archived one doesn't")
    }

    @Test func addToGroupReviewListsTheGroupsAppsAsInTheGroup() throws {
        let harness = try Harness(stats: routine(["a", "b", "c", "x"]))
        let group = harness.groups.addGroup(named: "Design", items: [item("a"), item("b"), item("c")])
        let plan = try #require(harness.center.suggestions().first)
        #expect(plan.kind == .addToGroup)
        #expect(plan.group == group.id)

        let review = try #require(harness.center.reviewPlan(for: plan))
        #expect(review.target == .group(group.id))
        #expect(review.candidates.map(\.id) == [id("x"), id("a"), id("b"), id("c")])
        #expect(review.candidates.filter(\.isSelectable).map(\.id) == [id("x")])
        #expect(review.candidates.dropFirst().allSatisfy { $0.notes == [.inGroup] })
        #expect(review.defaultSelection == [id("x")])

        let rows = harness.center.menuRows()
        #expect(rows.map(\.groupName) == ["Design"])
        #expect(rows.first?.appNames == ["X"])

        // Committing through the store is the only way the app gets in.
        #expect(harness.groups.group(withID: group.id)?.apps.count == 3)
        _ = harness.groups.capture(review.defaultItems, into: review.target, named: "")
        #expect(harness.groups.group(withID: group.id)?.apps.count == 4)
        #expect(harness.center.suggestions().isEmpty)
    }

    @Test func reviewNeedsACurrentSuggestion() throws {
        let harness = try Harness()
        let plan = try #require(harness.center.suggestions().first)
        let review = try #require(harness.center.reviewPlan(for: plan))
        #expect(review.target == .newGroup)
        #expect(review.defaultSelection == plan.appKeys)
        #expect(review.candidates.allSatisfy { $0.isSelectable })
        #expect(!review.hasWindowInformation)
        #expect(harness.groups.groups.isEmpty, "reviewing creates nothing")

        harness.preferences.update { $0.showsSuggestions = false }
        #expect(harness.center.reviewPlan(for: plan) == nil)
    }

    @Test func protectedAppsAreNeverSuggested() throws {
        let harness = try Harness()
        harness.preferences.update { $0.protectedApps = ProtectedApps([item("a")]) }
        #expect(harness.center.suggestions().allSatisfy { !$0.appKeys.contains(id("a")) })
    }
}

@Suite("Suggestions: menu rows")
struct SuggestionMenuRowTests {
    private func plan(_ shorts: [String], group: UUID? = nil) -> SuggestionPlan {
        SuggestionPlan(
            kind: group == nil ? .newGroup : .addToGroup,
            apps: shorts.map(item),
            group: group,
            weakestPairCount: 9,
            totalPairCount: 9
        )
    }

    @Test func atMostThreeRows() {
        let plans = (0..<5).map { plan(["a\($0)", "b\($0)", "c\($0)"]) }
        let rows = SuggestionMenuRow.rows(for: plans) { _ in nil }
        #expect(rows.count == 3)
        #expect(SuggestionMenuRow.maximumRows == 3)
        #expect(rows.map(\.plan) == Array(plans.prefix(3)))
        #expect(SuggestionMenuRow.rows(for: []) { _ in nil }.isEmpty)
    }

    @Test func namesTheFirstThreeAppsAndCountsTheRest() {
        let rows = SuggestionMenuRow.rows(for: [plan(["a", "b", "c", "d", "e"]), plan(["f", "g", "h"])]) { _ in nil }
        #expect(rows[0].appNames == ["A", "B", "C"])
        #expect(rows[0].otherAppCount == 2)
        #expect(rows[1].otherAppCount == 0)
    }

    @Test func anAdditionWithoutAnActiveGroupHasNoRow() {
        let active = UUID()
        let gone = UUID()
        let rows = SuggestionMenuRow.rows(for: [plan(["x"], group: gone), plan(["y"], group: active)]) { $0 == active ? "Design" : nil }
        #expect(rows.map(\.groupName) == ["Design"])
        #expect(rows.map(\.appNames) == [["Y"]])
    }

    @Test func snoozeLengths() {
        #expect(SuggestionSnooze.week.until(from: now) == now.addingTimeInterval(7 * day))
        #expect(SuggestionSnooze.month.until(from: now) == now.addingTimeInterval(30 * day))
        #expect(SuggestionSnooze.forever.until(from: now) == nil)
    }
}

@Suite("Suggestions: Diagnostics")
struct SuggestionDiagnosticsTests {
    private func report(showsSuggestions: Bool, dismissed: Int) -> String {
        let info = DiagnosticsInfo(
            app: .init(version: "1.0.0", build: "10000", path: "/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "Version 15.1", hardwareModel: "Mac15,6", architecture: "arm64"),
            isAccessibilityTrusted: false,
            isStatusItemShown: true,
            preferences: PopupPreferences(showsSuggestions: showsSuggestions),
            updates: .init(lastCheckDate: nil, lastResult: "not checked"),
            groups: [],
            dismissedSuggestionCount: dismissed,
            recentErrors: []
        )
        return DiagnosticsReport.text(for: info, homeDirectory: "/Users/test")
    }

    @Test func oneLineWithTheSettingAndTheDismissedCount() {
        let off = report(showsSuggestions: false, dismissed: 0)
        #expect(off.components(separatedBy: "\n").filter { $0.hasPrefix("Suggestions:") } == ["Suggestions: off (0 dismissed)"])
        let on = report(showsSuggestions: true, dismissed: 4)
        #expect(on.components(separatedBy: "\n").filter { $0.hasPrefix("Suggestions:") } == ["Suggestions: on (4 dismissed)"])
        #expect(!on.contains("com.example"))
    }
}
