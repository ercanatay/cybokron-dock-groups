import Foundation

// Launch actions (E phase 2, option A): docs/design/launch-actions-threat-model.md and
// docs/design/launch-action-core-slice.md.
//
// This file only models, reads, checks and stores them; it opens nothing. Only the launcher runs an
// enabled action, through `LaunchActionRunner` (docs/design/launch-action-runner-slice.md); the group
// window shows, sets and turns them on (docs/design/launch-action-ui-slice.md). An action under
// review is saved as such (docs/design/launch-action-review-persistence.md).

/// A browser whose profiles a website item can open in. Safari isn't one: there's no known public
/// way to open one of its profiles.
public enum BrowserFamily: String, CaseIterable, Hashable, Sendable {
    case chrome
    case edge
    case brave
    case firefox
}

/// What an item does when it opens, chosen from templates shipped with the app. A template is
/// fixed behaviour with typed, checked parameters: no case holds a command, script, program,
/// location, environment or raw argument, so data from a file can only select shipped behaviour.
public enum LaunchAction: Hashable, Sendable {
    /// Opens the website in `browser`, in its profile named `profileName`.
    case browserProfile(browser: BrowserFamily, profileName: String)
    /// Opens the website in a new private window of `browser` (Chrome and Brave: incognito, Edge:
    /// InPrivate, Firefox: private browsing): docs/design/launch-action-private-window.md. It has
    /// no parameter but the browser: no profile, no address of its own.
    case browserPrivate(browser: BrowserFamily)

    /// Why the action can't be used; `nil` when it can. A case can be built with any parameter,
    /// so every boundary (reading, writing, using) asks this again.
    var rejection: LaunchActionRejection? {
        switch self {
        case .browserProfile(_, let profileName):
            return BrowserProfileName.rejection(for: profileName).map(LaunchActionRejection.profileName)
        case .browserPrivate:
            return nil
        }
    }

    /// The item kinds the action can be set on: a browser profile and a private window are for
    /// websites only.
    func isAllowed(for kind: AppReference.Kind) -> Bool {
        switch self {
        case .browserProfile, .browserPrivate: return kind == .website
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
    /// The object has a key this version doesn't know, or one its template doesn't have (a
    /// `profile` for a private window).
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
    /// A `status` this version doesn't know, or `"review"` without a known `reason` (maybe written by
    /// a newer version).
    case unknownStatus
    /// The file says the action was refused before (`"status": "review", "reason": "invalid"`): it
    /// stays refused, whatever its other keys hold, until a new one is set.
    case markedInvalid
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

/// An item's launch action as kept in memory and in the file.
enum LaunchActionSetting: Hashable, Sendable {
    /// A valid action for the item: the only kind the launcher runs. Written with
    /// `"status": "enabled"`.
    case enabled(LaunchAction)
    /// An action that can't be used until the user reviews it. Written with `"status": "review"`
    /// and its reason, so it stays off after a restart (launch-action-review-persistence.md).
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

    /// The action as it was read from a file for an item of `kind`: one the file has under review
    /// as imported stays so, and only one the file has on (or saved before statuses) can be enabled.
    init(reading content: LaunchActionCoding.Content, for kind: AppReference.Kind) {
        switch content {
        case .enabled(let action): self.init(action, for: kind)
        case .imported(let action): self = LaunchActionSetting(action, for: kind).disabledForImport
        case .invalid(let rejection): self = .needsReview(.invalid(rejection))
        }
    }

    /// The action in use for an item of `kind`, checked again; `nil` when it needs review.
    func enabledAction(for kind: AppReference.Kind) -> LaunchAction? {
        guard case .enabled(let action) = self, action.rejection == nil, action.isAllowed(for: kind) else { return nil }
        return action
    }

    /// The setting as it comes in from a file someone may have handed over (a backup or its
    /// templates): an enabled action is turned off until reviewed, and written so.
    var disabledForImport: LaunchActionSetting {
        guard case .enabled(let action) = self else { return self }
        return .needsReview(.imported(action))
    }

    /// Whether it needs review because it was refused.
    var isInvalid: Bool {
        if case .needsReview(.invalid) = self { return true }
        return false
    }
}

/// An item's launch action together with what its object in the file held besides: the keys of
/// a refused action, written back as they were read so a newer version's data isn't lost. Never a
/// forbidden key (`LaunchActionCoding.forbiddenKeys`), `status` or `reason`.
struct StoredLaunchAction: Hashable, Sendable {
    let setting: LaunchActionSetting
    /// Kept only while the setting is refused (`LaunchActionSetting.isInvalid`); empty otherwise.
    let keptFields: [String: JSONValue]

    init(_ setting: LaunchActionSetting, keptFields: [String: JSONValue] = [:]) {
        self.setting = setting
        self.keptFields = setting.isInvalid ? keptFields.filter { !LaunchActionCoding.isForbidden($0.key) } : [:]
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
    /// The item's launch action (`nil`: none). Setting it keeps the kept fields of a refused action
    /// only while it stays refused (`StoredLaunchAction`).
    var launchActionSetting: LaunchActionSetting? {
        get { storedLaunchAction?.setting }
        set { storedLaunchAction = newValue.map { StoredLaunchAction($0, keptFields: storedLaunchAction?.keptFields ?? [:]) } }
    }

    /// The item's launch action in use: valid, for its kind, not waiting for review. Only the
    /// launcher opens the item with it.
    var launchAction: LaunchAction? {
        launchActionSetting?.enabledAction(for: kind)
    }

    /// Whether the item has a launch action that can't be used until the user reviews it.
    var launchActionNeedsReview: Bool {
        if case .needsReview = launchActionSetting { return true }
        return false
    }

    /// Sets the item's launch action (`nil` removes it); one that isn't valid for the item is kept
    /// and written as needing review, without its refused values.
    mutating func setLaunchAction(_ action: LaunchAction?) {
        launchActionSetting = action.map { LaunchActionSetting($0, for: kind) }
    }
}

// MARK: - On-disk form

/// The `launchAction` object of an item: a `status`, and the template's own keys, e.g.
/// `{"status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Work"}` or
/// `{"status": "enabled", "template": "browserPrivate", "browser": "firefox"}` (no `profile`).
///
/// - `"status": "enabled"` — on, so the launcher may run it.
/// - `"status": "review", "reason": "imported"` — came in with a backup: off until turned on.
/// - `"status": "review", "reason": "invalid"` — refused: never run; the object's other keys are
///   written back as they were read (`fields`), forbidden ones excepted.
/// - no `status` — written before statuses: read as `"enabled"`, so a valid action stays on.
///
/// Read strictly: any other `status` or `reason`, any other key, a wrong type or a missing
/// parameter makes the action invalid; nothing is defaulted. Always written with a `status`.
struct LaunchActionCoding: Codable {
    static let statusKey = "status"
    static let reasonKey = "reason"
    static let templateKey = "template"
    static let browserKey = "browser"
    static let profileKey = "profile"
    static let enabledStatus = "enabled"
    static let reviewStatus = "review"
    static let importedReason = "imported"
    static let invalidReason = "invalid"
    /// The templates' keys (`browserPrivate` has no `profile`).
    static let allowedKeys: Set<String> = [templateKey, browserKey, profileKey]
    /// Keys that are never read, kept or written, compared ignoring case. Any of them makes the
    /// action invalid (they'd be unknown anyway; listed so they're refused by name).
    static let forbiddenKeys: Set<String> = [
        "environment", "env", "command", "script", "executable", "shell", "args", "argv", "arguments", "path",
    ]
    /// The template identifier of `LaunchAction.browserProfile`.
    static let browserProfileTemplate = "browserProfile"
    /// The template identifier of `LaunchAction.browserPrivate`.
    static let browserPrivateTemplate = "browserPrivate"

    static func isForbidden(_ key: String) -> Bool {
        forbiddenKeys.contains(key.lowercased())
    }

    /// What an object says, before the item's kind is considered.
    enum Content: Hashable, Sendable {
        case enabled(LaunchAction)
        case imported(LaunchAction)
        case invalid(LaunchActionRejection)
    }

    /// What was read, or is to be written.
    let content: Content
    /// The object's keys but `status`, `reason` and forbidden ones, as read; written back with an
    /// invalid action. Empty for a value that isn't an object.
    let fields: [String: JSONValue]

    /// An enabled action, to write.
    init(_ action: LaunchAction) {
        content = .enabled(action)
        fields = [:]
    }

    /// `stored` as an item of `kind` writes it: on, or imported, only while valid and allowed for
    /// the kind; anything else as invalid, with only the kept fields of an action that was read
    /// refused (never a refused value built in memory).
    init(_ stored: StoredLaunchAction, for kind: AppReference.Kind) {
        switch stored.setting {
        case .enabled(let action) where action.rejection == nil && action.isAllowed(for: kind):
            content = .enabled(action)
            fields = [:]
        case .needsReview(.imported(let action)) where action.rejection == nil && action.isAllowed(for: kind):
            content = .imported(action)
            fields = [:]
        case .needsReview(.invalid(let rejection)):
            content = .invalid(rejection)
            fields = stored.keptFields
        case .enabled(let action), .needsReview(.imported(let action)):
            content = .invalid(action.rejection ?? .unsupportedItemKind)
            fields = [:]
        }
    }

    /// Never throws: a value that can't be read is an invalid action, not an unreadable item.
    init(from decoder: Decoder) {
        guard case .object(let object)? = try? JSONValue(from: decoder) else {
            content = .invalid(.notAnObject)
            fields = [:]
            return
        }
        content = Self.read(object)
        fields = object.filter { $0.key != Self.statusKey && $0.key != Self.reasonKey && !Self.isForbidden($0.key) }
    }

    /// An object that couldn't be decoded at all.
    static let unreadable = LaunchActionCoding(content: .invalid(.notAnObject), fields: [:])

    private init(content: Content, fields: [String: JSONValue]) {
        self.content = content
        self.fields = fields
    }

    private static func read(_ object: [String: JSONValue]) -> Content {
        if object.keys.contains(where: isForbidden) { return .invalid(.forbiddenKey) }
        var keys = allowedKeys
        var imported = false
        switch string(object, statusKey) {
        case .success(nil):
            break
        case .success(enabledStatus?):
            keys.insert(statusKey)
        case .success(reviewStatus?):
            keys.formUnion([statusKey, reasonKey])
            switch string(object, reasonKey) {
            case .success(importedReason?): imported = true
            case .success(invalidReason?): return .invalid(.markedInvalid)
            case .success: return .invalid(.unknownStatus)
            case .failure(let rejection): return .invalid(rejection)
            }
        case .success: return .invalid(.unknownStatus)
        case .failure(let rejection): return .invalid(rejection)
        }
        if object.keys.contains(where: { !keys.contains($0) }) { return .invalid(.unknownKey) }
        switch action(object) {
        case .success(let action): return imported ? .imported(action) : .enabled(action)
        case .failure(let rejection): return .invalid(rejection)
        }
    }

    /// The template and its parameters.
    private static func action(_ object: [String: JSONValue]) -> Result<LaunchAction, LaunchActionRejection> {
        let template: String
        switch string(object, templateKey) {
        case .success(let value?): template = value
        case .success(nil): return .failure(.missingTemplate)
        case .failure(let rejection): return .failure(rejection)
        }
        guard template == browserProfileTemplate || template == browserPrivateTemplate else { return .failure(.unknownTemplate) }
        // A private window has no profile: one written with it is refused, never ignored.
        if template == browserPrivateTemplate, object[profileKey] != nil { return .failure(.unknownKey) }
        let browser: BrowserFamily
        switch string(object, browserKey) {
        case .success(let value?):
            guard let family = BrowserFamily(rawValue: value) else { return .failure(.unknownBrowser) }
            browser = family
        case .success(nil): return .failure(.missingBrowser)
        case .failure(let rejection): return .failure(rejection)
        }
        if template == browserPrivateTemplate { return .success(.browserPrivate(browser: browser)) }
        switch string(object, profileKey) {
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
    private static func string(_ object: [String: JSONValue], _ key: String) -> Result<String?, LaunchActionRejection> {
        guard let value = object[key] else { return .success(nil) }
        guard let string = value.stringValue else { return .failure(.wrongValueType) }
        return .success(string)
    }

    /// Always with a `status`. An enabled or imported action only when it's valid, with only its
    /// own keys; an invalid one with its kept fields, forbidden keys never.
    func encode(to encoder: Encoder) throws {
        var object: [String: JSONValue]
        switch content {
        case .enabled(let action), .imported(let action):
            guard action.rejection == nil else {
                throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Not a valid launch action"))
            }
            switch action {
            case .browserProfile(let browser, let profileName):
                object = [
                    Self.templateKey: .string(Self.browserProfileTemplate),
                    Self.browserKey: .string(browser.rawValue),
                    Self.profileKey: .string(profileName),
                ]
            case .browserPrivate(let browser):
                object = [
                    Self.templateKey: .string(Self.browserPrivateTemplate),
                    Self.browserKey: .string(browser.rawValue),
                ]
            }
            if case .imported = content {
                object[Self.statusKey] = .string(Self.reviewStatus)
                object[Self.reasonKey] = .string(Self.importedReason)
            } else {
                object[Self.statusKey] = .string(Self.enabledStatus)
            }
        case .invalid:
            object = fields.filter { !Self.isForbidden($0.key) }
            object[Self.statusKey] = .string(Self.reviewStatus)
            object[Self.reasonKey] = .string(Self.invalidReason)
        }
        try JSONValue.object(object).encode(to: encoder)
    }
}
