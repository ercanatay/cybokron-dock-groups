import DockGroupsCore
import SwiftUI

/// The list of groups, reorderable by dragging, with add/remove buttons underneath.
struct GroupSidebarView: View {
    @ObservedObject var store: GroupStore
    @Binding var selection: DockGroup.ID?
    let onAdd: () -> Void
    let onRename: (DockGroup) -> Void
    let onDelete: (DockGroup) -> Void
    let onOpenAll: (DockGroup) -> Void

    private var selectedGroup: DockGroup? {
        selection.flatMap(store.group(withID:))
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.groups) { group in
                GroupSidebarRow(group: group)
                    .tag(group.id)
                    .contextMenu {
                        Button("Open All") { onOpenAll(group) }
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
    }
}
