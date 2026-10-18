import AppKit
import DockGroupsCore
import SwiftUI
import UniformTypeIdentifiers

/// A group an app can be moved to, as the "Move to" menus list it.
struct GroupMoveTarget: Identifiable, Hashable {
    let id: DockGroup.ID
    let title: String

    /// The groups other than `sourceID`, in list order.
    static func targets(in groups: [DockGroup], excluding sourceID: DockGroup.ID) -> [GroupMoveTarget] {
        groups.filter { $0.id != sourceID }.map { GroupMoveTarget(id: $0.id, title: "\($0.emoji)  \($0.name)") }
    }
}

/// A context menu with a "Move to" submenu of the other groups (see `GroupStore.moveApp`), for an
/// app in the popup or the group window. Without other groups the view gets no context menu.
struct MoveToGroupContextMenu: ViewModifier {
    let targets: [GroupMoveTarget]
    let move: (DockGroup.ID) -> Void

    func body(content: Content) -> some View {
        if targets.isEmpty {
            content
        } else {
            content.contextMenu {
                Menu("Move to") {
                    ForEach(targets) { target in
                        Button(target.title) { move(target.id) }
                    }
                }
            }
        }
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
