import AppKit
import DockGroupsCore
import SwiftUI

/// One item of a group: icon, name, and below it what the item is — an app's bundle identifier
/// (or location, for an app without one), a website's address, a file's or folder's location — or
/// what's wrong with it (`ItemRowStatus`); a missing file or folder has Locate…, and every row a
/// button that removes the item from the group.
///
/// The row only shows what it's given: where the item is was checked beforehand
/// (`ItemPresenceCache`), so drawing it never looks at the disk or asks LaunchServices.
struct AppRowView: View {
    let app: GroupItem
    let status: ItemRowStatus
    let icon: NSImage
    /// The item can't be opened (missing, or on a volume that isn't connected): its icon is dimmed.
    let isDimmed: Bool
    let onRemove: () -> Void
    /// Says where a missing file or folder is now; `nil` when there's nothing to locate.
    var onLocate: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(isDimmed ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                Text(statusText)
                    .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let onLocate {
                Button(L10n.Item.locate, action: onLocate)
                    .controlSize(.small)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(removeHelp)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch status {
        case .identity(let identity): return identity
        case .appNotFound(let identity): return L10n.GroupWindow.appNotFound(identity)
        case .missing(let location): return L10n.Item.missingRow(location)
        case .volumeUnavailable(let volume, let location): return L10n.Item.volumeRow(volume, location: location)
        case .unverified(let location): return L10n.Item.unverifiedRow(location)
        }
    }

    private var removeHelp: String {
        switch app.kind {
        case .application: return L10n.GroupWindow.removeAppHelp(app.name)
        case .website: return L10n.GroupWindow.removeWebsiteHelp(app.name)
        case .file: return L10n.GroupWindow.removeFileHelp(app.name)
        case .folder: return L10n.GroupWindow.removeFolderHelp(app.name)
        }
    }
}

/// The context menu of an item's row in the group window, from `ItemAction.available`: Show in
/// Finder and Quick Look for what's on disk, Locate… for a missing file or folder, and Move to
/// (the other groups). Without any of them the row gets no context menu.
struct ItemRowContextMenu: ViewModifier {
    let item: GroupItem
    let presence: ItemPresence?
    let moveTargets: [GroupMoveTarget]
    let showInFinder: () -> Void
    let quickLook: () -> Void
    let locate: () -> Void
    let move: (DockGroup.ID) -> Void

    func body(content: Content) -> some View {
        let actions = offered
        if actions.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(actions, id: \.self) { action in
                    switch action {
                    case .showInFinder:
                        Button(L10n.Common.showInFinder, action: showInFinder)
                    case .quickLook:
                        Button(L10n.Item.quickLook, action: quickLook)
                    case .locate:
                        Button(L10n.Item.locate, action: locate)
                    case .moveTo:
                        Menu(L10n.Common.moveTo) {
                            ForEach(moveTargets) { target in
                                Button(target.title) { move(target.id) }
                            }
                        }
                    case .open, .copyURL, .editDetails, .remove:
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The actions shown: Edit Details… comes with the details editor, and Move to needs another
    /// group. An item not checked yet is offered what a found one is; the action checks it again.
    private var offered: [ItemAction] {
        let checked = presence ?? (item.isWebsite ? .online : .unverified)
        return ItemAction.available(for: item, presence: checked, in: .groupWindow).filter { action in
            switch action {
            case .editDetails: return false
            case .moveTo: return !moveTargets.isEmpty
            default: return true
            }
        }
    }
}
