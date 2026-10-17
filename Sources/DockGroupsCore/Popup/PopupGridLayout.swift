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

    private func width(metrics: PopupGridMetrics) -> CGFloat {
        CGFloat(columns) * metrics.cellWidth + CGFloat(columns - 1) * metrics.spacing + 2 * metrics.padding
    }

    private func height(ofRows rowCount: Int, metrics: PopupGridMetrics) -> CGFloat {
        CGFloat(rowCount) * metrics.cellHeight + CGFloat(rowCount - 1) * metrics.spacing + 2 * metrics.padding
    }
}
