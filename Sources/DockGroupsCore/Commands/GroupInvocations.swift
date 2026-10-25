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
    /// What to ask Siri for the group: the first phrase of the Show, Launch and Quit Group App
    /// Shortcuts with the group's name, titled like the actions in the Shortcuts app (Start and
    /// Finish Group: `switchingPhrases`). The App Shortcuts phrases
    /// (`DockGroupsShortcuts`) must be literals and can't share these strings: keep both in step,
    /// translations included (a translated phrase here must be the one Siri accepts).
    public static func siriPhrases(groupName: String, appName: String) -> [GroupInvocation] {
        [
            GroupInvocation(
                title: Localization.string("core.invocation.showGroup", "Show Group"),
                text: Localization.format("core.invocation.showGroup.phrase", "Show %1$@ in %2$@", groupName, appName)
            ),
            GroupInvocation(
                title: Localization.string("core.invocation.launchGroup", "Launch Group"),
                text: Localization.format("core.invocation.launchGroup.phrase", "Launch %1$@ in %2$@", groupName, appName)
            ),
            GroupInvocation(
                title: Localization.string("core.invocation.quitGroup", "Quit Group"),
                text: Localization.format("core.invocation.quitGroup.phrase", "Quit %1$@ in %2$@", groupName, appName)
            ),
        ]
    }

    /// What to ask Siri to start or finish the group (`StartGroupIntent`, `FinishGroupIntent`), as
    /// `siriPhrases` does for the other App Shortcuts; Settings lists them after those.
    public static func switchingPhrases(groupName: String, appName: String) -> [GroupInvocation] {
        [
            GroupInvocation(
                title: Localization.string("core.invocation.startGroup", "Start Group"),
                text: Localization.format("core.invocation.startGroup.phrase", "Start %1$@ in %2$@", groupName, appName)
            ),
            GroupInvocation(
                title: Localization.string("core.invocation.finishGroup", "Finish Group"),
                text: Localization.format("core.invocation.finishGroup.phrase", "Finish %1$@ in %2$@", groupName, appName)
            ),
        ]
    }

    /// What to ask Siri to make a group of the open apps (`CaptureOpenAppsIntent`): the first
    /// phrase of its App Shortcut, which names no group. Settings lists it after the group's
    /// phrases; keep both in step, as `siriPhrases`.
    public static func capturePhrase(appName: String) -> GroupInvocation {
        GroupInvocation(
            title: Localization.string("core.invocation.capture.newGroup", "New Group from Open Apps"),
            text: Localization.format("core.invocation.capture.newGroup.phrase", "Capture my open apps in %@", appName)
        )
    }

    /// The links that start and finish `group` (see `SwitchingURLCommand`), named as `links`
    /// names it; Settings lists them after those.
    public static func switchingLinks(for group: DockGroup, in groups: [DockGroup]) -> [GroupInvocation] {
        let token = linkToken(for: group, in: groups)
        let base = "\(URLCommand.scheme)://"
        return [
            GroupInvocation(title: Localization.string("core.invocation.startGroup.link", "Start"), text: "\(base)start/\(token)"),
            GroupInvocation(title: Localization.string("core.invocation.finishGroup.link", "Finish"), text: "\(base)finish/\(token)"),
        ]
    }

    /// The link that shows Add Open Apps for `group` (`URLCommand.captureOpenApps`), named as
    /// `links` names it; Settings lists it after the switching links. The link only shows the
    /// sheet: nothing is added until the user says so.
    public static func captureLink(for group: DockGroup, in groups: [DockGroup]) -> GroupInvocation {
        GroupInvocation(
            title: Localization.string("core.invocation.capture.link", "Add Open Apps"),
            text: "\(URLCommand.scheme)://capture/\(linkToken(for: group, in: groups))"
        )
    }

    /// The URL scheme's links for `group` (see `URLCommand`): show its popup, Open All, Hide All
    /// and Close All.
    /// - Parameter groups: All groups, in order: a name another group answers to first isn't used.
    public static func links(for group: DockGroup, in groups: [DockGroup]) -> [GroupInvocation] {
        let token = linkToken(for: group, in: groups)
        let base = "\(URLCommand.scheme)://"
        return [
            GroupInvocation(title: Localization.string("core.invocation.showPopup", "Show Popup"), text: "\(base)open/\(token)"),
            GroupInvocation(title: Localization.string("core.invocation.openAll", "Open All"), text: "\(base)launch/\(token)"),
            GroupInvocation(title: Localization.string("core.invocation.hideAll", "Hide All"), text: "\(base)hide/\(token)"),
            GroupInvocation(title: Localization.string("core.invocation.closeAll", "Close All"), text: "\(base)quit/\(token)"),
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
