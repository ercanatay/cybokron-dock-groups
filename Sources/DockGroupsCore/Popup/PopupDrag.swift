import CoreGraphics

/// What dropping an app that was dragged in the popup does.
public enum PopupDrop: Equatable, Sendable {
    /// Nothing: the app was dropped back on its own slot.
    case none
    /// The app moves to this index of the group's app list.
    case move(to: Int)
    /// The app was dropped outside the popup and leaves the group. The app itself isn't affected.
    case remove

    public init(sourceIndex: Int, targetIndex: Int, isInRemovalArea: Bool) {
        if isInRemovalArea {
            self = .remove
        } else if sourceIndex == targetIndex {
            self = .none
        } else {
            self = .move(to: targetIndex)
        }
    }
}

/// Dragging apps in the popup: within the grid to reorder them, out of the popup to remove them.
public enum PopupDrag {
    /// How far beyond the popup's edges the pointer has to be for a drop to remove the app, so a
    /// drop that just overshoots the edge doesn't.
    public static let removalMargin: CGFloat = 12

    /// Whether dropping with the pointer at `location` removes the app; both in screen coordinates.
    public static func isRemovalLocation(_ location: CGPoint, panelFrame: CGRect) -> Bool {
        !panelFrame.insetBy(dx: -removalMargin, dy: -removalMargin).contains(location)
    }

    /// The order the grid shows while `id` is dragged: moved to `targetIndex` (clamped), or left
    /// out while it's over the removal area (`targetIndex == nil`). Unknown ids leave `ids` as is.
    public static func previewOrder<ID: Equatable>(_ ids: [ID], moving id: ID, to targetIndex: Int?) -> [ID] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        var order = ids
        let moving = order.remove(at: source)
        if let targetIndex {
            order.insert(moving, at: min(max(targetIndex, 0), order.count))
        }
        return order
    }
}
