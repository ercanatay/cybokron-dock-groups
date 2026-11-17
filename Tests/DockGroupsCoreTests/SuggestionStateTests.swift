import Foundation
import Testing
@testable import DockGroupsCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func app(_ bundleIdentifier: String) -> AppReference {
    AppReference(bundleIdentifier: bundleIdentifier, name: bundleIdentifier, path: "/Applications/\(bundleIdentifier).app")
}

/// A fixed calendar, so local calendar days don't depend on the machine running the tests.
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func decodeState(_ json: String) throws -> SuggestionState {
    try JSONDecoder().decode(SuggestionState.self, from: Data(json.utf8))
}

@Suite("Suggestion state")
struct SuggestionStateTests {
    @Test func roundTripsThroughJSON() throws {
        let group = UUID()
        var state = SuggestionState(enabledAt: start, activeDays: 4, lastActiveDay: "2027-01-15")
        state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ["com.example.B", "com.example.a"]), now: start)
        state.addDismissal(DismissedSuggestion(kind: .addToGroup, apps: ["com.example.c"], group: group, until: start.addingTimeInterval(86_400)), now: start)

        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SuggestionState.self, from: data) == state)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == 1)
        #expect(object?["enabledAt"] as? Double == start.timeIntervalSince1970)
        #expect(object?["lastActiveDay"] as? String == "2027-01-15")
        let dismissed = object?["dismissed"] as? [[String: Any]]
        #expect(dismissed?.first?["apps"] as? [String] == ["com.example.a", "com.example.b"], "lowercased and sorted")
        #expect(dismissed?.first?["until"] is NSNull, "never again is written as null")
        #expect(dismissed?.last?["group"] as? String == group.uuidString)
    }

    @Test func unknownFieldsAndUnreadableEntriesAreIgnored() throws {
        let state = try decodeState("""
        {"formatVersion": 1, "enabledAt": 1800000000, "activeDays": 3, "lastActiveDay": "2027-01-15",
         "future": {"anything": [1, 2]},
         "dismissed": [
           {"kind": "newGroup", "apps": ["com.example.a", 7, ""], "until": null, "extra": true},
           {"kind": "somethingElse", "apps": ["com.example.b"]},
           {"kind": "newGroup", "apps": []},
           {"kind": "addToGroup", "apps": ["com.example.c"]},
           "not an object"
         ]}
        """)
        #expect(state.enabledAt == start)
        #expect(state.activeDays == 3)
        #expect(state.dismissed == [DismissedSuggestion(kind: .newGroup, apps: ["com.example.a"])])
    }

    @Test func malformedValuesFallBackToTheirDefaults() throws {
        let state = try decodeState("""
        {"enabledAt": "yesterday", "activeDays": -4, "lastActiveDay": "15.01.2027", "dismissed": {"a": 1}}
        """)
        #expect(state == SuggestionState())
    }

    @Test func countsEachLocalDayOnce() {
        var state = SuggestionState(enabledAt: start)
        for offset in [0.0, 60, 3_600] {
            state.recordActivity(at: start.addingTimeInterval(offset), calendar: utc)
        }
        #expect(state.activeDays == 1)
        #expect(state.lastActiveDay == SuggestionState.day(of: start, calendar: utc))

        let nextDay = state.recordActivity(at: start.addingTimeInterval(86_400), calendar: utc)
        #expect(nextDay)
        #expect(state.activeDays == 2)
        let sameDay = state.recordActivity(at: start.addingTimeInterval(86_400 + 60), calendar: utc)
        #expect(!sameDay)
        let earlier = state.recordActivity(at: start.addingTimeInterval(60), calendar: utc)
        #expect(!earlier, "a clock that went back doesn't count")
        #expect(state.activeDays == 2)
    }

    @Test func nothingCountsWithoutOrBeforeEnabledAt() {
        var never = SuggestionState()
        let counted = never.recordActivity(at: start, calendar: utc)
        #expect(!counted)
        #expect(never == SuggestionState())

        var later = SuggestionState(enabledAt: start.addingTimeInterval(60))
        let countedEarly = later.recordActivity(at: start, calendar: utc)
        #expect(!countedEarly)
        #expect(later.activeDays == 0)
    }

    @Test func startingAgainResetsTheWindowButKeepsDismissals() {
        let dismissal = DismissedSuggestion(kind: .newGroup, apps: ["a", "b", "c"])
        var state = SuggestionState(enabledAt: start, activeDays: 9, lastActiveDay: "2027-01-15", dismissed: [dismissal])
        state.start(at: start.addingTimeInterval(100))
        #expect(state == SuggestionState(enabledAt: start.addingTimeInterval(100), dismissed: [dismissal]))
    }

    @Test func dismissalsAreCappedDroppingTheOldestExpiredFirst() {
        let now = start
        var state = SuggestionState()
        for index in 0..<SuggestionState.maxDismissed {
            // Entries 10 and 20 have timed out; all others hold.
            let until: Date? = index == 10 || index == 20 ? now.addingTimeInterval(-1) : (index.isMultiple(of: 2) ? nil : now.addingTimeInterval(3_600))
            state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ["app\(index)"], until: until), now: now)
        }
        #expect(state.dismissed.count == 200)

        state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ["app200"]), now: now)
        #expect(state.dismissed.count == 200)
        #expect(!state.dismissed.contains { $0.apps == ["app10"] }, "the oldest expired one goes")
        #expect(state.dismissed.contains { $0.apps == ["app20"] })
        #expect(state.dismissed.first?.apps == ["app0"])
        #expect(state.dismissed.last?.apps == ["app200"])

        state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ["app201"]), now: now)
        state.addDismissal(DismissedSuggestion(kind: .newGroup, apps: ["app202"]), now: now)
        #expect(!state.dismissed.contains { $0.apps == ["app20"] })
        #expect(!state.dismissed.contains { $0.apps == ["app0"] }, "without expired ones, the oldest goes")
        #expect(state.dismissed.count == 200)
    }

    @Test func aFileWithTooManyDismissalsKeepsTheNewest() throws {
        let entries = (0..<250).map { #"{"kind": "newGroup", "apps": ["app\#($0)"]}"# }.joined(separator: ",")
        let state = try decodeState(#"{"dismissed": [\#(entries)]}"#)
        #expect(state.dismissed.count == 200)
        #expect(state.dismissed.first?.apps == ["app50"])
    }
}

@Suite("Suggestion state file")
struct SuggestionStatePersistenceTests {
    @Test func missingFileIsAFreshState() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(try JSONFileSuggestionStatePersistence(directory: directory.url).loadState() == SuggestionState())
    }

    @Test func savesAndLoads() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileSuggestionStatePersistence(directory: directory.url)
        let state = SuggestionState(enabledAt: start, activeDays: 2, lastActiveDay: "2027-01-16")
        try persistence.saveState(state)

        #expect(persistence.fileURL.lastPathComponent == "suggestions-state.json")
        #expect(try persistence.loadState() == state)
    }

    @Test func unreadableAndNewerFilesThrow() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileSuggestionStatePersistence(directory: directory.url)
        try Data("not json".utf8).write(to: persistence.fileURL)
        #expect(throws: (any Error).self) { try persistence.loadState() }

        try Data(#"{"formatVersion": 2, "activeDays": 3}"#.utf8).write(to: persistence.fileURL)
        #expect(throws: SuggestionStatePersistenceError.unsupportedFormatVersion(2)) { try persistence.loadState() }
    }

    @Test func deleteRemovesTheFileAndToleratesNone() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = JSONFileSuggestionStatePersistence(directory: directory.url)
        try persistence.deleteState()
        try persistence.saveState(SuggestionState(enabledAt: start))
        try persistence.deleteState()
        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }
}

/// `UsageStore` with a suggestions state: active days, turning Suggestions on, Clear History.
@Suite("Usage store suggestions state")
@MainActor
struct UsageStoreSuggestionStateTests {
    final class Clock {
        var now = start
    }

    final class Switch {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    private func makeStore(
        in directory: TemporaryDirectory,
        clock: Clock,
        suggestions: Switch,
        recording: Switch = Switch(true)
    ) -> UsageStore {
        UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            now: { clock.now },
            isRecordingEnabled: { recording.isOn },
            suggestionPersistence: JSONFileSuggestionStatePersistence(directory: directory.url),
            areSuggestionsEnabled: { suggestions.isOn },
            calendar: utc
        )
    }

    /// A store whose Suggestions switch is the preference, as in the app.
    private func makeStore(in directory: TemporaryDirectory, clock: Clock, preferences: PreferencesStore) -> UsageStore {
        UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            now: { clock.now },
            suggestionPersistence: JSONFileSuggestionStatePersistence(directory: directory.url),
            areSuggestionsEnabled: { preferences.preferences.showsSuggestions },
            calendar: utc
        )
    }

    private func makePreferences(in directory: TemporaryDirectory) -> PreferencesStore {
        PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: directory.url.appending(path: "preferences.json")), saveDelay: .zero)
    }

    private func stateFile(in directory: TemporaryDirectory) -> URL {
        directory.url.appending(path: "suggestions-state.json")
    }

    @Test func activeDaysCountOncePerDayWhileSuggestionsAreOn() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let preferences = makePreferences(in: directory)
        let store = makeStore(in: directory, clock: clock, preferences: preferences)
        store.setSuggestionsEnabled(true, in: preferences)
        #expect(preferences.preferences.showsSuggestions)
        #expect(store.suggestionState.enabledAt == start)

        for offset in [10.0, 20, 30] {
            clock.now = start.addingTimeInterval(offset)
            store.recordLaunch(of: app("com.example.app\(Int(offset))"))
        }
        #expect(store.suggestionState.activeDays == 1)

        clock.now = start.addingTimeInterval(86_400)
        store.recordLaunch(of: app("com.example.mail"))
        #expect(store.suggestionState.activeDays == 2)
        #expect(try JSONFileSuggestionStatePersistence(directory: directory.url).loadState() == store.suggestionState, "written right away")
    }

    @Test func nothingCountsWhileSuggestionsOrRecordingAreOff() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let suggestions = Switch(true)
        let recording = Switch(true)
        try JSONFileSuggestionStatePersistence(directory: directory.url).saveState(SuggestionState(enabledAt: start))
        let store = makeStore(in: directory, clock: clock, suggestions: suggestions, recording: recording)

        suggestions.isOn = false
        store.recordLaunch(of: app("a"))
        #expect(store.suggestionState.activeDays == 0)

        suggestions.isOn = true
        recording.isOn = false
        store.recordLaunch(of: app("a"))
        #expect(store.suggestionState.activeDays == 0)

        recording.isOn = true
        store.recordLaunch(of: app("a"))
        #expect(store.suggestionState.activeDays == 1)
    }

    @Test func withoutEnabledAtNothingCounts() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // Suggestions off at launch: no window is started, so turning the switch on behind the
        // store's back (not through `setSuggestionsEnabled`) counts nothing.
        let suggestions = Switch(false)
        let store = makeStore(in: directory, clock: Clock(), suggestions: suggestions)
        suggestions.isOn = true
        store.recordLaunch(of: app("a"))

        #expect(store.suggestionState == SuggestionState())
        #expect(!FileManager.default.fileExists(atPath: stateFile(in: directory).path))
    }

    @Test func turningOnAgainResetsTheWindowAndTurningOffKeepsTheFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let preferences = makePreferences(in: directory)
        let store = makeStore(in: directory, clock: clock, preferences: preferences)
        store.setSuggestionsEnabled(true, in: preferences)

        clock.now = start.addingTimeInterval(60)
        store.setSuggestionsEnabled(true, in: preferences)
        #expect(store.suggestionState.enabledAt == start, "already on: unchanged")

        store.setSuggestionsEnabled(false, in: preferences)
        #expect(!preferences.preferences.showsSuggestions)
        #expect(FileManager.default.fileExists(atPath: stateFile(in: directory).path))

        clock.now = start.addingTimeInterval(120)
        store.setSuggestionsEnabled(true, in: preferences)
        #expect(store.suggestionState.enabledAt == start.addingTimeInterval(120))
        #expect(store.suggestionState.activeDays == 0)
    }

    @Test func unreadableStateIsMovedAsideAndStartsEmpty() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("{ broken".utf8).write(to: stateFile(in: directory))
        let store = makeStore(in: directory, clock: Clock(), suggestions: Switch(false))

        #expect(store.suggestionState == SuggestionState())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(names.contains { $0.hasPrefix("suggestions-state.unreadable-") })
        #expect(!names.contains("suggestions-state.json"))
    }

    @Test func aNewerStateIsMovedAsideAndAWindowStartsWhenOn() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data(#"{"formatVersion": 9, "enabledAt": 1, "activeDays": 99}"#.utf8).write(to: stateFile(in: directory))
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock, suggestions: Switch(true))

        #expect(store.suggestionState == SuggestionState(enabledAt: start))
        store.flushPendingSave()
        #expect(try JSONFileSuggestionStatePersistence(directory: directory.url).loadState() == SuggestionState(enabledAt: start))
    }

    @Test func clearHistoryDeletesTheStateFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let preferences = makePreferences(in: directory)
        let store = makeStore(in: directory, clock: clock, preferences: preferences)
        store.setSuggestionsEnabled(true, in: preferences)
        store.recordLaunch(of: app("a"))
        #expect(store.suggestionState.activeDays == 1)
        #expect(FileManager.default.fileExists(atPath: stateFile(in: directory).path))

        store.setSuggestionsEnabled(false, in: preferences)
        store.clearHistory()
        #expect(!FileManager.default.fileExists(atPath: stateFile(in: directory).path))
        #expect(store.suggestionState == SuggestionState())
        store.flushPendingSave()
        #expect(!FileManager.default.fileExists(atPath: stateFile(in: directory).path))
    }

    @Test func clearHistoryWhileOnRestartsTheWindow() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock, suggestions: Switch(true))
        store.recordLaunch(of: app("a"))
        #expect(store.suggestionState.activeDays == 1)

        clock.now = start.addingTimeInterval(500)
        store.clearHistory()
        #expect(!FileManager.default.fileExists(atPath: stateFile(in: directory).path))
        #expect(store.suggestionState == SuggestionState(enabledAt: start.addingTimeInterval(500)))
    }

    @Test func storesWithoutSuggestionPersistenceKeepNoState() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = UsageStore(
            persistence: JSONFileUsagePersistence(directory: directory.url),
            saveDelay: .zero,
            areSuggestionsEnabled: { true }
        )
        store.recordLaunch(of: app("a"))
        store.clearHistory()
        #expect(store.suggestionState == SuggestionState())
        #expect(!FileManager.default.fileExists(atPath: stateFile(in: directory).path))
    }
}

@Suite("Suggestions preference")
struct ShowsSuggestionsPreferenceTests {
    private func decode(_ json: String) throws -> PopupPreferences {
        try JSONDecoder().decode(PopupPreferences.self, from: Data(json.utf8))
    }

    @Test func offByDefaultAndWhenMissing() throws {
        #expect(!PopupPreferences().showsSuggestions)
        #expect(try !decode("{}").showsSuggestions)
    }

    @Test func onlyAnExplicitTrueTurnsItOn() throws {
        for value in ["1", #""true""#, #""yes""#, "null", "{}", "[true]", "false", "0"] {
            #expect(try !decode(#"{"showsSuggestions": \#(value)}"#).showsSuggestions, "\(value)")
        }
        #expect(try decode(#"{"showsSuggestions": true}"#).showsSuggestions)
    }

    @Test func writtenOnlyWhileOn() throws {
        let off = String(decoding: try JSONEncoder().encode(PopupPreferences()), as: UTF8.self)
        #expect(!off.contains("showsSuggestions"), "preferences that never had it are written as before")
        let on = try JSONEncoder().encode(PopupPreferences(showsSuggestions: true))
        #expect(String(decoding: on, as: UTF8.self).contains(#""showsSuggestions":true"#))
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: on).showsSuggestions)
    }

    @Test func standaloneSnapshotsHaveItOff() {
        let configuration = AgentConfiguration(group: DockGroup(name: "G"), preferences: PopupPreferences(showsSuggestions: true))
        #expect(!configuration.preferences.showsSuggestions)
    }

    @Test func backupsNeitherCarryNorRestoreIt() throws {
        let backup = SettingsBackup(appVersion: "1.0", groups: [], preferences: PopupPreferences(showsSuggestions: true))
        #expect(!backup.preferences.showsSuggestions)
        #expect(!String(decoding: try backup.encoded(), as: UTF8.self).contains("showsSuggestions"))

        // A hand-made backup that has it on.
        var object = try JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any] ?? [:]
        var preferences = object["preferences"] as? [String: Any] ?? [:]
        preferences["showsSuggestions"] = true
        object["preferences"] = preferences
        let crafted = try JSONSerialization.data(withJSONObject: object)
        #expect(try !SettingsBackup.decode(from: crafted).preferences.showsSuggestions)
    }

    @MainActor @Test func restoringABackupTurnsItOff() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json")), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: directory.url.appending(path: "preferences.json")), saveDelay: .zero)
        preferences.update { $0.showsSuggestions = true }

        var backup = SettingsBackup(appVersion: "1.0", groups: [], preferences: PopupPreferences())
        backup.preferences.showsSuggestions = true // set behind the initializer's back
        try backup.restore(to: groups, preferences: preferences)

        #expect(!preferences.preferences.showsSuggestions)
    }
}
