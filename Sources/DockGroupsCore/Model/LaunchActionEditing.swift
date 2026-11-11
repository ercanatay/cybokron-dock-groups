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
    /// The browser the action opens the website in.
    public var browser: BrowserFamily {
        switch self {
        case .browserProfile(let browser, _): return browser
        }
    }

    /// The profile the action opens the website in, as the user typed it.
    public var profileName: String {
        switch self {
        case .browserProfile(_, let profileName): return profileName
        }
    }

    /// Whether `profileName` passes the profile-name grammar (`BrowserProfileName`): the editor
    /// can't save a browser profile whose name doesn't.
    public static func isAcceptedProfileName(_ profileName: String) -> Bool {
        BrowserProfileName.rejection(for: profileName) == nil
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
    /// `nil` without an action that's on.
    public var launchActionBrowserBundleIdentifier: String? {
        guard let action = launchAction else { return nil }
        return launch.opener?.bundleIdentifier ?? action.browser.bundleIdentifier
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
/// name and bundle identifier), which profile and the full address that will open.
public struct LaunchActionSummary: Equatable, Sendable {
    public let itemName: String
    public let browser: BrowserFamily
    public let profileName: String
    /// The website's whole address, as it will open.
    public let address: String

    /// The summary of `action` set on `item`; `nil` when the item isn't a website.
    public init?(_ action: LaunchAction, for item: GroupItem) {
        guard item.isWebsite, let url = item.websiteURL else { return nil }
        itemName = item.displayName
        browser = action.browser
        profileName = action.profileName
        address = url.absoluteString
    }

    /// The question: "Open “GitHub” in Chrome with the profile “Work”?"
    public var title: String {
        Localization.format(
            "item.launch.profile.confirm.title", "Open “%1$@” in %2$@ with the profile “%3$@”?",
            itemName, browser.name, profileName
        )
    }

    /// The rest, not localized: the full address, then the browser app with its bundle identifier.
    public var details: String {
        "\(address)\n\(browser.applicationName) (\(browser.bundleIdentifier))"
    }
}

/// The lines an item's row shows about its launch action: "Chrome · Work", and while that browser
/// is running, that the item won't open until it's quit (the runner refuses a running browser:
/// launch-action-runner-slice.md); or that the action needs review.
public struct LaunchActionCaption: Equatable, Sendable {
    /// "Chrome · Work", or "Needs review…".
    public let text: String
    /// While the browser is running: "Chrome is running: …"; `nil` otherwise.
    public let note: String?
    /// The action is off until reviewed, so the item isn't opened at all.
    public let needsReview: Bool

    /// The caption of `item`; `nil` when it has no launch action.
    /// - Parameter isApplicationRunning: Whether the app with this bundle identifier runs now.
    public init?(item: GroupItem, isApplicationRunning: (String) -> Bool) {
        guard let status = item.launchActionStatus else { return nil }
        switch status {
        case .enabled(let action):
            text = "\(action.browser.name) · \(action.profileName)"
            needsReview = false
            let running = item.launchActionBrowserBundleIdentifier.map(isApplicationRunning) ?? false
            note = running
                ? Localization.format("item.launch.profile.row.running", "%@ is running: the item opens only after you quit it.", action.browser.name)
                : nil
        case .imported, .invalid:
            text = Localization.string("item.launch.profile.row.review", "Browser profile needs review: the item won't open until you turn it on.")
            needsReview = true
            note = nil
        }
    }
}
