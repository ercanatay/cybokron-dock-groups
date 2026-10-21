import AppIntents
import DockGroupsCore

/// A group as Siri, Spotlight and the Shortcuts app see it. It's identified by the group's ID, so
/// shortcuts keep working after the group is renamed.
struct GroupEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Group"
    static let defaultQuery = GroupEntityQuery()

    let id: UUID
    let name: String
    let emoji: String
    /// Apps and websites alike.
    let itemCount: Int

    init(group: DockGroup) {
        id = group.id
        name = group.name
        emoji = group.emoji
        itemCount = group.apps.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(emoji)  \(itemCount == 1 ? "1 item" : "\(itemCount) items")"
        )
    }
}

/// Looks groups up for the system: by ID, by (part of) their name, and all of them as suggestions,
/// which also teaches Siri the group names.
struct GroupEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [GroupEntity.ID]) async throws -> [GroupEntity] {
        let groups = GroupIntentSupport.groups
        return identifiers.compactMap { id in
            groups.first { $0.id == id }.map(GroupEntity.init(group:))
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [GroupEntity] {
        GroupLookup.search(string, in: GroupIntentSupport.groups).map(GroupEntity.init(group:))
    }

    @MainActor
    func suggestedEntities() async throws -> [GroupEntity] {
        GroupIntentSupport.groups.map(GroupEntity.init(group:))
    }
}
