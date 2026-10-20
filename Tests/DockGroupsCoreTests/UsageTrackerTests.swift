import Foundation
import Testing
@testable import DockGroupsCore

private func app(_ bundleIdentifier: String, _ name: String? = nil) -> AppReference {
    AppReference(bundleIdentifier: bundleIdentifier, name: name ?? bundleIdentifier, path: "/Applications/\(name ?? bundleIdentifier).app")
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
}

@Suite("Usage tracker")
struct UsageTrackerTests {
    @Test func countsLaunchesPerAppCaseInsensitively() {
        var tracker = UsageTracker()
        tracker.recordLaunch(of: app("com.example.Mail", "Mail"), at: at(0))
        tracker.recordLaunch(of: app("com.example.mail", "Mail"), at: at(1))
        tracker.recordLaunch(of: app("com.example.notes"), at: at(2))

        #expect(tracker.stats.apps["com.example.mail"]?.launchCount == 2)
        #expect(tracker.stats.apps["com.example.mail"]?.lastLaunchedAt == at(1))
        #expect(tracker.stats.apps["com.example.notes"]?.launchCount == 1)
        #expect(tracker.stats.totalLaunchCount == 3)
    }

    @Test func ignoresFilteredSystemProcesses() {
        var tracker = UsageTracker()
        for identifier in ["com.apple.finder", "com.apple.Spotlight", "com.apple.WebKit.WebContent", "com.apple.security.agent", "com.apple.accessibility.foo", ""] {
            let recorded = tracker.recordLaunch(of: app(identifier), at: at(0))
            #expect(!recorded, "\(identifier)")
        }
        #expect(tracker.stats.isEmpty)
        #expect(tracker.session.isEmpty)
        #expect(UsageTracker.isTracked(bundleIdentifier: "com.apple.TextEdit"))
    }

    @Test func pairsAppsLaunchedInTheSameSessionBothWays() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(60))
        tracker.recordLaunch(of: app("c"), at: at(120))

        #expect(tracker.stats.cooccurrence["a"] == ["b": 1, "c": 1])
        #expect(tracker.stats.cooccurrence["b"] == ["a": 1, "c": 1])
        #expect(tracker.stats.cooccurrence["c"] == ["a": 1, "b": 1])
    }

    @Test func appsOutsideTheWindowDontPair() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(601))

        #expect(tracker.stats.cooccurrence.isEmpty)
        #expect(tracker.sessionMembers(at: at(601)) == ["b"])
    }

    @Test func windowEdgeStillCounts() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(600))

        #expect(tracker.stats.cooccurrence["a"] == ["b": 1])
    }

    @Test func relaunchWithinTheSessionCountsButDoesntPairAgain() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(10))
        tracker.recordLaunch(of: app("a"), at: at(20))

        #expect(tracker.stats.apps["a"]?.launchCount == 2)
        #expect(tracker.stats.cooccurrence["a"] == ["b": 1])
        #expect(tracker.stats.cooccurrence["b"] == ["a": 1])
    }

    @Test func activationKeepsASessionAppInTheSession() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordActivation(bundleIdentifier: "A", at: at(500))
        tracker.recordLaunch(of: app("b"), at: at(900))

        #expect(tracker.stats.cooccurrence["b"] == ["a": 1])
        #expect(tracker.stats.apps["a"]?.launchCount == 1, "activations aren't launches")
    }

    @Test func activationDoesntAddAppsToTheSession() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordActivation(bundleIdentifier: "a", at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(10))

        #expect(tracker.stats.cooccurrence.isEmpty)
        #expect(tracker.stats.apps["a"] == nil)
    }

    @Test func shorterSessionLengthAppliesToTheExistingSession() {
        var tracker = UsageTracker(sessionLength: 600)
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.sessionLength = 120
        tracker.recordLaunch(of: app("b"), at: at(300))

        #expect(tracker.stats.cooccurrence.isEmpty)
    }

    @Test func launchKeepsTheLatestNameAndKnownPath() {
        var tracker = UsageTracker()
        tracker.recordLaunch(of: app("a", "Old"), at: at(0))
        tracker.recordLaunch(of: AppReference(bundleIdentifier: "a", name: "New", path: nil), at: at(1))

        #expect(tracker.stats.apps["a"]?.app.name == "New")
        #expect(tracker.stats.apps["a"]?.app.path == "/Applications/Old.app")
    }

    @Test func resetForgetsEverything() {
        var tracker = UsageTracker()
        tracker.recordLaunch(of: app("a"), at: at(0))
        tracker.recordLaunch(of: app("b"), at: at(1))
        tracker.reset()

        #expect(tracker.stats == UsageStats())
        #expect(tracker.session.isEmpty)
    }
}

@Suite("Most Used ranking")
struct MostUsedRankingTests {
    private func stats(_ launches: [String: Int], pairs: [String: [String: Int]] = [:]) -> UsageStats {
        UsageStats(
            apps: launches.reduce(into: [:]) { result, item in
                result[item.key] = AppUsage(app: app(item.key), launchCount: item.value, lastLaunchedAt: at(0))
            },
            cooccurrence: pairs
        )
    }

    @Test func ordersByLaunchCount() {
        let ranked = MostUsedRanking.rank(stats(["a": 2, "b": 5, "c": 3]), limit: 10)
        #expect(ranked.map(\.app.bundleIdentifier) == ["b", "c", "a"])
        #expect(ranked.map(\.launchCount) == [5, 3, 2])
    }

    @Test func scoreAddsThirtyPercentAtMost() {
        let values = stats(["a": 4, "b": 4], pairs: ["a": ["b": 2, "c": 9]])
        // a: 11 launches together, capped at its 4 launches.
        #expect(MostUsedRanking.score(of: "a", in: values) == 4 + 0.3 * 4)
        #expect(MostUsedRanking.score(of: "b", in: values) == 4)
        #expect(MostUsedRanking.score(of: "missing", in: values) == 0)
    }

    @Test func cooccurrenceBreaksCloseRaces() {
        let values = stats(["solo": 10, "routine": 9], pairs: ["routine": ["x": 9]])
        #expect(MostUsedRanking.rank(values, limit: 10).map(\.app.bundleIdentifier) == ["routine", "solo"])
    }

    @Test func cooccurrenceNeverBeatsMuchMoreLaunches() {
        let values = stats(["solo": 20, "routine": 9], pairs: ["routine": ["x": 9]])
        #expect(MostUsedRanking.rank(values, limit: 10).map(\.app.bundleIdentifier) == ["solo", "routine"])
    }

    @Test func tiesGoToTheMoreRecentAppThenTheName() {
        var values = stats(["b": 3, "a": 3, "c": 3])
        values.apps["c"]?.lastLaunchedAt = at(100)
        #expect(MostUsedRanking.rank(values, limit: 10).map(\.app.bundleIdentifier) == ["c", "a", "b"])
    }

    @Test func cutsOffAtTheLimit() {
        let values = stats(Dictionary(uniqueKeysWithValues: (1...20).map { ("app\($0)", $0) }))
        let ranked = MostUsedRanking.rank(values, limit: 10)
        #expect(ranked.count == 10)
        #expect(ranked.first?.app.bundleIdentifier == "app20")
        #expect(ranked.last?.app.bundleIdentifier == "app11")
        #expect(MostUsedRanking.rank(values, limit: 0).isEmpty)
    }

    @Test func skipsUnavailableAppsAndFillsUpWithTheNext() {
        let values = stats(["a": 5, "gone": 4, "b": 3, "c": 1])
        var checked: [String] = []
        let ranked = MostUsedRanking.rank(values, limit: 2) { app in
            checked.append(app.bundleIdentifier)
            return app.bundleIdentifier != "gone"
        }
        #expect(ranked.map(\.app.bundleIdentifier) == ["a", "b"])
        #expect(checked == ["a", "gone", "b"], "stops checking once the list is full")
    }

    @Test func emptyStatsGiveAnEmptyList() {
        #expect(MostUsedRanking.rank(UsageStats(), limit: 10).isEmpty)
    }

    @Test func filteredAppsInOldFilesAreLeftOut() {
        #expect(MostUsedRanking.rank(stats(["com.apple.finder": 50, "a": 1]), limit: 10).map(\.app.bundleIdentifier) == ["a"])
    }

    @Test func virtualGroupHasAFixedIdentityAndTheRankedApps() {
        let entries = MostUsedRanking.rank(stats(["a": 2, "b": 1]), limit: 10)
        let group = MostUsedGroup.group(with: entries)
        #expect(group.id == MostUsedGroup.id)
        #expect(group.name == "Most Used")
        #expect(group.emoji == "★")
        #expect(group.apps.map(\.bundleIdentifier) == ["a", "b"])
    }
}

@Suite("Usage store")
@MainActor
struct UsageStoreTests {
    /// A clock tests move forward by hand.
    final class Clock {
        var now = start
    }

    private func makeStore(in directory: TemporaryDirectory, clock: Clock, saveDelay: Duration = .zero) -> UsageStore {
        UsageStore(persistence: JSONFileUsagePersistence(directory: directory.url), saveDelay: saveDelay, now: { clock.now })
    }

    @Test func missingFilesMeanEmptyStatsAndNoWrite() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(in: directory, clock: Clock())

        #expect(store.stats.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func statisticsSurviveARestart() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        store.recordLaunch(of: app("com.example.mail", "Mail"))
        clock.now = at(30)
        store.recordLaunch(of: app("com.example.notes", "Notes"))
        store.recordLaunch(of: app("com.example.mail", "Mail"))

        let reloaded = makeStore(in: directory, clock: clock)

        #expect(reloaded.stats == store.stats)
        #expect(reloaded.mostUsed(limit: 10).map(\.app.name) == ["Mail", "Notes"])
        #expect(reloaded.stats.cooccurrence["com.example.mail"] == ["com.example.notes": 1])
    }

    @Test func writesBothFilesInTheDocumentedFormat() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        store.recordLaunch(of: app("com.example.Mail", "Mail"))
        store.recordLaunch(of: app("com.example.notes", "Notes"))

        let launches = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appending(path: "usage-stats.json"))) as? [String: Any]
        #expect(launches?["formatVersion"] as? Int == 1)
        let apps = launches?["apps"] as? [[String: Any]]
        #expect(apps?.first?["bundleIdentifier"] as? String == "com.example.Mail")
        #expect(apps?.first?["launchCount"] as? Int == 1)
        #expect(apps?.first?["lastLaunchedAt"] as? Double == start.timeIntervalSince1970)

        let pairs = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appending(path: "usage-cooccurrence.json"))) as? [String: Any]
        #expect((pairs?["pairs"] as? [String: [String: Int]])?["com.example.notes"] == ["com.example.mail": 1])
    }

    @Test func coalescesLaunchesIntoOneDelayedWrite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileUsagePersistence(directory: directory.url)
        let store = UsageStore(persistence: persistence, saveDelay: .milliseconds(100))
        store.recordLaunch(of: app("a"))
        store.recordLaunch(of: app("b"))

        #expect(!FileManager.default.fileExists(atPath: persistence.launchesFileURL.path))
        try await Task.sleep(for: .milliseconds(400))
        store.flushPendingSave()
        #expect(try persistence.loadLaunches().count == 2)
    }

    @Test func flushWritesAPendingChangeRightAway() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileUsagePersistence(directory: directory.url)
        let store = UsageStore(persistence: persistence, saveDelay: .seconds(60))
        store.recordLaunch(of: app("a"))
        store.flushPendingSave()

        #expect(try persistence.loadLaunches()["a"]?.launchCount == 1)
    }

    @Test func unreadableFilesAreMovedAsideAndCountingStartsOver() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileUsagePersistence(directory: directory.url)
        try Data("not json".utf8).write(to: persistence.launchesFileURL)
        try Data("[1, 2]".utf8).write(to: persistence.cooccurrenceFileURL)

        let store = UsageStore(persistence: persistence, saveDelay: .zero)
        #expect(store.stats.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(names.contains { $0.hasPrefix("usage-stats.unreadable-") })
        #expect(names.contains { $0.hasPrefix("usage-cooccurrence.unreadable-") })

        store.recordLaunch(of: app("a"))
        #expect(try persistence.loadLaunches()["a"]?.launchCount == 1)
    }

    @Test func oneUnreadableFileDoesntLoseTheOther() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileUsagePersistence(directory: directory.url)
        try persistence.save(UsageStats(apps: ["a": AppUsage(app: app("a"), launchCount: 3)]))
        try Data("{".utf8).write(to: persistence.cooccurrenceFileURL)

        let store = UsageStore(persistence: persistence, saveDelay: .zero)
        #expect(store.stats.apps["a"]?.launchCount == 3)
        #expect(store.stats.cooccurrence.isEmpty)
    }

    @Test func clearHistoryEmptiesTheFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(in: directory, clock: Clock())
        store.recordLaunch(of: app("a"))
        store.recordLaunch(of: app("b"))
        store.clearHistory()

        #expect(store.stats.isEmpty)
        #expect(store.mostUsed(limit: 10).isEmpty)
        #expect(makeStore(in: directory, clock: Clock()).stats.isEmpty)
    }

    @Test func sessionLengthChangesApplyToNewLaunches() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        store.sessionLength = 60
        store.recordLaunch(of: app("a"))
        clock.now = at(120)
        store.recordLaunch(of: app("b"))

        #expect(store.stats.cooccurrence.isEmpty)
        #expect(store.sessionMembers == ["b"])
    }
}

@Suite("Usage files")
struct UsageFileTests {
    private func persistence(in directory: TemporaryDirectory) -> JSONFileUsagePersistence {
        JSONFileUsagePersistence(directory: directory.url)
    }

    @Test func badEntriesAreSkippedAndGoodOnesKept() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data("""
        {"apps": [
            {"bundleIdentifier": "com.example.good", "name": "Good", "launchCount": 4, "lastLaunchedAt": 1800000000, "extra": true},
            {"bundleIdentifier": "com.example.noname", "launchCount": 1, "lastLaunchedAt": "yesterday"},
            {"bundleIdentifier": "com.example.zero", "launchCount": 0},
            {"bundleIdentifier": "com.example.text", "launchCount": "many"},
            {"name": "No identifier", "launchCount": 2},
            "garbage",
            {"bundleIdentifier": "com.example.GOOD", "launchCount": 1}
        ], "unknownKey": 1}
        """.utf8).write(to: persistence.launchesFileURL)

        let launches = try persistence.loadLaunches()

        #expect(Set(launches.keys) == ["com.example.good", "com.example.noname"])
        #expect(launches["com.example.good"]?.launchCount == 5, "duplicates add up")
        #expect(launches["com.example.good"]?.lastLaunchedAt == start)
        #expect(launches["com.example.noname"]?.app.name == "com.example.noname")
        #expect(launches["com.example.noname"]?.lastLaunchedAt == nil)
    }

    @Test func cooccurrenceKeepsOnlyPositiveCounts() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data("""
        {"pairs": {
            "A": {"b": 2, "c": -1, "d": "x", "a": 5},
            "b": {"A": 2},
            "broken": 7
        }}
        """.utf8).write(to: persistence.cooccurrenceFileURL)

        #expect(try persistence.loadCooccurrence() == ["a": ["b": 2], "b": ["a": 2]])
    }

    @Test func missingSectionsMeanEmpty() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data("{}".utf8).write(to: persistence.launchesFileURL)
        try Data("{\"formatVersion\": 1}".utf8).write(to: persistence.cooccurrenceFileURL)

        #expect(try persistence.loadLaunches().isEmpty)
        #expect(try persistence.loadCooccurrence().isEmpty)
    }

    @Test func newerFormatIsRejected() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data("{\"formatVersion\": 99, \"apps\": []}".utf8).write(to: persistence.launchesFileURL)

        #expect(throws: UsagePersistenceError.unsupportedFormatVersion(99)) {
            try persistence.loadLaunches()
        }
    }

    @Test func nonObjectFilesAreRejected() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try Data("[]".utf8).write(to: persistence.launchesFileURL)

        #expect(throws: (any Error).self) {
            try persistence.loadLaunches()
        }
    }
}

/// `UsageStore(isRecordingEnabled:)`: the Most Used setting gates recording at every event; what
/// was recorded stays when it's turned off.
@Suite("Usage recording switch")
@MainActor
struct UsageRecordingSwitchTests {
    /// Stands in for the Most Used setting.
    final class Switch {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    private func makeStore(in directory: TemporaryDirectory, setting: Switch, now: @escaping () -> Date = { start }) -> UsageStore {
        UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            now: now,
            isRecordingEnabled: { setting.isOn }
        )
    }

    @Test func nothingIsRecordedWhileMostUsedIsOff() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(in: directory, setting: Switch(false))

        #expect(!store.isRecording)
        #expect(!store.recordLaunch(of: app("com.example.mail", "Mail")))
        store.recordActivation(bundleIdentifier: "com.example.mail")

        #expect(store.stats.isEmpty)
        #expect(store.sessionMembers.isEmpty)
        // Not even an empty file is written.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func turningItOffStopsRecordingAndKeepsTheHistory() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let setting = Switch(true)
        let store = makeStore(in: directory, setting: setting)
        #expect(store.recordLaunch(of: app("com.example.mail", "Mail")))
        let recorded = store.stats

        setting.isOn = false
        #expect(!store.recordLaunch(of: app("com.example.notes", "Notes")))
        #expect(!store.recordLaunch(of: app("com.example.mail", "Mail")))

        #expect(store.stats == recorded, "events while off are dropped; earlier ones stay")
        #expect(makeStore(in: directory, setting: setting).stats == recorded, "the saved history is kept")
    }

    @Test func turningItBackOnRecordsNewEventsOnly() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let setting = Switch(false)
        let store = makeStore(in: directory, setting: setting)
        store.recordLaunch(of: app("com.example.mail", "Mail"))

        setting.isOn = true
        #expect(store.recordLaunch(of: app("com.example.notes", "Notes")))

        #expect(store.mostUsed(limit: 10).map(\.app.name) == ["Notes"])
    }

    @Test func theSettingIsAskedAtEveryEvent() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var asked = 0
        let store = UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            isRecordingEnabled: { asked += 1; return asked.isMultiple(of: 2) }
        )

        let first = store.recordLaunch(of: app("a"))
        let second = store.recordLaunch(of: app("b"))
        store.recordActivation(bundleIdentifier: "b")

        #expect([first, second] == [false, true])
        #expect(asked == 3)
        #expect(store.stats.apps.keys.sorted() == ["b"])
    }

    @Test func storesWithoutASwitchRecordAsBefore() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = UsageStore(persistence: JSONFileUsagePersistence(directory: directory.url), saveDelay: .zero)

        #expect(store.isRecording)
        #expect(store.recordLaunch(of: app("com.example.mail", "Mail")))
    }
}
