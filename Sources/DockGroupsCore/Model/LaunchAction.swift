import Foundation

// Launch actions (E phase 2, option A): docs/design/launch-actions-threat-model.md and
// docs/design/launch-action-core-slice.md.
//
// This slice only models, reads, checks and stores them. Nothing opens anything with them: no
// launcher, workspace call or process reads a launch action yet, and an item with one opens exactly
// as it does without one.

/// A browser whose profiles a website item can open in. Safari isn't one: there's no known public
/// way to open one of its profiles.
enum BrowserFamily: String, CaseIterable, Hashable, Sendable {
    case chrome
    case edge
    case brave
    case firefox
}

/// What an item does when it opens, chosen from templates shipped with the app. A template is
/// fixed behaviour with typed, checked parameters: no case holds a command, script, program,
/// location, environment or raw argument, so data from a file can only select shipped behaviour.
enum LaunchAction: Hashable, Sendable {
    /// Opens the website in `browser`, in its profile named `profileName`.
    case browserProfile(browser: BrowserFamily, profileName: String)

    /// Why the action can't be used; `nil` when it can. A case can be built with any parameter,
    /// so every boundary (reading, writing, using) asks this again.
    var rejection: LaunchActionRejection? {
        switch self {
        case .browserProfile(_, let profileName):
            return BrowserProfileName.rejection(for: profileName).map(LaunchActionRejection.profileName)
        }
    }

    /// The item kinds the action can be set on: a browser profile is for websites only.
    func isAllowed(for kind: AppReference.Kind) -> Bool {
        switch self {
        case .browserProfile: return kind == .website
        }
    }
}

/// Why a launch action was refused. Holds no text from the file (keys or values), so it can be
/// logged or shown without leaking what was saved.
enum LaunchActionRejection: Error, Hashable, Sendable {
    /// The value isn't a JSON object.
    case notAnObject
    /// The object has a key no template has and that is never read: an environment, a command, a
    /// script, a program, a shell, arguments or a location (`LaunchActionCoding.forbiddenKeys`).
    case forbiddenKey
    /// The object has a key this version doesn't know.
    case unknownKey
    /// A key holds a value of the wrong JSON type.
    case wrongValueType
    case missingTemplate
    /// A template this version doesn't ship (maybe written by a newer one).
    case unknownTemplate
    case missingBrowser
    /// A browser that has no profile template (Safari, or one a newer version added).
    case unknownBrowser
    case missingProfile
    /// The template can't be set on an item of this kind.
    case unsupportedItemKind
    /// The profile name breaks the grammar (`BrowserProfileName`).
    case profileName(BrowserProfileNameRejection)
}

/// Why a profile name was refused (`BrowserProfileName.rejection(for:)`).
enum BrowserProfileNameRejection: Hashable, Sendable, CaseIterable {
    case empty
    /// More than `BrowserProfileName.maximumLength` Unicode scalars.
    case tooLong
    /// A control character: NUL, a line break or a tab among them.
    case controlCharacter
    /// A bidirectional formatting character, which can make the name read differently than it is.
    case bidiCharacter
    /// An invisible or unassigned character: a format character, private use, a lone surrogate,
    /// or a space other than U+0020.
    case invisibleCharacter
    /// It starts like a location: "/", "~" or "file:".
    case looksLikePath
    /// It starts with "-", so an app could take it for an option.
    case leadingHyphen
    /// It starts or ends with a space.
    case surroundingWhitespace
    /// It contains "..".
    case parentReference
    /// It contains a character of `BrowserProfileName.forbiddenCharacters`.
    case forbiddenCharacter
}

/// The grammar of a browser profile name. A name that breaks it is refused, never trimmed,
/// escaped or otherwise fixed.
enum BrowserProfileName {
    /// The longest name accepted, in Unicode scalars.
    static let maximumLength = 64

    /// Characters a name can't contain: path separators and home, shell and quoting
    /// characters, globs, and "=" and ":" (option values and URL schemes).
    static let forbiddenCharacters: Set<Unicode.Scalar> = [
        "/", "\\", "~", "$", "`", ";", "|", "&", ">", "<", "*", "?", "\"", "'", "=", ":",
    ]

    /// Why `name` can't be a profile name; `nil` when it can.
    static func rejection(for name: String) -> BrowserProfileNameRejection? {
        let scalars = name.unicodeScalars
        guard !scalars.isEmpty else { return .empty }
        guard scalars.count <= maximumLength else { return .tooLong }
        for scalar in scalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return .controlCharacter
            default:
                break
            }
        }
        if scalars.contains(where: \.properties.isBidiControl) { return .bidiCharacter }
        for scalar in scalars {
            switch scalar.properties.generalCategory {
            case .format, .privateUse, .surrogate, .unassigned:
                return .invisibleCharacter
            case .spaceSeparator where scalar != " ":
                return .invisibleCharacter
            default:
                break
            }
        }
        if name.hasPrefix("/") || name.hasPrefix("~") || name.lowercased().hasPrefix("file:") { return .looksLikePath }
        if name.hasPrefix("-") { return .leadingHyphen }
        if name.hasPrefix(" ") || name.hasSuffix(" ") { return .surroundingWhitespace }
        if name.contains("..") { return .parentReference }
        if scalars.contains(where: forbiddenCharacters.contains) { return .forbiddenCharacter }
        return nil
    }
}

/// An item's launch action as kept in memory.
enum LaunchActionSetting: Hashable, Sendable {
    /// A valid action for the item. Written to the file; not executed by this version.
    case enabled(LaunchAction)
    /// An action that can't be used until the user reviews it. Never written to a file.
    case needsReview(LaunchActionReview)

    /// `action` as an item of `kind` keeps it: enabled when it's valid and allowed for the kind,
    /// otherwise needing review.
    init(_ action: LaunchAction, for kind: AppReference.Kind) {
        if let rejection = action.rejection {
            self = .needsReview(.invalid(rejection))
        } else if !action.isAllowed(for: kind) {
            self = .needsReview(.invalid(.unsupportedItemKind))
        } else {
            self = .enabled(action)
        }
    }

    /// The action as it was read from a file for an item of `kind`.
    init(reading result: Result<LaunchAction, LaunchActionRejection>, for kind: AppReference.Kind) {
        switch result {
        case .success(let action): self.init(action, for: kind)
        case .failure(let rejection): self = .needsReview(.invalid(rejection))
        }
    }

    /// The action in use for an item of `kind`, checked again; `nil` when it needs review.
    func enabledAction(for kind: AppReference.Kind) -> LaunchAction? {
        guard case .enabled(let action) = self, action.rejection == nil, action.isAllowed(for: kind) else { return nil }
        return action
    }

    /// The setting as it comes in from a file someone may have handed over (a backup or its
    /// templates): an enabled action is turned off until reviewed, and isn't written again.
    var disabledForImport: LaunchActionSetting {
        guard case .enabled(let action) = self else { return self }
        return .needsReview(.imported(action))
    }
}

/// Why an item's launch action needs review.
enum LaunchActionReview: Hashable, Sendable {
    /// It was refused when it was read or set.
    case invalid(LaunchActionRejection)
    /// It came in with a backup, so it's off until the user turns it on.
    case imported(LaunchAction)
}

extension AppReference {
    /// The item's launch action in use: valid, for its kind, not waiting for review. Nothing opens
    /// the item with it yet.
    var launchAction: LaunchAction? {
        launchActionSetting?.enabledAction(for: kind)
    }

    /// Whether the item has a launch action that can't be used until the user reviews it.
    var launchActionNeedsReview: Bool {
        if case .needsReview = launchActionSetting { return true }
        return false
    }

    /// Sets the item's launch action (`nil` removes it); one that isn't valid for the item is kept
    /// as needing review, and isn't written.
    mutating func setLaunchAction(_ action: LaunchAction?) {
        launchActionSetting = action.map { LaunchActionSetting($0, for: kind) }
    }
}

// MARK: - On-disk form

/// The `launchAction` object of an item: exactly `template`, `browser` and `profile`, e.g.
/// `{"template": "browserProfile", "browser": "chrome", "profile": "Work"}`. Read strictly: any
/// other key, a wrong type or a missing parameter makes the action invalid; nothing is defaulted.
struct LaunchActionCoding: Codable {
    static let templateKey = "template"
    static let browserKey = "browser"
    static let profileKey = "profile"
    /// The keys a launch action can have.
    static let allowedKeys: Set<String> = [templateKey, browserKey, profileKey]
    /// Keys that are never read, kept or written, compared ignoring case. Any of them makes the
    /// action invalid (they'd be unknown anyway; listed so they're refused by name).
    static let forbiddenKeys: Set<String> = [
        "environment", "env", "command", "script", "executable", "shell", "args", "argv", "arguments", "path",
    ]
    /// The template identifier of `LaunchAction.browserProfile`.
    static let browserProfileTemplate = "browserProfile"

    /// What was read.
    let result: Result<LaunchAction, LaunchActionRejection>

    init(_ action: LaunchAction) {
        result = .success(action)
    }

    /// Never throws: a value that can't be read is an invalid action, not an unreadable item.
    init(from decoder: Decoder) {
        result = Self.read(decoder)
    }

    private static func read(_ decoder: Decoder) -> Result<LaunchAction, LaunchActionRejection> {
        guard let container = try? decoder.container(keyedBy: Key.self) else { return .failure(.notAnObject) }
        let keys = container.allKeys.map(\.stringValue)
        if keys.contains(where: { forbiddenKeys.contains($0.lowercased()) }) { return .failure(.forbiddenKey) }
        if keys.contains(where: { !allowedKeys.contains($0) }) { return .failure(.unknownKey) }
        let template: String
        switch string(container, templateKey) {
        case .success(let value?): template = value
        case .success(nil): return .failure(.missingTemplate)
        case .failure(let rejection): return .failure(rejection)
        }
        guard template == browserProfileTemplate else { return .failure(.unknownTemplate) }
        let browser: BrowserFamily
        switch string(container, browserKey) {
        case .success(let value?):
            guard let family = BrowserFamily(rawValue: value) else { return .failure(.unknownBrowser) }
            browser = family
        case .success(nil): return .failure(.missingBrowser)
        case .failure(let rejection): return .failure(rejection)
        }
        switch string(container, profileKey) {
        case .success(let profileName?):
            let action = LaunchAction.browserProfile(browser: browser, profileName: profileName)
            if let rejection = action.rejection { return .failure(rejection) }
            return .success(action)
        case .success(nil): return .failure(.missingProfile)
        case .failure(let rejection): return .failure(rejection)
        }
    }

    /// The string at `key`; `nil` when it's missing, a failure when it's of another type (`null`
    /// included).
    private static func string(_ container: KeyedDecodingContainer<Key>, _ key: String) -> Result<String?, LaunchActionRejection> {
        let codingKey = Key(stringValue: key)
        guard container.contains(codingKey) else { return .success(nil) }
        guard let value = try? container.decode(String.self, forKey: codingKey) else { return .failure(.wrongValueType) }
        return .success(value)
    }

    /// Writes only a valid action, with only its own keys.
    func encode(to encoder: Encoder) throws {
        guard case .success(let action) = result, action.rejection == nil else {
            throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Not a valid launch action"))
        }
        var container = encoder.container(keyedBy: Key.self)
        switch action {
        case .browserProfile(let browser, let profileName):
            try container.encode(Self.browserProfileTemplate, forKey: Key(stringValue: Self.templateKey))
            try container.encode(browser.rawValue, forKey: Key(stringValue: Self.browserKey))
            try container.encode(profileName, forKey: Key(stringValue: Self.profileKey))
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
