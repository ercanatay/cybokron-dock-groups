import AppKit
import DockGroupsCore
import SwiftUI
import UniformTypeIdentifiers

/// A group an item can be moved to, as the "Move to" menus list it (see `GroupStore.moveApp`).
struct GroupMoveTarget: Identifiable, Hashable {
    let id: DockGroup.ID
    let title: String

    /// The groups other than `sourceID`, in list order.
    static func targets(in groups: [DockGroup], excluding sourceID: DockGroup.ID) -> [GroupMoveTarget] {
        groups.filter { $0.id != sourceID }.map { GroupMoveTarget(id: $0.id, title: "\($0.emoji)  \($0.name)") }
    }
}

/// An app dragged from a group's app list in the group window, to drop it on another group in the
/// sidebar. The item provider is visible to this app only, so other apps never see the drag.
struct GroupAppDrag: Codable, Equatable, Sendable {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let type = UTType(exportedAs: "com.cybokron.dockgroups.group-app")

    let groupID: DockGroup.ID
    let bundleIdentifier: String

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Reads the dragged app from the first of `providers` that carries one and passes it to
    /// `completion` on the main actor. Returns whether any provider carries one.
    static func load(from providers: [NSItemProvider], completion: @escaping @MainActor @Sendable (GroupAppDrag) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let drag = try? JSONDecoder().decode(GroupAppDrag.self, from: data) else { return }
            Task { @MainActor in completion(drag) }
        }
        return true
    }
}
