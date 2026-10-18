import DockGroupsCore
import SwiftUI

/// The list of groups, reorderable by dragging, with add/remove buttons underneath. Apps dragged
/// from the selected group's app list onto another group move to that group.
struct GroupSidebarView: View {
    @ObservedObject var store: GroupStore
    @Binding var selection: DockGroup.ID?
    let onAdd: () -> Void
    let onRename: (DockGroup) -> Void
    let onDelete: (DockGroup) -> Void
    let onOpenAll: (DockGroup) -> Void
    let onHideAll: (DockGroup) -> Void

    /// The row an app is being dragged over.
    @State private var dropTargetID: DockGroup.ID?

    private var selectedGroup: DockGroup? {
        selection.flatMap(store.group(withID:))
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.groups) { group in
                GroupSidebarRow(group: group, isDropTarget: dropTargetID == group.id)
                    .tag(group.id)
                    // The dragged apps come from the selected group, so only the others take them.
                    .onDrop(
                        of: group.id == selection ? [] : [GroupAppDrag.type],
                        isTargeted: dropTargetBinding(for: group.id)
                    ) { providers in
                        GroupAppDrag.load(from: providers) { drag in
                            store.moveApp(bundleIdentifier: drag.bundleIdentifier, fromGroup: drag.groupID, toGroup: group.id)
                        }
                    }
                    .contextMenu {
                        Button("Open All") { onOpenAll(group) }
                            .disabled(group.apps.isEmpty)
                        Button("Hide All") { onHideAll(group) }
                            .disabled(group.apps.isEmpty)
                        Button("Rename…") { onRename(group) }
                        Divider()
                        Button("Delete…", role: .destructive) { onDelete(group) }
                    }
            }
            .onMove { source, destination in
                store.moveGroups(fromOffsets: source, toOffset: destination)
            }
        }
        .onDeleteCommand {
            if let selectedGroup { onDelete(selectedGroup) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
    }

    private func dropTargetBinding(for id: DockGroup.ID) -> Binding<Bool> {
        Binding(
            get: { dropTargetID == id },
            set: { isTargeted in
                if isTargeted {
                    dropTargetID = id
                } else if dropTargetID == id {
                    dropTargetID = nil
                }
            }
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .help("Add a group")

                Button {
                    if let selectedGroup { onDelete(selectedGroup) }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .help("Delete the selected group")
                .disabled(selectedGroup == nil)

                Spacer()

                Text("^[\(store.groups.count) group](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct GroupSidebarRow: View {
    let group: DockGroup
    /// An app is being dragged over the row; dropping moves it to this group.
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(group.emoji)
                .font(.title3)
            Text(group.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.apps.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(Text("^[\(group.apps.count) app](inflect: true)"))
        }
        .padding(.vertical, 2)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, -4)
            }
        }
    }
}
