import Foundation

/// A group kept out of sight (spec I-2). It's never in `GroupStore.groups`, so nothing that reads
/// the groups — the popup, the menus, the number and group shortcuts, links, Siri, Focus filters,
/// delayed launches, standalone apps — can open, start, show or register it. Only restoring it
/// (`GroupStore.restoreGroup`) makes it a group again.
///
/// An archived group isn't standalone: its own app and Dock tile go when it's archived, and
/// `restoresStandalone` says to bring them back when it's restored. A version without archives
/// (0.8.0) reads it as an ordinary group, and so never finds a standalone group without its Dock
/// tile, which it would turn off and save, dropping every group's archive mark.
public struct ArchivedGroup: Identifiable, Hashable, Sendable {
    /// The group as it was archived, except that it isn't standalone.
    public let group: DockGroup
    /// When it was archived, in whole seconds; `nil` when the file's date couldn't be read.
    public let archivedAt: Date?
    /// It was standalone when archived: restoring turns Standalone on again.
    public let restoresStandalone: Bool

    public var id: DockGroup.ID { group.id }

    /// A standalone `group` is kept with Standalone off and `restoresStandalone` on.
    public init(group: DockGroup, archivedAt: Date?, restoresStandalone: Bool = false) {
        var group = group
        self.restoresStandalone = restoresStandalone || group.isStandalone
        group.isStandalone = false
        self.group = group
        self.archivedAt = archivedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }

    /// The same archived group holding `group` (cleaned up, as when a backup is read).
    func replacingGroup(_ group: DockGroup) -> ArchivedGroup {
        ArchivedGroup(group: group, archivedAt: archivedAt, restoresStandalone: restoresStandalone)
    }
}

/// What the groups file holds: the active groups in list order, and the archived groups in the
/// order they were archived. No archived group has the identifier of a group before it: one that
/// does is dropped.
public struct StoredGroups: Hashable, Sendable {
    public private(set) var active: [DockGroup]
    public private(set) var archived: [ArchivedGroup]

    public init(active: [DockGroup] = [], archived: [ArchivedGroup] = []) {
        self.active = active
        var seen = Set(active.map(\.id))
        self.archived = archived.filter { seen.insert($0.id).inserted }
    }
}

/// One group of the groups file or a backup: an active group, or an archived one — the group's own
/// keys with `"archived": true`, `archivedAt` and `restoresStandalone` beside them, so a version
/// without archives reads it as an ordinary group instead of dropping it.
enum GroupEntry: Codable {
    case active(DockGroup)
    case archived(ArchivedGroup)

    init(from decoder: Decoder) throws {
        let group = try DockGroup(from: decoder)
        let marks = DockGroup.ArchiveMarks(from: decoder)
        guard marks.archived else {
            self = .active(group)
            return
        }
        self = .archived(ArchivedGroup(group: group, archivedAt: marks.archivedAt, restoresStandalone: marks.restoresStandalone))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .active(let group):
            try group.encode(to: encoder)
        case .archived(let archived):
            try archived.group.encode(to: encoder, marks: DockGroup.ArchiveMarks(archivedAt: archived.archivedAt, restoresStandalone: archived.restoresStandalone))
        }
    }

    /// The entries of a file: the active groups first, so a version without archives keeps their
    /// places (and their number shortcuts), then the archived ones.
    static func entries(of stored: StoredGroups) -> [GroupEntry] {
        stored.active.map(GroupEntry.active) + stored.archived.map(GroupEntry.archived)
    }

    /// The groups of a file's entries, each list in the file's order.
    static func storedGroups(from entries: [GroupEntry]) -> StoredGroups {
        var active: [DockGroup] = []
        var archived: [ArchivedGroup] = []
        for entry in entries {
            switch entry {
            case .active(let group): active.append(group)
            case .archived(let group): archived.append(group)
            }
        }
        return StoredGroups(active: active, archived: archived)
    }
}
