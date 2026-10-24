import AppKit
import DockGroupsCore
import SwiftUI

/// One item of a group: icon, the name it's shown with (its alias, when it has one) and its tags,
/// below them its own name when an alias is shown instead, and what the item is — an app's bundle
/// identifier (or location, for an app without one), a website's address, a file's or folder's
/// location — or what's wrong with it (`ItemRowStatus`), and under that its launch options when it
/// has some (`ItemLaunchCaption`). A missing file or folder has Locate…;
/// every row has an ⓘ button that opens the details editor (`detailsEditor`, in a popover) and a
/// button that removes the item from the group.
///
/// The row only shows what it's given: where the item is was checked beforehand
/// (`ItemPresenceCache`), so drawing it never looks at the disk or asks LaunchServices.
struct AppRowView<DetailsEditor: View>: View {
    let app: GroupItem
    let status: ItemRowStatus
    let icon: NSImage
    /// The item can't be opened (missing, or on a volume that isn't connected): its icon is dimmed.
    let isDimmed: Bool
    let onRemove: () -> Void
    /// Says where a missing file or folder is now; `nil` when there's nothing to locate.
    var onLocate: (() -> Void)?
    /// The delay and the app chosen to open it; `nil` without launch options.
    var launchCaption: ItemLaunchCaption?
    /// Whether the details editor is open in the ⓘ button's popover.
    @Binding var isEditingDetails: Bool
    @ViewBuilder let detailsEditor: () -> DetailsEditor

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(isDimmed ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.displayName)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !app.details.tags.isEmpty {
                        Text(verbatim: app.details.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel(L10n.Details.tagsList(app.details.tags.joined(separator: ", ")))
                    }
                }
                if app.details.alias != nil {
                    Text(L10n.Details.originalName(app.name))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(statusText)
                    .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let launchCaption {
                    Text(launchCaption.text)
                        .foregroundStyle(launchCaption.isOpenerMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help(ifAny: PopupCellText.Details(item: app)?.text)
            Spacer(minLength: 8)
            if let onLocate {
                Button(L10n.Item.locate, action: onLocate)
                    .controlSize(.small)
            }
            Button {
                isEditingDetails = true
            } label: {
                Image(systemName: app.details.isEmpty && app.launch.isEmpty ? "info.circle" : "info.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.Details.buttonHelp(app.displayName))
            .accessibilityLabel(L10n.Details.buttonHelp(app.displayName))
            .popover(isPresented: $isEditingDetails, arrowEdge: .bottom, content: detailsEditor)
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
        let name = app.displayName
        switch app.kind {
        case .application: return L10n.GroupWindow.removeAppHelp(name)
        case .website: return L10n.GroupWindow.removeWebsiteHelp(name)
        case .file: return L10n.GroupWindow.removeFileHelp(name)
        case .folder: return L10n.GroupWindow.removeFolderHelp(name)
        }
    }
}

extension View {
    /// A tooltip when there's something to say; none for `nil` or an empty text.
    @ViewBuilder
    func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}

extension PopupCellText.Details {
    /// “Name: Q3 Report.pdf · Tags: finance, q3 · Notes: Send the totals…”, for tooltips.
    var text: String {
        var parts: [String] = []
        if let name { parts.append(L10n.Details.originalName(name)) }
        if !tags.isEmpty { parts.append(L10n.Details.tagsList(tags.joined(separator: ", "))) }
        if let notes { parts.append(L10n.Details.notesSummary(notes)) }
        return parts.joined(separator: " · ")
    }
}

/// The context menu of an item's row in the group window, from `ItemAction.available`: Show in
/// Finder and Quick Look for what's on disk, Edit Details…, Locate… for a missing file or folder,
/// and Move to (the other groups).
struct ItemRowContextMenu: ViewModifier {
    let item: GroupItem
    let presence: ItemPresence?
    let moveTargets: [GroupMoveTarget]
    let showInFinder: () -> Void
    let quickLook: () -> Void
    let editDetails: () -> Void
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
                    case .editDetails:
                        Button(L10n.Details.menu, action: editDetails)
                    case .locate:
                        Button(L10n.Item.locate, action: locate)
                    case .moveTo:
                        Menu(L10n.Common.moveTo) {
                            ForEach(moveTargets) { target in
                                Button(target.title) { move(target.id) }
                            }
                        }
                    case .open, .copyURL, .remove:
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The actions shown: Move to needs another group. An item not checked yet is offered what a
    /// found one is; the action checks it again.
    private var offered: [ItemAction] {
        let checked = presence ?? (item.isWebsite ? .online : .unverified)
        return ItemAction.available(for: item, presence: checked, in: .groupWindow).filter { action in
            action != .moveTo || !moveTargets.isEmpty
        }
    }
}
