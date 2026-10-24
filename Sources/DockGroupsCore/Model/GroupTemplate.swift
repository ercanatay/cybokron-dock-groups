import Foundation

/// A saved copy of a group's items and settings that new groups are made from (spec I-3): its
/// items with their details and launch options, its Dock tile, popup, pinning, Free Layout cells,
/// and Start and Finish settings. A template is a blueprint, never a group: nothing reads it to
/// open, start or register anything, and a group made from it is a new group the user sees, whose
/// items are checked whenever they open, as every group's are.
///
/// The blueprint has no identity or Dock icon of its own: its identifier is the template's, it
/// isn't standalone and it has no keyboard shortcut — whatever the group or the file said.
public struct GroupTemplate: Identifiable, Hashable, Sendable {
    /// The most templates kept.
    public static let maximumCount = 50

    public let id: UUID
    /// When it was saved, in whole seconds; `nil` when the file's date couldn't be read.
    public let savedAt: Date?
    /// The blueprint (normalized: see the type's description).
    public let group: DockGroup

    /// The template's name: its blueprint's, which groups made from it take.
    public var name: String { group.name }

    /// A template of `group`, named `name` (blank or `nil`: the group's name).
    public init(saving group: DockGroup, named name: String? = nil, id: UUID = UUID(), at date: Date? = Date()) {
        self.id = id
        savedAt = date.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        let templateName = name.flatMap(DockGroup.sanitizedName) ?? DockGroup.sanitizedName(group.name) ?? DockGroup.defaultName
        self.group = Self.blueprint(of: group, id: id, name: templateName)
    }

    /// The same template under another name.
    func renamed(_ name: String) -> GroupTemplate {
        GroupTemplate(saving: group, named: name, id: id, at: savedAt)
    }

    /// The same template holding `group` (cleaned up, as when a backup is read).
    func replacingGroup(_ group: DockGroup) -> GroupTemplate {
        GroupTemplate(saving: group, named: name, id: id, at: savedAt)
    }

    /// A new group made from the blueprint: a new identity, `name`, and everything else copied —
    /// not standalone, without a keyboard shortcut.
    public func makeGroup(named name: String) -> DockGroup {
        Self.blueprint(of: group, id: UUID(), name: name)
    }

    private static func blueprint(of group: DockGroup, id: UUID, name: String) -> DockGroup {
        DockGroup(
            id: id,
            name: DockGroup.sanitizedName(name) ?? DockGroup.defaultName,
            emoji: group.emoji,
            apps: group.apps,
            tile: group.tile,
            isPinned: group.isPinned,
            isStandalone: false,
            popup: group.popup,
            freeLayoutSlots: group.freeLayoutSlots,
            switching: group.switching,
            shortcut: nil
        )
    }
}

extension GroupTemplate: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, savedAt, group
    }

    /// `{ "id": …, "savedAt": "2026-10-25T09:30:00Z", "group": { … } }`. The identifier and the
    /// group are required; the date is read leniently, written in ISO 8601 by hand as the groups
    /// file's archive dates are (`DockGroup.ArchiveMarks`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let group = try container.decode(DockGroup.self, forKey: .group)
        let savedAt = container.decodeLeniently(String.self, forKey: .savedAt).flatMap(DockGroup.ArchiveMarks.date(from:))
        self.init(saving: group, named: group.name, id: id, at: savedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let savedAt {
            try container.encode(DockGroup.ArchiveMarks.string(from: savedAt), forKey: .savedAt)
        }
        try container.encode(group, forKey: .group)
    }
}

extension GroupTemplate {
    /// `templates` with each identifier and each name (as groups' names are compared) once — the
    /// first kept — and at most `maximumCount` of them.
    static func sanitized(_ templates: [GroupTemplate]) -> [GroupTemplate] {
        var ids = Set<UUID>()
        var names = Set<String>()
        var kept: [GroupTemplate] = []
        for template in templates where kept.count < maximumCount {
            guard ids.insert(template.id).inserted, names.insert(GroupNaming.comparisonKey(template.name)).inserted else { continue }
            kept.append(template)
        }
        return kept
    }
}
