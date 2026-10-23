import Foundation

/// Something the user can do with one item of a group, from a menu.
public enum ItemAction: Hashable, Sendable, CaseIterable {
    /// Opens the item: launches or activates an app, opens a website, file or folder.
    case open
    /// Shows the item in Quick Look (`PopupQuickLook.target`).
    case quickLook
    /// Selects the item in a Finder window.
    case showInFinder
    /// Copies a website's address.
    case copyURL
    /// Points a missing file or folder at where it is now (`GroupStore.relinkItem`).
    case locate
    /// Edits the item's alias, tags and task notes.
    case editDetails
    /// Moves the item to another group.
    case moveTo
    /// Removes the item from the group; the item itself isn't touched.
    case remove
}

/// Where an item's actions are offered.
public enum ItemActionContext: Hashable, Sendable {
    /// The popup's context menu: the main app's, which can edit the group, or a standalone group's
    /// own app's, which can't.
    case popup(isEditable: Bool)
    /// The context menu of the item's row in the group window (removing has its own button there).
    case groupWindow
    /// A standalone group's Dock menu, which only opens items.
    case dockMenu
}

extension ItemAction {
    /// The actions offered for `item` in `context`, in menu order, given where it is (`presence`).
    ///
    /// - Quick Look and Show in Finder need something on disk to show: a found app, file or
    ///   folder, or a file or folder the app couldn't check (Quick Look and Finder read it).
    /// - Locate… is for a file or folder that's missing, and only where the group can be edited.
    /// - Copy URL is for websites.
    /// - Edit Details… is offered for every item, found or not, where the group can be edited: in
    ///   the group window, and in the main app's popup (which opens the editor there).
    /// - The popup always offers Open (the launch report says why an item didn't open); the Dock
    ///   menu offers it only for an item worth trying, and nothing else.
    public static func available(for item: GroupItem, presence: ItemPresence, in context: ItemActionContext) -> [ItemAction] {
        let canShow = PopupQuickLook.target(for: item, presence: presence) != nil
        let canLocate = item.kind.isFileSystemItem && presence == .missing
        var actions: [ItemAction] = []
        switch context {
        case .popup(let isEditable):
            actions.append(.open)
            if canShow { actions += [.quickLook, .showInFinder] }
            if item.isWebsite { actions.append(.copyURL) }
            if isEditable {
                if canLocate { actions.append(.locate) }
                actions += [.editDetails, .moveTo, .remove]
            }
        case .groupWindow:
            if canShow { actions += [.showInFinder, .quickLook] }
            actions.append(.editDetails)
            if canLocate { actions.append(.locate) }
            actions.append(.moveTo)
        case .dockMenu:
            if presence.isOpenable { actions.append(.open) }
        }
        return actions
    }
}
