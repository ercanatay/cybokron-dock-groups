import Foundation

/// One way to control a group from outside the app: a phrase to ask Siri, or a link.
public struct GroupInvocation: Hashable, Sendable, Identifiable {
    /// What it does, e.g. "Launch Group" or "Open All".
    public let title: String
    /// The phrase or the link, ready to copy.
    public let text: String

    public var id: String { text }

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// The Siri phrases and links of one group, spelled out with its name, as Settings lists them to
/// copy.
public enum GroupInvocations {
    /// What to ask Siri for the group: the first phrase of each of the app's App Shortcuts with
    /// the group's name, titled like the actions in the Shortcuts app. The App Shortcuts phrases
    /// (`DockGroupsShortcuts`) must be literals and can't share these strings: keep both in step.
    public static func siriPhrases(groupName: String, appName: String) -> [GroupInvocation] {
        [
            GroupInvocation(title: "Show Group", text: "Show \(groupName) in \(appName)"),
            GroupInvocation(title: "Launch Group", text: "Launch \(groupName) in \(appName)"),
            GroupInvocation(title: "Quit Group", text: "Quit \(groupName) in \(appName)"),
        ]
    }

    /// The URL scheme's links for `group` (see `URLCommand`): show its popup, Open All, Hide All
    /// and Close All.
    /// - Parameter groups: All groups, in order: a name another group answers to first isn't used.
    public static func links(for group: DockGroup, in groups: [DockGroup]) -> [GroupInvocation] {
        let token = linkToken(for: group, in: groups)
        let base = "\(URLCommand.scheme)://"
        return [
            GroupInvocation(title: "Show Popup", text: "\(base)open/\(token)"),
            GroupInvocation(title: "Open All", text: "\(base)launch/\(token)"),
            GroupInvocation(title: "Hide All", text: "\(base)hide/\(token)"),
            GroupInvocation(title: "Close All", text: "\(base)quit/\(token)"),
        ]
    }

    /// How the group's links name it: its slug ("calisma-alani") when that finds this very group,
    /// otherwise — a name without letters or digits, or one an earlier group shares — its
    /// identifier.
    public static func linkToken(for group: DockGroup, in groups: [DockGroup]) -> String {
        let slug = GroupLookup.slug(for: group.name)
        guard !slug.isEmpty, GroupLookup.group(matching: slug, in: groups)?.id == group.id else {
            return group.id.uuidString
        }
        return slug
    }
}
