import Foundation

/// Who asked to open a group's items (docs/design/launch-action-runner-slice.md).
///
/// An item with a launch action opens only when the user opened it themselves, in the app's own
/// windows and menus (`userAction`). From every other source such an item isn't opened at all and
/// is reported with a fixed reason; items without a launch action open the same way from every
/// source. A caller that doesn't say (`unspecified`) counts as unattended.
public enum LaunchSource: String, Sendable, CaseIterable {
    /// A click in the popup, the group window or the menu bar menu, Most Used among them.
    case userAction
    /// A group's own keyboard shortcut: pressed by the user, but maybe by accident, and it doesn't
    /// show what it does.
    case keyboardShortcut
    /// A `cybokrondockgroups://` link, which any app, script or web page can open. The command-line
    /// tool only opens such links, so it comes in as a link too.
    case link
    /// Siri or the Shortcuts app.
    case intent
    /// A Focus that turned on or off.
    case focus
    /// A trigger: a time, a login, a display, a network, an app opening.
    case trigger
    /// A standalone group's own app.
    case standaloneAgent
    /// A caller that didn't say where the request came from.
    case unspecified

    /// The source of a Start (`ContextSwitcher`) that `trigger` asked for.
    public init(_ trigger: TransitionTrigger) {
        switch trigger {
        case .userAction: self = .userAction
        case .shortcut: self = .keyboardShortcut
        case .link: self = .link
        case .intent: self = .intent
        case .focus: self = .focus
        case .automation: self = .trigger
        }
    }

    /// Whether the user opened the items themselves in the app; only then can an item's launch
    /// action run.
    public var isUserPresent: Bool { self == .userAction }
}
