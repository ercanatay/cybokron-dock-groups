import DockGroupsCore
import SwiftUI

/// The list of groups, reorderable by dragging, with add/remove buttons underneath. Apps dragged
/// from the selected group's app list onto another group move to that group.
///
/// The archived groups follow in a collapsed Archived section (spec §3.3): dimmed, newest first,
/// not draggable and taking no drops, with Restore and Delete… only. The + button adds a group; its
/// menu adds one from a template or from the open apps, or manages the templates.
struct GroupSidebarView: View {
    struct Actions {
        let add: () -> Void
        let addFromTemplate: (GroupTemplate) -> Void
        let manageTemplates: () -> Void
        /// New Group from Open Apps…: the capture sheet for a new group.
        let captureNewGroup: () -> Void
        let rename: (DockGroup) -> Void
        let duplicate: (DockGroup) -> Void
        let saveAsTemplate: (DockGroup) -> Void
        /// Archive: asks first for a standalone group.
        let archive: (DockGroup) -> Void
        let restore: (ArchivedGroup) -> Void
        /// Delete…, for an active or an archived group: asks first.
        let delete: (DockGroup) -> Void
        let openAll: (DockGroup) -> Void
        let hideAll: (DockGroup) -> Void
    }

    @ObservedObject var store: GroupStore
    @ObservedObject var templates: TemplateStore
    @Binding var selection: DockGroup.ID?
    let actions: Actions

    /// The row an app is being dragged over.
    @State private var dropTargetID: DockGroup.ID?
    /// Whether the Archived section is expanded; collapsed until opened.
    @State private var showsArchived = false

    /// The selected group, active or archived.
    private var selectedGroup: DockGroup? {
        guard let selection else { return nil }
        return store.group(withID: selection) ?? store.archivedGroup(withID: selection)?.group
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.groups) { group in
                GroupSidebarRow(group: group, isArchived: false, isDropTarget: dropTargetID == group.id)
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
                        Button(L10n.Common.openAll) { actions.openAll(group) }
                            .disabled(group.apps.isEmpty)
                        Button(L10n.Common.hideAll) { actions.hideAll(group) }
                            .disabled(group.apps.isEmpty)
                        Button(L10n.GroupWindow.renameMenu) { actions.rename(group) }
                        Divider()
                        Button(L10n.GroupWindow.Archive.duplicate) { actions.duplicate(group) }
                        Button(L10n.Templates.saveAsTemplate) { actions.saveAsTemplate(group) }
                        Button(L10n.GroupWindow.Archive.archive) { actions.archive(group) }
                        Divider()
                        Button(L10n.GroupWindow.deleteMenu, role: .destructive) { actions.delete(group) }
                    }
            }
            .onMove { source, destination in
                store.moveGroups(fromOffsets: source, toOffset: destination)
            }

            if !store.archivedGroups.isEmpty {
                Section(isExpanded: $showsArchived) {
                    // Newest first; no onMove and no onDrop: archived groups can't be reordered or edited.
                    ForEach(store.archivedGroups.reversed()) { archived in
                        GroupSidebarRow(group: archived.group, isArchived: true, isDropTarget: false)
                            .tag(archived.id)
                            .contextMenu {
                                Button(L10n.GroupWindow.Archive.restore) { actions.restore(archived) }
                                Divider()
                                Button(L10n.GroupWindow.deleteMenu, role: .destructive) { actions.delete(archived.group) }
                            }
                    }
                } header: {
                    Text(L10n.GroupWindow.Archive.section(store.archivedGroups.count))
                }
            }
        }
        .onDeleteCommand {
            if let selectedGroup { actions.delete(selectedGroup) }
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
                addMenu

                Button {
                    if let selectedGroup { actions.delete(selectedGroup) }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .help(L10n.GroupWindow.deleteGroupHelp)
                .disabled(selectedGroup == nil)

                Spacer()

                Text(L10n.Common.groupCount(store.groups.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// + adds a group, as before; its menu also has the templates.
    private var addMenu: some View {
        Menu {
            Button(L10n.Templates.newGroup, action: actions.add)
            Menu(L10n.Templates.newGroupFromTemplate) {
                if templates.templates.isEmpty {
                    Button(L10n.Templates.noTemplates) {}
                        .disabled(true)
                } else {
                    ForEach(templates.templates) { template in
                        Button {
                            actions.addFromTemplate(template)
                        } label: {
                            Text(verbatim: "\(template.group.emoji)  \(template.name)")
                        }
                    }
                }
            }
            Button(L10n.Capture.sidebarItem, action: actions.captureNewGroup)
            Divider()
            Button(L10n.Templates.manage, action: actions.manageTemplates)
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            actions.add()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 3)
        .help(L10n.Templates.addMenuHelp)
        .accessibilityLabel(L10n.GroupWindow.addGroupHelp)
    }
}

private struct GroupSidebarRow: View {
    let group: DockGroup
    /// An archived group's row is dimmed.
    let isArchived: Bool
    /// An app is being dragged over the row; dropping moves it to this group.
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(group.emoji)
                .font(.title3)
                .opacity(isArchived ? 0.5 : 1)
            Text(group.name)
                .lineLimit(1)
                .foregroundStyle(isArchived ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(verbatim: "\(group.apps.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(L10n.Common.itemCount(group.apps.count))
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
