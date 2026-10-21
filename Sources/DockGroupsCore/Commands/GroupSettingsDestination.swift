import Foundation

/// Where a Group Settings request — the popup's gear, a group's "Group Settings…" menu item, or a
/// `cybokrondockgroups://settings/group/<group>` link — takes the group window: the settings of the
/// group it names, or, when no group matches, the window as it was.
public enum GroupSettingsDestination: Equatable, Sendable {
    /// The named group: the window selects it.
    case group(DockGroup.ID)
    /// No group matches the request: the window opens on the group it showed before, or on the
    /// first group when that one is gone; `nil` without groups.
    case unmatched(keeping: DockGroup.ID?)

    /// The destination of a request naming `token` (an identifier or a name, read as
    /// `GroupLookup` does) while the window shows `current`.
    public init(request token: String, current: DockGroup.ID?, in groups: [DockGroup]) {
        if let group = GroupLookup.group(matching: token, in: groups) {
            self = .group(group.id)
        } else if let current, groups.contains(where: { $0.id == current }) {
            self = .unmatched(keeping: current)
        } else {
            self = .unmatched(keeping: groups.first?.id)
        }
    }

    /// The group the window selects.
    public var selection: DockGroup.ID? {
        switch self {
        case .group(let id): return id
        case .unmatched(let id): return id
        }
    }
}
