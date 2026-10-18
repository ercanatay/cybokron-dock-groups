import Foundation
import Testing
@testable import DockGroupsCore

/// The language list of the Settings picker against the string tables in `Resources`, the stored
/// language choice, and the `AppleLanguages` override that puts it into effect.
@Suite("Supported languages")
struct SupportedLanguagesTests {
    // MARK: - The list

    @Test func listHasTheTwentySixLanguagesOnce() {
        let codes = SupportedLanguages.all.map(\.code)
        #expect(codes.count == 26)
        #expect(Set(codes).count == codes.count, "a code is listed twice")
        #expect(Set(SupportedLanguages.all.map(\.nativeName)).count == codes.count, "a name is listed twice")
        #expect(codes.first == "en")
        #expect(codes.contains("tr"))
        #expect(!codes.contains("system"), "system is the stored form of the system choice")
        for language in SupportedLanguages.all {
            #expect(!language.nativeName.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.code) has no name")
            #expect(Locale(identifier: language.code).language.languageCode != nil, "\(language.code) isn't a language identifier")
        }
    }

    @Test func everyStringTableFolderIsListed() {
        let folders = LocalizationTests.languages
        #expect(folders.contains("en"))
        #expect(folders.contains("tr"))
        let listed = Set(SupportedLanguages.all.map(\.code))
        for folder in folders {
            #expect(listed.contains(folder), "Resources/\(folder).lproj needs an entry in SupportedLanguages.all")
        }
        // The picker offers exactly the folders, in list order.
        #expect(Set(SupportedLanguages.available(in: folders).map(\.code)) == Set(folders))
    }

    @Test func availableKeepsListOrderAndSkipsUnknownFolders() {
        let available = SupportedLanguages.available(in: ["tr", "Base", "ja", "en", "xx"])
        #expect(available.map(\.code) == ["en", "tr", "ja"])
        // With every table present the picker lists 26 languages (after "System").
        #expect(SupportedLanguages.available(in: SupportedLanguages.all.map(\.code)).count == 26)
    }

    @Test func nativeNames() {
        #expect(SupportedLanguages.language(withCode: "tr")?.nativeName == "Türkçe")
        #expect(SupportedLanguages.language(withCode: "de")?.nativeName == "Deutsch")
        #expect(SupportedLanguages.language(withCode: "ja")?.nativeName == "日本語")
        #expect(SupportedLanguages.language(withCode: "xx") == nil)
    }

    @Test(arguments: [
        (["tr-TR", "en-US"], ["en", "tr"], "tr"),
        (["en-GB"], ["en", "tr"], "en"),
        (["ja-JP"], ["en", "tr"], "en"),
        (["de-DE", "tr"], ["en", "tr"], "tr"),
        (["pt-BR"], ["en", "pt-BR"], "pt-BR"),
        (["zh-Hans-CN"], ["en", "zh-Hans"], "zh-Hans"),
    ])
    func systemLanguageIsTheOneTheBundlePicks(preferred: [String], localizations: [String], expected: String) {
        #expect(SupportedLanguages.match(forPreferredLanguages: preferred, in: localizations).code == expected)
    }

    // MARK: - The stored choice

    @Test func choiceIsStoredAsSystemOrTheCode() throws {
        #expect(AppLanguage(rawValue: "system") == .system)
        #expect(AppLanguage(rawValue: "tr") == .specific("tr"))
        #expect(AppLanguage(rawValue: "xx") == nil)
        #expect(AppLanguage.specific("de").rawValue == "de")

        #expect(PopupPreferences().language == .system)
        let data = try JSONEncoder().encode(PopupPreferences(language: .specific("tr")))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["language"] as? String == "tr")
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: data).language == .specific("tr"))
        let system = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PopupPreferences())) as? [String: Any]
        #expect(system?["language"] as? String == "system")
    }

    @Test(arguments: ["{}", #"{ "language": "xx" }"#, #"{ "language": 3 }"#, #"{ "language": "" }"#])
    func missingOrUnknownChoiceIsTheSystem(json: String) throws {
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: Data(json.utf8)).language == .system)
    }

    @Test func sanitizedDropsUnknownCodes() {
        #expect(PopupPreferences(language: .specific("xx")).sanitized().language == .system)
        #expect(PopupPreferences(language: .specific("de")).sanitized().language == .specific("de"))
    }

    @Test func agentsGetTheChoice() throws {
        let configuration = AgentConfiguration(group: DockGroup(name: "Work"), preferences: PopupPreferences(language: .specific("tr")))
        #expect(try AgentConfiguration.decode(from: configuration.encoded()).preferences.language == .specific("tr"))
    }

    // MARK: - AppleLanguages

    /// A defaults domain of its own, removed afterwards.
    private static func withDefaults(_ body: (UserDefaults, _ suite: String) throws -> Void) throws {
        let suite = "com.cybokron.dockgroups.language-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    @Test func pickedLanguageFallsBackToEnglish() {
        #expect(LanguageOverride.preferredLanguages(for: "tr") == ["tr", "en"])
        #expect(LanguageOverride.preferredLanguages(for: "en") == ["en"])
    }

    @Test func pickingALanguageSetsAppleLanguages() throws {
        try Self.withDefaults { defaults, _ in
            #expect(LanguageOverride.apply(.specific("tr"), to: defaults))
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["tr", "en"])
            // Unchanged the next launch.
            #expect(!LanguageOverride.apply(.specific("tr"), to: defaults))
            #expect(LanguageOverride.apply(.specific("de"), to: defaults))
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de", "en"])
        }
    }

    @Test func systemRemovesOnlyTheAppsOwnOverride() throws {
        try Self.withDefaults { defaults, suite in
            // Never picked one: nothing to undo.
            #expect(!LanguageOverride.apply(.system, to: defaults))

            LanguageOverride.apply(.specific("tr"), to: defaults)
            #expect(LanguageOverride.apply(.system, to: defaults))
            #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
            #expect(defaults.string(forKey: LanguageOverride.appliedLanguageKey) == nil)
            #expect(!LanguageOverride.apply(.system, to: defaults))

            // Changed in System Settings since: left alone.
            LanguageOverride.apply(.specific("tr"), to: defaults)
            defaults.set(["fr"], forKey: "AppleLanguages")
            #expect(LanguageOverride.apply(.system, to: defaults))
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
            #expect(defaults.string(forKey: LanguageOverride.appliedLanguageKey) == nil)
        }
    }
}
