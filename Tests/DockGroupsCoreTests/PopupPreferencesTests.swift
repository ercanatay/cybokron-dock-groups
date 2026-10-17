import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Popup preferences")
@MainActor
struct PopupPreferencesTests {
    private func persistence(in directory: TemporaryDirectory) -> JSONFilePreferencesPersistence {
        JSONFilePreferencesPersistence(fileURL: directory.url.appending(path: "preferences.json"))
    }

    private func write(_ json: String, to persistence: JSONFilePreferencesPersistence) throws {
        try Data(json.utf8).write(to: persistence.fileURL)
    }

    @Test func defaultsAreDarkFrostedAutoLayout() {
        let defaults = PopupPreferences()
        #expect(defaults.theme == .dark)
        #expect(defaults.usesFrostedGlass)
        #expect(defaults.columns == .auto)
        #expect(defaults.maxRows == PopupPreferences.defaultMaxRows)
        #expect(defaults.showsTitles)
        #expect(defaults.anchor == .dockCenter)
    }

    @Test func groupOverridesWinOverDefaults() {
        let defaults = PopupPreferences(columns: .fixed(6), maxRows: 2, showsTitles: true, anchor: .dockCenter)

        #expect(defaults.resolved(with: PopupOverrides()) == PopupSettings(
            columns: .fixed(6), maxRows: 2, showsTitles: true, anchor: .dockCenter
        ))
        #expect(defaults.resolved(with: PopupOverrides(columns: .auto, showsTitles: false)) == PopupSettings(
            columns: .auto, maxRows: 2, showsTitles: false, anchor: .dockCenter
        ))
        #expect(defaults.resolved(with: PopupOverrides(maxRows: 7, anchor: .dockIcon)) == PopupSettings(
            columns: .fixed(6), maxRows: 7, showsTitles: true, anchor: .dockIcon
        ))
    }

    @Test func missingFileMeansDefaultsAndNoWrite() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)

        let store = PreferencesStore(persistence: persistence, saveDelay: .zero)

        #expect(store.preferences == PopupPreferences())
        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func fileUsesFlatKeysWithFormatVersion() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)

        try persistence.savePreferences(PopupPreferences(theme: .light, usesFrostedGlass: false, columns: .fixed(3)))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == 1)
        #expect(object?["panelTheme"] as? String == "light")
        #expect(object?["glassyStyle"] as? Bool == false)
        #expect(object?["popupColumns"] as? Int == 3)
        #expect(object?["popupMaxRows"] as? Int == PopupPreferences.defaultMaxRows)
        #expect(object?["popupShowsTitles"] as? Bool == true)
        #expect(object?["popupAnchor"] as? String == "dockCenter")
    }

    @Test func changesSurviveARestart() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)

        let store = PreferencesStore(persistence: persistence, saveDelay: .zero)
        store.update {
            $0.theme = .system
            $0.columns = .fixed(4)
            $0.maxRows = 2
            $0.showsTitles = false
            $0.anchor = .dockIcon
        }

        let reloaded = PreferencesStore(persistence: persistence, saveDelay: .zero)
        #expect(reloaded.preferences == store.preferences)
        #expect(reloaded.preferences.columns == .fixed(4))
    }

    @Test func pendingChangeIsWrittenOnFlush() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)

        let store = PreferencesStore(persistence: persistence, saveDelay: .seconds(60))
        store.update { $0.usesFrostedGlass = false }
        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))

        store.flushPendingSave()
        #expect(try persistence.loadPreferences()?.usesFrostedGlass == false)
    }

    @Test func unknownOrInvalidValuesFallBackFieldByField() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try write("""
        {
          "formatVersion": 7,
          "panelTheme": "neon",
          "glassyStyle": "yes",
          "popupColumns": 3,
          "popupMaxRows": 99,
          "popupShowsTitles": false,
          "popupAnchor": "dockIcon",
          "popupShowsMostUsed": true,
          "somethingNew": { "nested": [1, 2, 3] }
        }
        """, to: persistence)

        let preferences = try #require(try persistence.loadPreferences())

        #expect(preferences.theme == .dark)
        #expect(preferences.usesFrostedGlass == true)
        #expect(preferences.columns == .fixed(3))
        #expect(preferences.maxRows == PopupPreferences.defaultMaxRows)
        #expect(preferences.showsTitles == false)
        #expect(preferences.anchor == .dockIcon)
    }

    @Test func emptyObjectGivesDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try write("{}", to: persistence)

        #expect(try persistence.loadPreferences() == PopupPreferences())
    }

    @Test func outOfRangeColumnsFallBackToAuto() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try write(#"{ "popupColumns": 0 }"#, to: persistence)

        #expect(try persistence.loadPreferences()?.columns == .auto)
    }

    @Test func unreadableFileIsMovedAsideAndDefaultsAreUsed() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let persistence = persistence(in: directory)
        try write("[\"not\", \"preferences\"]", to: persistence)

        let store = PreferencesStore(persistence: persistence, saveDelay: .zero)

        #expect(store.preferences == PopupPreferences())
        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            .filter { $0.hasPrefix("preferences.unreadable-") }
        #expect(kept.count == 1)

        store.update { $0.showsTitles = false }
        #expect(try persistence.loadPreferences()?.showsTitles == false)
    }

    @Test func storeRejectsOutOfRangeCounts() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let store = PreferencesStore(persistence: persistence(in: directory), saveDelay: .zero)
        store.update {
            $0.maxRows = 0
            $0.columns = .fixed(42)
        }

        #expect(store.preferences.maxRows == PopupPreferences.defaultMaxRows)
        #expect(store.preferences.columns == .auto)
    }
}
