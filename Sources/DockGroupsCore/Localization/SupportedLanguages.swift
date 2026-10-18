import Foundation

/// A language the app can be shown in: its `<code>.lproj` string table and its name in itself.
public struct SupportedLanguage: Hashable, Sendable, Identifiable {
    /// The language identifier, also the name of its folder of string tables (`<code>.lproj`).
    public let code: String
    /// The language's name in the language itself ("Deutsch", "日本語"), as language pickers show it.
    public let nativeName: String

    public var id: String { code }

    public init(code: String, nativeName: String) {
        self.code = code
        self.nativeName = nativeName
    }
}

/// The languages the language picker in Settings knows, in the order it lists them.
///
/// The one list to update when a language is added: a new `Resources/<code>.lproj` folder needs its
/// entry here (`SupportedLanguagesTests` check every folder has one). The picker offers only the
/// languages whose table the app bundle has, so an entry without a folder yet is simply not shown.
public enum SupportedLanguages {
    public static let all: [SupportedLanguage] = [
        SupportedLanguage(code: "en", nativeName: "English"),
        SupportedLanguage(code: "tr", nativeName: "Türkçe"),
        SupportedLanguage(code: "az", nativeName: "Azərbaycan dili"),
        SupportedLanguage(code: "de", nativeName: "Deutsch"),
        SupportedLanguage(code: "fr", nativeName: "Français"),
        SupportedLanguage(code: "es", nativeName: "Español"),
        SupportedLanguage(code: "it", nativeName: "Italiano"),
        SupportedLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
        SupportedLanguage(code: "nl", nativeName: "Nederlands"),
        SupportedLanguage(code: "sv", nativeName: "Svenska"),
        SupportedLanguage(code: "pl", nativeName: "Polski"),
        SupportedLanguage(code: "cs", nativeName: "Čeština"),
        SupportedLanguage(code: "ro", nativeName: "Română"),
        SupportedLanguage(code: "hu", nativeName: "Magyar"),
        SupportedLanguage(code: "el", nativeName: "Ελληνικά"),
        SupportedLanguage(code: "bg", nativeName: "Български"),
        SupportedLanguage(code: "uk", nativeName: "Українська"),
        SupportedLanguage(code: "ru", nativeName: "Русский"),
        SupportedLanguage(code: "ar", nativeName: "العربية"),
        SupportedLanguage(code: "fa", nativeName: "فارسی"),
        SupportedLanguage(code: "hi", nativeName: "हिन्दी"),
        SupportedLanguage(code: "zh-Hans", nativeName: "简体中文"),
        SupportedLanguage(code: "ja", nativeName: "日本語"),
        SupportedLanguage(code: "ko", nativeName: "한국어"),
        SupportedLanguage(code: "id", nativeName: "Bahasa Indonesia"),
        SupportedLanguage(code: "vi", nativeName: "Tiếng Việt"),
    ]

    /// The language with this code, `nil` for codes the list doesn't have.
    public static func language(withCode code: String) -> SupportedLanguage? {
        all.first { $0.code == code }
    }

    /// The listed languages a bundle has string tables for (`Bundle.localizations`), in list order.
    public static func available(in localizations: [String]) -> [SupportedLanguage] {
        let present = Set(localizations)
        return all.filter { present.contains($0.code) }
    }

    /// The listed language a bundle with `localizations` shows for a user who prefers
    /// `preferredLanguages` (most preferred first), as `Bundle` picks it; English when none matches.
    public static func match(
        forPreferredLanguages preferredLanguages: [String],
        in localizations: [String]
    ) -> SupportedLanguage {
        let available = available(in: localizations).map(\.code)
        let picked = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages).first
        return picked.flatMap(language(withCode:)) ?? all[0]
    }
}

/// The language the app is shown in: the system's (the user's preferred languages in System
/// Settings) or one picked in Settings, stored in `preferences.json` as `"system"` or the code.
public enum AppLanguage: Hashable, Sendable {
    case system
    /// One of `SupportedLanguages.all`, by code.
    case specific(String)

    /// The stored form: `"system"` or the language code.
    public var rawValue: String {
        switch self {
        case .system: return "system"
        case .specific(let code): return code
        }
    }

    /// `nil` for codes `SupportedLanguages` doesn't list.
    public init?(rawValue: String) {
        if rawValue == "system" {
            self = .system
        } else if SupportedLanguages.language(withCode: rawValue) != nil {
            self = .specific(rawValue)
        } else {
            return nil
        }
    }
}

extension AppLanguage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let language = AppLanguage(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown language \(rawValue)")
        }
        self = language
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Puts the picked language into effect through `AppleLanguages` in the process's own defaults
/// domain — the per-app language macOS itself offers (System Settings → General → Language & Region
/// → Applications). Bundles read it when they first look up a string, so it's applied first thing
/// at launch and a change shows after a restart.
public enum LanguageOverride {
    static let appleLanguagesKey = "AppleLanguages"
    /// The code this app last wrote to `AppleLanguages`, so "System" removes only its own value and
    /// leaves one set in System Settings alone.
    static let appliedLanguageKey = "DockGroupsAppliedLanguage"

    /// What a picked language puts in `AppleLanguages`: the language, then English for keys its
    /// table lacks.
    public static func preferredLanguages(for code: String) -> [String] {
        code == "en" ? ["en"] : [code, "en"]
    }

    /// Writes (or, for `.system`, removes) the override in `defaults`. Returns whether anything
    /// changed.
    @discardableResult
    public static func apply(_ language: AppLanguage, to defaults: UserDefaults) -> Bool {
        let applied = defaults.string(forKey: appliedLanguageKey)
        let current = defaults.stringArray(forKey: appleLanguagesKey)
        switch language {
        case .specific(let code):
            let languages = preferredLanguages(for: code)
            guard applied != code || current != languages else { return false }
            defaults.set(languages, forKey: appleLanguagesKey)
            defaults.set(code, forKey: appliedLanguageKey)
            return true
        case .system:
            guard let applied else { return false }
            // Changed since (in System Settings): no longer ours to remove.
            if current == preferredLanguages(for: applied) {
                defaults.removeObject(forKey: appleLanguagesKey)
            }
            defaults.removeObject(forKey: appliedLanguageKey)
            return true
        }
    }
}
