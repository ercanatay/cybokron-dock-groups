import Foundation

// Launch actions, slice 4 (the group window): docs/design/launch-action-ui-slice.md.
//
// What the group window needs to show an item's launch action, let the user set one and turn an
// imported one on: names, the action's status, the row's caption and the confirmation's summary.
// Nothing here opens anything; an action only ever runs through the launcher and its runner, which
// check everything again.

extension BrowserFamily {
    /// The browser's short name, for menus and rows: "Chrome". A brand name, not localized.
    public var name: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        }
    }

    /// The browser app's full name, for the confirmation: "Google Chrome".
    public var applicationName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave Browser"
        case .firefox: return "Firefox"
        }
    }

    /// The bundle identifier the template starts when the item has no browser chosen for it (the
    /// release channel), and the one whose installation and running state the window checks.
    public var bundleIdentifier: String { bundleIdentifiers[0] }

    /// What an empty profile field shows as an example: a Chromium profile directory ("Profile 1")
    /// or a Firefox profile name ("default-release"). Not localized: the browsers write them so.
    public var profileNameExample: String {
        self == .firefox ? "default-release" : "Profile 1"
    }
}

extension LaunchAction {
    /// The browser the action opens the website in; `nil` for a shortcut, which opens none.
    public var browser: BrowserFamily? {
        switch self {
        case .browserProfile(let browser, _), .browserPrivate(let browser): return browser
        case .shortcut: return nil
        }
    }

    /// The profile the action opens the website in, as the user typed it; `nil` for a private
    /// window, which has none.
    public var profileName: String? {
        switch self {
        case .browserProfile(_, let profileName): return profileName
        case .browserPrivate, .shortcut: return nil
        }
    }

    /// The shortcut the action runs, as the user typed it; `nil` for the browser templates.
    public var shortcutName: String? {
        if case .shortcut(let name) = self { return name }
        return nil
    }

    /// Whether the action opens the website in a private window (`browserPrivate`).
    public var isPrivateWindow: Bool {
        if case .browserPrivate = self { return true }
        return false
    }

    /// Whether `profileName` passes the profile-name grammar (`BrowserProfileName`): the editor
    /// can't save a browser profile whose name doesn't.
    public static func isAcceptedProfileName(_ profileName: String) -> Bool {
        BrowserProfileName.rejection(for: profileName) == nil
    }

    /// Whether `name` passes the shortcut-name grammar (`ShortcutName`): the editor can't save a
    /// shortcut whose name doesn't. Checked as typed only: whether Shortcuts has a shortcut of
    /// that name isn't asked (docs/design/launch-action-shortcut.md, Q4).
    public static func isAcceptedShortcutName(_ name: String) -> Bool {
        ShortcutName.rejection(for: name) == nil
    }
}

extension AppReference {
    /// Whether the item is the Shortcuts app's, the only one a shortcut action can be set on
    /// (`LaunchAction.isAllowed(for:identity:)`).
    public var isShortcutsApplication: Bool {
        kind == .application && bundleIdentifier.lowercased() == LaunchAction.shortcutsBundleIdentifier
    }
}

/// An item's launch action as the group window shows it (`AppReference.launchActionStatus`).
public enum LaunchActionStatus: Hashable, Sendable {
    /// Valid for the item and on: the item opens with it.
    case enabled(LaunchAction)
    /// It came in with a backup or a template from one, so it's off until the user turns it on;
    /// the item isn't opened at all meanwhile.
    case imported(LaunchAction)
    /// It couldn't be read or isn't valid for the item; the item isn't opened at all until a new
    /// one is set. Why isn't shown: the reason holds nothing the user could act on but "set it
    /// again".
    case invalid

    /// Whether the user must review it before the item opens again.
    public var needsReview: Bool {
        if case .enabled = self { return false }
        return true
    }
}

extension AppReference {
    /// The item's launch action as the window shows it; `nil` without one.
    public var launchActionStatus: LaunchActionStatus? {
        switch launchActionSetting {
        case nil: return nil
        case .enabled: return launchAction.map(LaunchActionStatus.enabled) ?? .invalid
        case .needsReview(.imported(let action)): return .imported(action)
        case .needsReview(.invalid): return .invalid
        }
    }

    /// The bundle identifier of the browser the launcher would start for the item's launch action:
    /// its Open With app when it has one, otherwise the template's own, as the launcher picks it.
    /// `nil` without an action that's on, and for one that opens no browser (a shortcut).
    public var launchActionBrowserBundleIdentifier: String? {
        guard let browser = launchAction?.browser else { return nil }
        return launch.opener?.bundleIdentifier ?? browser.bundleIdentifier
    }
}

/// What closing the details editor does to the item's launch action
/// (`ItemDetailsDraft.launchActionToSave(endingWith:)`); `nil` there keeps it as it is.
public enum LaunchActionEdit: Hashable, Sendable {
    /// The item no longer has a launch action.
    case remove
    /// The action, confirmed by the user, is set and on (`LaunchActionSetting.enabled`).
    case enable(LaunchAction)
}

/// What the confirmation before an action is turned on shows: which item, which browser (its app's
/// name and bundle identifier), which profile or that it's a private window, and the full address
/// that will open; or, for a shortcut, its name and what running it means.
public struct LaunchActionSummary: Equatable, Sendable {
    /// The action asked about: Turn On sets it only when it's still the one chosen.
    public let action: LaunchAction
    public let itemName: String
    /// `nil` for a shortcut, which opens no browser.
    public let browser: BrowserFamily?
    /// `nil` for a private window and a shortcut.
    public let profileName: String?
    /// The website's whole address, as it will open; `nil` for a shortcut.
    public let address: String?
    /// The shortcut's name, as stored and as the approval binds it; `nil` for a browser template.
    public let shortcutName: String?

    /// The summary of `action` set on `item`; `nil` when the action can't be set on it: a browser
    /// template on anything but a website, a shortcut on anything but the Shortcuts app's item.
    public init?(_ action: LaunchAction, for item: GroupItem) {
        guard action.isAllowed(for: item.kind, identity: item.bundleIdentifier) else { return nil }
        self.action = action
        itemName = item.displayName
        profileName = action.profileName
        if let name = action.shortcutName {
            browser = nil
            address = nil
            shortcutName = name
        } else {
            guard let url = item.websiteURL, let browser = action.browser else { return nil }
            self.browser = browser
            address = url.absoluteString
            shortcutName = nil
        }
    }

    /// The question: "Open “GitHub” in Chrome with the profile “Work”?", for a private window
    /// "Open “GitHub” in a private Chrome window?", for a shortcut "Run the shortcut “Work Setup”
    /// when you open this item?"
    public var title: String {
        if let shortcutName {
            return Localization.format("item.launch.shortcut.confirm.title", "Run the shortcut “%@” when you open this item?", shortcutName)
        }
        let browserName = browser?.name ?? ""
        guard let profileName else {
            return Localization.format("item.launch.private.confirm.title", "Open “%1$@” in a private %2$@ window?", itemName, browserName)
        }
        return Localization.format(
            "item.launch.profile.confirm.title", "Open “%1$@” in %2$@ with the profile “%3$@”?",
            itemName, browserName, profileName
        )
    }

    /// The rest: for a browser template, not localized, the full address, then the browser app
    /// with its bundle identifier; for a shortcut, its name as stored, then what running it means
    /// (it does whatever the shortcut does; the app passes it nothing).
    public var details: String {
        if let shortcutName {
            let warning = Localization.string(
                "item.launch.shortcut.confirm.message",
                "It does whatever this shortcut does, with the permissions you gave Shortcuts. The app passes it nothing: no input, no text, no files. If you rename it, or another shortcut gets this name, that one runs."
            )
            return "\(shortcutName)\n\(warning)"
        }
        guard let browser else { return address ?? "" }
        return "\(address ?? "")\n\(browser.applicationName) (\(browser.bundleIdentifier))"
    }
}

/// The lines an item's row shows about its launch action: "Chrome · Work" (or "Chrome · private
/// window", or "Run a Shortcut: Work Setup"), and while that browser
/// is running, that the item won't open until it's quit (the runner refuses a running browser:
/// launch-action-runner-slice.md); or that the action needs review.
public struct LaunchActionCaption: Equatable, Sendable {
    /// "Chrome · Work", "Chrome · private window", "Run a Shortcut: Work Setup", or "Needs review…".
    public let text: String
    /// While the browser is running: "Chrome is running: …"; `nil` otherwise.
    public let note: String?
    /// The action is off until reviewed, so the item isn't opened at all.
    public let needsReview: Bool

    /// The caption of `item`; `nil` when it has no launch action.
    /// - Parameter isApplicationRunning: Whether the app with this bundle identifier runs now.
    /// - Parameter isApprovalMissing: Whether this Mac has no approval for the action that's on
    ///   (`GroupStore.isApprovalMissing(for:)`): the launcher refuses it, so the row says so.
    public init?(item: GroupItem, isApprovalMissing: Bool = false, isApplicationRunning: (String) -> Bool) {
        guard let status = item.launchActionStatus else { return nil }
        switch status {
        case .enabled where isApprovalMissing:
            text = Localization.string("item.launch.profile.approval.row", "Approval missing on this Mac: the item won't open until you turn it on again.")
            needsReview = true
            note = nil
        case .enabled(let action):
            guard let browser = action.browser else {
                // A shortcut: what it runs, by name.
                let shortcutName = action.shortcutName ?? ""
                text = Localization.format("item.launch.shortcut.row", "Run a Shortcut: %@", shortcutName)
                needsReview = false
                note = nil
                return
            }
            text = action.profileName.map { "\(browser.name) · \($0)" }
                ?? Localization.format("item.launch.private.row", "%@ · private window", browser.name)
            needsReview = false
            let running = item.launchActionBrowserBundleIdentifier.map(isApplicationRunning) ?? false
            note = running
                ? Localization.format("item.launch.profile.row.running", "%@ is running: the item opens only after you quit it.", browser.name)
                : nil
        case .imported, .invalid:
            // The Shortcuts app's item can only have a shortcut; any other item only a browser
            // template, so the item says which one needs review, even when it couldn't be read.
            text = item.isShortcutsApplication
                ? Localization.string("item.launch.shortcut.row.review", "Shortcut needs review: the item won't open until you turn it on.")
                : Localization.string("item.launch.profile.row.review", "Browser profile needs review: the item won't open until you turn it on.")
            needsReview = true
            note = nil
        }
    }
}
