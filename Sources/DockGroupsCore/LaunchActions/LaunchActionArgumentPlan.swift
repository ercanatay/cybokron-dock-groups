import Foundation

// Launch actions, slice 3, the computing part: docs/design/launch-action-argv-slice.md.
//
// Turns a website item's launch action into what its browser would be started with: which browser,
// which arguments, which address. It only computes. Nothing here starts, opens or looks up an app;
// whether the browser is installed is asked of the caller, and no caller hands a plan to the system
// yet. There is no shell and no environment: each argument is one element, given to the browser as
// it is, and the plan has no field an environment could be put in.

extension BrowserFamily {
    /// The bundle identifiers the template can start for this family, the first one preferred.
    /// Release channels only; beta, developer and nightly builds keep their own profiles and
    /// aren't offered.
    var bundleIdentifiers: [String] {
        switch self {
        case .chrome: return ["com.google.Chrome"]
        case .edge: return ["com.microsoft.edgemac"]
        case .brave: return ["com.brave.Browser"]
        case .firefox: return ["org.mozilla.firefox"]
        }
    }

    /// The family `bundleIdentifier` belongs to, compared ignoring case as bundle identifiers are;
    /// `nil` for any other app (Safari among them).
    static func family(forBundleIdentifier bundleIdentifier: String) -> BrowserFamily? {
        allCases.first { $0.canonicalBundleIdentifier(for: bundleIdentifier) != nil }
    }

    /// `bundleIdentifier` as this family writes it, or `nil` when it isn't one of the family's.
    func canonicalBundleIdentifier(for bundleIdentifier: String) -> String? {
        let lowercased = bundleIdentifier.lowercased()
        return bundleIdentifiers.first { $0.lowercased() == lowercased }
    }
}

/// Why no plan was made for an item's launch action. Fixed reasons that hold nothing from the item
/// or the file, so they can be logged or shown as they are.
enum LaunchActionArgumentRefusal: String, Error, CaseIterable, Hashable, Sendable {
    /// The browser to start isn't one the action's template can start (another family, Safari, any
    /// other app).
    case unsupportedBrowser
    /// The browser isn't on this Mac. No other browser is tried instead.
    case browserNotInstalled
    /// The action can't be set on an item of this kind (a browser profile is for websites only).
    case itemKindMismatch
    /// The action was refused when it was read or set, or fails the checks made again here.
    case actionNeedsReview
    /// The action came in with a backup and is off until the user turns it on.
    case actionDisabled
    /// The address isn't one a website item can open: http or https with a host, no user name or
    /// password.
    case urlRejected
}

/// What a browser would be started with for a website item's launch action. Made only by
/// `make(setting:itemKind:url:browserBundleIdentifier:isInstalled:)`, which checks everything
/// again, so a plan always has an allowed browser, one element per argument and an accepted address.
/// Holds no environment and no shell command; nothing uses a plan yet.
struct LaunchActionArgumentPlan: Hashable, Sendable {
    /// The browser to start, as its template's bundle-identifier set writes it.
    let executableBundleIdentifier: String
    /// The arguments, each one element given to the browser unchanged; never joined into a line.
    let arguments: [String]
    /// The address to open, given to the browser apart from the arguments.
    let url: URL

    private init(executableBundleIdentifier: String, arguments: [String], url: URL) {
        self.executableBundleIdentifier = executableBundleIdentifier
        self.arguments = arguments
        self.url = url
    }

    /// The Chromium switch that picks a profile by its directory, joined with the value in one
    /// element: `--profile-directory=Work`.
    static let chromiumProfileOption = "--profile-directory="
    /// The Firefox option that picks a profile by its name, followed by the name as its own
    /// element: `-P`, `Work`.
    static let firefoxProfileOption = "-P"

    /// The plan for an item of `itemKind` at `url` whose launch action is `setting`, started in the
    /// browser `browserBundleIdentifier`, or why there is none. Checked in this order, the first
    /// failure winning: the setting is enabled, the action fits the item kind, the action and its
    /// profile name pass their grammar again, the address is accepted, the browser is one of the
    /// template's, and last `isInstalled` (asked only when everything else passed) says it's here.
    static func make(
        setting: LaunchActionSetting,
        itemKind: AppReference.Kind,
        url: URL,
        browserBundleIdentifier: String,
        isInstalled: (String) -> Bool
    ) -> Result<LaunchActionArgumentPlan, LaunchActionArgumentRefusal> {
        let action: LaunchAction
        switch setting {
        case .enabled(let enabled): action = enabled
        case .needsReview(.imported): return .failure(.actionDisabled)
        case .needsReview(.invalid(.unsupportedItemKind)): return .failure(.itemKindMismatch)
        case .needsReview(.invalid): return .failure(.actionNeedsReview)
        }
        guard action.isAllowed(for: itemKind) else { return .failure(.itemKindMismatch) }
        guard action.rejection == nil else { return .failure(.actionNeedsReview) }
        switch action {
        case .browserProfile(let browser, let profileName):
            // Checked again here, not only through `action.rejection`: a plan must never carry a
            // name the grammar refuses, whatever the model does.
            guard BrowserProfileName.rejection(for: profileName) == nil,
                  let arguments = profileArguments(browser: browser, profileName: profileName)
            else { return .failure(.actionNeedsReview) }
            guard isAcceptable(url) else { return .failure(.urlRejected) }
            guard let executable = browser.canonicalBundleIdentifier(for: browserBundleIdentifier) else {
                return .failure(.unsupportedBrowser)
            }
            guard isInstalled(executable) else { return .failure(.browserNotInstalled) }
            return .success(LaunchActionArgumentPlan(executableBundleIdentifier: executable, arguments: arguments, url: url))
        }
    }

    /// The plan for `item`'s launch action in the browser `browserBundleIdentifier`; `nil` when the
    /// item has no launch action at all (it opens as before).
    static func make(
        for item: AppReference,
        browserBundleIdentifier: String,
        isInstalled: (String) -> Bool
    ) -> Result<LaunchActionArgumentPlan, LaunchActionArgumentRefusal>? {
        guard let setting = item.launchActionSetting else { return nil }
        guard let url = item.websiteURL else {
            return item.isWebsite ? .failure(.urlRejected) : .failure(.itemKindMismatch)
        }
        return make(setting: setting, itemKind: item.kind, url: url,
                    browserBundleIdentifier: browserBundleIdentifier, isInstalled: isInstalled)
    }

    /// The arguments that pick `profileName` in `browser`, or `nil` when the result wouldn't be
    /// exactly the template's shape: the option, and the name as one value that can't be read as
    /// an option.
    static func profileArguments(browser: BrowserFamily, profileName: String) -> [String]? {
        guard isSingleArgumentValue(profileName) else { return nil }
        let arguments: [String]
        switch browser {
        case .chrome, .edge, .brave:
            arguments = [chromiumProfileOption + profileName]
        case .firefox:
            arguments = [firefoxProfileOption, profileName]
        }
        return arguments.allSatisfy(isSingleArgument) ? arguments : nil
    }

    /// Whether `value` can stand as one argument value on its own: not empty, not an option, and
    /// nothing that splits, ends or changes an argument (no NUL, line break or other control
    /// character, no whitespace other than an inner space, no "=").
    static func isSingleArgumentValue(_ value: String) -> Bool {
        guard isSingleArgument(value), !value.hasPrefix("-"), !value.contains("=") else { return false }
        return !value.hasPrefix(" ") && !value.hasSuffix(" ")
    }

    /// Whether `argument` is one non-empty element with no control character or whitespace other
    /// than U+0020.
    static func isSingleArgument(_ argument: String) -> Bool {
        guard !argument.isEmpty else { return false }
        return argument.unicodeScalars.allSatisfy { scalar in
            if scalar == " " { return true }
            if scalar.properties.isWhitespace { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    /// Whether `url` is an address a website item can open (`WebsiteAddress`): http or https, a
    /// host, no user name or password. Nothing else, `mailto:`, `file:` and `javascript:` among
    /// them, is planned.
    static func isAcceptable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), WebsiteAddress.allowedSchemes.contains(scheme),
              url.user == nil, url.password == nil, url.host() != nil
        else { return false }
        return (try? WebsiteAddress.parse(url.absoluteString)) != nil
    }
}
