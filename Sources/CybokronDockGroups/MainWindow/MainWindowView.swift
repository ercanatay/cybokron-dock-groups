import DockGroupsCore
import SwiftUI

/// Group list on the left, the selected group's settings on the right.
struct MainWindowView: View {
    struct Actions {
        let openAll: (DockGroup) -> Void
        /// Hides the group's running apps.
        let hideAll: (DockGroup) -> Void
        let showPopup: (DockGroup) -> Void
    }

    @ObservedObject var store: GroupStore
    let tiles: TileImageCache
    let standalone: StandaloneController
    let actions: Actions

    @State private var selection: DockGroup.ID?

    @State private var isRenaming = false
    @State private var renameTargetID: DockGroup.ID?
    @State private var renameText = ""

    @State private var isConfirmingDeletion = false
    @State private var deletionCandidate: DockGroup?

    var body: some View {
        NavigationSplitView {
            GroupSidebarView(
                store: store,
                selection: $selection,
                onAdd: addGroup,
                onRename: beginRename,
                onDelete: confirmDeletion,
                onOpenAll: actions.openAll,
                onHideAll: actions.hideAll
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let id = selection, let group = store.group(withID: id) {
                GroupDetailView(store: store, standalone: standalone, group: group, tiles: tiles, actions: actions)
                    .id(group.id)
            } else {
                ContentUnavailableView {
                    Label(
                        store.groups.isEmpty ? L10n.GroupWindow.noGroupsTitle : L10n.GroupWindow.noSelectionTitle,
                        systemImage: "square.grid.2x2"
                    )
                } description: {
                    Text(store.groups.isEmpty ? L10n.GroupWindow.noGroupsDescription : L10n.GroupWindow.noSelectionDescription)
                } actions: {
                    if store.groups.isEmpty {
                        Button(L10n.GroupWindow.addGroup, action: addGroup)
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .alert(L10n.GroupWindow.renameTitle, isPresented: $isRenaming) {
            TextField(L10n.GroupWindow.name, text: $renameText)
            Button(L10n.GroupWindow.rename, action: commitRename)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.GroupWindow.renameMessage)
        }
        .confirmationDialog(
            L10n.GroupWindow.deleteTitle(deletionCandidate?.name ?? ""),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { group in
            Button(L10n.GroupWindow.deleteGroup, role: .destructive) { delete(group) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { group in
            Text(group.isStandalone ? L10n.GroupWindow.deleteMessageStandalone : L10n.GroupWindow.deleteMessage)
        }
        .alert(
            store.issue?.title ?? "",
            isPresented: Binding(
                get: { store.issue != nil },
                set: { isPresented in if !isPresented { store.dismissIssue() } }
            ),
            presenting: store.issue
        ) { _ in
            Button(L10n.Common.ok) { store.dismissIssue() }
        } message: { issue in
            Text(issue.message)
        }
        .onAppear {
            if selection == nil {
                selection = store.groups.first?.id
            }
        }
    }

    private func addGroup() {
        selection = store.addGroup().id
    }

    private func beginRename(_ group: DockGroup) {
        renameTargetID = group.id
        renameText = group.name
        isRenaming = true
    }

    private func commitRename() {
        guard let id = renameTargetID else { return }
        store.renameGroup(id, to: renameText)
        renameTargetID = nil
    }

    private func confirmDeletion(_ group: DockGroup) {
        deletionCandidate = group
        isConfirmingDeletion = true
    }

    private func delete(_ group: DockGroup) {
        if selection == group.id {
            selection = nil
        }
        store.deleteGroup(group.id)
        deletionCandidate = nil
    }
}
