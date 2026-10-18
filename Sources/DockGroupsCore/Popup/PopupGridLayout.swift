import CoreGraphics

/// Sizes of the popup's grid cells, in points.
public struct PopupGridMetrics: Equatable, Sendable {
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    /// Space between neighboring cells, horizontally and vertically.
    public var spacing: CGFloat
    /// Space between the cells and the edges of the grid area.
    public var padding: CGFloat

    public init(cellWidth: CGFloat, cellHeight: CGFloat, spacing: CGFloat, padding: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.spacing = spacing
        self.padding = padding
    }
}

/// How a group's apps are arranged in the popup grid.
///
/// With `.auto` columns the grid keeps the standard width whatever the group's size; a fixed count
/// is an upper bound, so the popup shrinks to fit a group with fewer apps. Rows beyond `maxRows`
/// aren't shown at once: the grid scrolls instead.
public struct PopupGridLayout: Equatable, Sendable {
    /// Columns of the standard-size popup (`.auto`).
    public static let standardColumnCount = 5

    public let itemCount: Int
    public let columns: Int
    /// Rows needed for all items; at least one, so an empty group still has room for a message.
    public let rows: Int
    /// Rows shown without scrolling.
    public let visibleRows: Int

    public var scrolls: Bool { rows > visibleRows }
    /// Cells of all rows, including the empty end of the last row: where apps can go in Free Layout.
    public var slotCount: Int { rows * columns }

    public init(itemCount: Int, columns setting: PopupColumns, maxRows: Int) {
        let count = max(itemCount, 0)
        self.itemCount = count
        switch setting {
        case .auto:
            columns = Self.standardColumnCount
        case .fixed(let requested):
            let allowed = PopupOverrides.allowedCountRange
            let clamped = min(max(requested, allowed.lowerBound), allowed.upperBound)
            columns = max(1, min(clamped, count))
        }
        rows = max(1, (count + columns - 1) / columns)
        visibleRows = min(rows, max(maxRows, 1))
    }

    /// Size of the grid area showing `visibleRows` rows, padding included.
    public func visibleSize(metrics: PopupGridMetrics) -> CGSize {
        CGSize(width: width(metrics: metrics), height: height(ofRows: visibleRows, metrics: metrics))
    }

    /// Height of all rows, padding included: the scrolling content's height.
    public func contentHeight(metrics: PopupGridMetrics) -> CGFloat {
        height(ofRows: rows, metrics: metrics)
    }

    /// Top-left corner of the cell in slot `index` (slots run row by row), in coordinates of the
    /// whole grid content: the origin is its top-left corner, padding included, and y grows
    /// downward as in SwiftUI.
    public func cellOrigin(at index: Int, metrics: PopupGridMetrics) -> CGPoint {
        let slot = max(index, 0)
        return CGPoint(
            x: metrics.padding + CGFloat(slot % columns) * (metrics.cellWidth + metrics.spacing),
            y: metrics.padding + CGFloat(slot / columns) * (metrics.cellHeight + metrics.spacing)
        )
    }

    /// The slot of the cell under `point` (coordinates as in `cellOrigin`); points in the gaps
    /// between cells go to the nearest one, points beyond the grid to the closest edge slot, and
    /// points past the last app to the last slot. `nil` for an empty grid.
    public func slotIndex(at point: CGPoint, metrics: PopupGridMetrics) -> Int? {
        guard itemCount > 0 else { return nil }
        return min(cellIndex(at: point, metrics: metrics), itemCount - 1)
    }

    /// Like `slotIndex(at:metrics:)`, but any of the `slotCount` cells, so points past the last
    /// app hit the empty cells there, as Free Layout needs. `nil` for an empty grid.
    public func freeSlotIndex(at point: CGPoint, metrics: PopupGridMetrics) -> Int? {
        guard itemCount > 0 else { return nil }
        return cellIndex(at: point, metrics: metrics)
    }

    private func cellIndex(at point: CGPoint, metrics: PopupGridMetrics) -> Int {
        let column = Self.clampedIndex(
            (point.x - metrics.padding + metrics.spacing / 2) / (metrics.cellWidth + metrics.spacing),
            count: columns
        )
        let row = Self.clampedIndex(
            (point.y - metrics.padding + metrics.spacing / 2) / (metrics.cellHeight + metrics.spacing),
            count: rows
        )
        return row * columns + column
    }

    private static func clampedIndex(_ value: CGFloat, count: Int) -> Int {
        guard value.isFinite else { return 0 }
        return min(max(Int(value.rounded(.down)), 0), max(count - 1, 0))
    }

    private func width(metrics: PopupGridMetrics) -> CGFloat {
        CGFloat(columns) * metrics.cellWidth + CGFloat(columns - 1) * metrics.spacing + 2 * metrics.padding
    }

    private func height(ofRows rowCount: Int, metrics: PopupGridMetrics) -> CGFloat {
        CGFloat(rowCount) * metrics.cellHeight + CGFloat(rowCount - 1) * metrics.spacing + 2 * metrics.padding
    }
}
