import AppKit
import DockGroupsCore
import SwiftUI

/// The group the group window shows, shared with `MainWindowController` so Group Settings
/// requests (the popup's gear, menus, links) can open the window on a given group — and something
/// to do there once it shows the group, such as the popup's Edit Details….
@MainActor
final class GroupWindowSelection: ObservableObject {
    @Published var groupID: DockGroup.ID?
    /// Done (and cleared) by the group's settings once they show; `nil` when there's nothing to do.
    @Published var request: GroupWindowRequest?
    /// A capture sheet to show (capture spec §2.6): shown, and cleared, once no other sheet is up.
    @Published var capture: CaptureRequest?
}

/// Something the popup asks the group window to do in one of its groups: the popup can't host the
/// details editor or an open panel itself.
struct GroupWindowRequest: Equatable {
    enum Action: Equatable {
        /// Opens the details editor of the item with this identity.
        case editDetails(itemID: String)
        /// Add Apps… (the popup of an empty group).
        case addApps
        /// Add Files or Folders… (the popup of an empty group).
        case addFilesAndFolders
    }

    let groupID: DockGroup.ID
    let action: Action
    /// Tells two requests for the same thing apart, so asking again works.
    let id = UUID()
}

/// Group list on the left, the selected group's settings on the right — or, for an archived group,
/// its read-only summary (`ArchivedGroupView`). Duplicate, Archive, Restore and the templates'
/// sheets start here (spec §1.6–1.9), and the capture sheet shows here (capture spec §2.6): when
/// another sheet, alert or open panel is up, it waits until that closes.
struct MainWindowView: View {
    struct Actions {
        let openAll: (DockGroup) -> Void
        /// Hides the group's running apps.
        let hideAll: (DockGroup) -> Void
        let showPopup: (DockGroup) -> Void
        /// Start and Finish, the user's click.
        let start: (DockGroup) -> Void
        let finish: (DockGroup) -> Void
        /// Settings → Switching, where the protected apps are.
        let showProtectedApps: () -> Void
        /// Archives the group; its items waiting for their launch delay don't open.
        let archive: (DockGroup) -> Void
        /// Makes an archived group active again — standalone again when it was; `nil` when no
        /// archived group has this identifier.
        let restore: (DockGroup.ID) -> GroupRestoreResult?
        /// New Group from Open Apps… and Add Open Apps…: reads the open apps now, then shows the
        /// capture sheet.
        let capture: (CaptureTarget) -> Void
    }

    /// The note that a restored group came back without its keyboard shortcut.
    private struct RestoreNote {
        let title: String
        let message: String
    }

    @ObservedObject var store: GroupStore
    /// Save as Template…, the + menu's templates and Manage Templates.
    @ObservedObject var templates: TemplateStore
    let tiles: TileImageCache
    let standalone: StandaloneController
    /// The current group, for the Start and Finish section.
    let session: ContextSession
    /// The group shortcuts, for the Keyboard Shortcut section.
    let shortcuts: GlobalShortcutMonitor
    /// Plans and adds what the capture sheet shows.
    let capture: CaptureController
    let actions: Actions
    @ObservedObject var selection: GroupWindowSelection
    /// Where the selected group's items are, their icons and Quick Look.
    let items: GroupWindowItems

    @State private var isRenaming = false
    @State private var renameTargetID: DockGroup.ID?
    @State private var renameText = ""

    @State private var isConfirmingDeletion = false
    @State private var deletionCandidate: DockGroup?

    @State private var isConfirmingArchive = false
    @State private var archiveCandidate: DockGroup?
    @State private var restoreNote: RestoreNote?

    /// The group Save as Template… shows its sheet for.
    @State private var templateSource: DockGroup?
    @State private var isManagingTemplates = false
    /// The capture sheet showing; the next one waits in `selection.capture`.
    @State private var shownCapture: CaptureRequest?

    var body: some View {
        NavigationSplitView {
            GroupSidebarView(
                store: store,
                templates: templates,
                selection: $selection.groupID,
                actions: GroupSidebarView.Actions(
                    add: addGroup,
                    addFromTemplate: addGroup(from:),
                    manageTemplates: { isManagingTemplates = true },
                    captureNewGroup: { actions.capture(.newGroup) },
                    rename: beginRename,
                    duplicate: duplicate,
                    saveAsTemplate: { templateSource = $0 },
                    archive: requestArchive,
                    restore: restore,
                    delete: confirmDeletion,
                    openAll: actions.openAll,
                    hideAll: actions.hideAll
                )
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let id = selection.groupID, let group = store.group(withID: id) {
                GroupDetailView(
                    store: store,
                    standalone: standalone,
                    session: session,
                    shortcuts: shortcuts,
                    group: group,
                    tiles: tiles,
                    actions: actions,
                    items: items,
                    selection: selection
                )
                .id(group.id)
            } else if let id = selection.groupID, let archived = store.archivedGroup(withID: id) {
                ArchivedGroupView(
                    archived: archived,
                    onRestore: { restore(archived) },
                    onDelete: { confirmDeletion(archived.group) }
                )
                .id(archived.id)
            } else {
                ContentUnavailableView {
                    Label(
                        hasNoGroups ? L10n.GroupWindow.noGroupsTitle : L10n.GroupWindow.noSelectionTitle,
                        systemImage: "square.grid.2x2"
                    )
                } description: {
                    Text(hasNoGroups ? L10n.GroupWindow.noGroupsDescription : L10n.GroupWindow.noSelectionDescription)
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
        .confirmationDialog(
            L10n.GroupWindow.Archive.confirmTitle(archiveCandidate?.name ?? ""),
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible,
            presenting: archiveCandidate
        ) { group in
            Button(L10n.GroupWindow.Archive.archive) { archive(group) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.GroupWindow.Archive.confirmMessage)
        }
        .alert(
            restoreNote?.title ?? "",
            isPresented: Binding(
                get: { restoreNote != nil },
                set: { isPresented in if !isPresented { restoreNote = nil } }
            ),
            presenting: restoreNote
        ) { _ in
            Button(L10n.Common.ok) {}
        } message: { note in
            Text(note.message)
        }
        .sheet(item: $templateSource) { group in
            SaveTemplateSheet(templates: templates, store: store, group: group) { templateSource = nil }
        }
        .sheet(isPresented: $isManagingTemplates) {
            ManageTemplatesSheet(
                templates: templates,
                onNewGroup: { template in
                    isManagingTemplates = false
                    addGroup(from: template)
                },
                dismiss: { isManagingTemplates = false }
            )
        }
        .sheet(item: $shownCapture) { request in
            CaptureSheet(
                request: request,
                capture: capture,
                icons: items.icons,
                onCreated: { id in selection.groupID = id },
                dismiss: { shownCapture = nil }
            )
        }
        .onChange(of: selection.capture?.id) {
            // Once the window that was just asked to come forward is there for the sheet.
            DispatchQueue.main.async { presentPendingCapture() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
            guard let window = note.object as? NSWindow, window === items.window else { return }
            DispatchQueue.main.async { presentPendingCapture() }
        }
        .alert(
            templates.issue?.title ?? "",
            isPresented: Binding(
                get: { templates.issue != nil },
                set: { isPresented in if !isPresented { templates.dismissIssue() } }
            ),
            presenting: templates.issue
        ) { _ in
            Button(L10n.Common.ok) { templates.dismissIssue() }
        } message: { issue in
            Text(issue.message)
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
            if selection.groupID == nil {
                selection.groupID = store.groups.first?.id
            }
            DispatchQueue.main.async { presentPendingCapture() }
        }
    }

    /// Shows the waiting capture sheet unless a sheet, an alert or an open panel is up in the
    /// window — then it shows once that ends. A group that was archived or deleted meanwhile gets
    /// no sheet: it's never a target.
    private func presentPendingCapture() {
        guard let request = selection.capture, shownCapture == nil, items.window?.attachedSheet == nil else { return }
        selection.capture = nil
        if case .group(let id) = request.target, store.group(withID: id) == nil {
            NSSound.beep()
            return
        }
        shownCapture = request
    }

    /// No group at all, active or archived.
    private var hasNoGroups: Bool {
        store.groups.isEmpty && store.archivedGroups.isEmpty
    }

    private func addGroup() {
        selection.groupID = store.addGroup().id
    }

    /// A group made from the template, at the end of the list and selected. Nothing opens.
    private func addGroup(from template: GroupTemplate) {
        selection.groupID = store.addGroup(from: template).id
    }

    /// The copy goes at the end of the list, selected.
    private func duplicate(_ group: DockGroup) {
        if let copy = store.duplicateGroup(group.id) {
            selection.groupID = copy.id
        }
    }

    /// A standalone group asks first: its own app and Dock icon go away.
    private func requestArchive(_ group: DockGroup) {
        if group.isStandalone {
            archiveCandidate = group
            isConfirmingArchive = true
        } else {
            archive(group)
        }
    }

    private func archive(_ group: DockGroup) {
        if selection.groupID == group.id {
            selection.groupID = nil
        }
        actions.archive(group)
        archiveCandidate = nil
    }

    /// Puts the group back at the end of the list, selected; says so when it came back without its
    /// keyboard shortcut, which another group has now.
    private func restore(_ archived: ArchivedGroup) {
        guard let result = actions.restore(archived.id) else { return }
        selection.groupID = result.group.id
        if let removed = result.removedShortcut {
            let owner = result.shortcutOwner.flatMap(store.group(withID:))?.name ?? ""
            restoreNote = RestoreNote(
                title: result.removedShortcutTitle,
                message: result.removedShortcutMessage(ownerName: owner, keyTitle: KeyNames.title(for: removed.keys))
            )
        }
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
        if selection.groupID == group.id {
            selection.groupID = nil
        }
        store.deleteGroup(group.id)
        deletionCandidate = nil
    }
}
