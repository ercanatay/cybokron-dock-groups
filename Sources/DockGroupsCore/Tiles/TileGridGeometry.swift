import CoreGraphics

/// Layout of the app icons on a grid tile: a 2×2 grid for up to four apps, 3×3 for more. Apps
/// beyond the ninth aren't shown on the tile.
public enum TileGridGeometry {
    public static let maximumIconCount = 9

    /// Free space around the icons, as a fraction of the tile's side.
    static let insetFraction: CGFloat = 0.14
    /// Space between icons, as a fraction of the area holding them.
    static let spacingFraction: CGFloat = 0.05

    /// Icons per row and column: 0 without icons, 2 for up to four, 3 above.
    public static func dimension(forIconCount count: Int) -> Int {
        switch count {
        case ...0: return 0
        case 1...4: return 2
        default: return 3
        }
    }

    /// Frames of the first `min(iconCount, 9)` icons inside a tile occupying `bounds`, row by row
    /// from the top left. Coordinates have their origin at the bottom left, as in Core Graphics.
    public static func iconFrames(iconCount: Int, in bounds: CGRect) -> [CGRect] {
        let count = min(iconCount, maximumIconCount)
        let dimension = dimension(forIconCount: count)
        guard dimension > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let side = min(bounds.width, bounds.height)
        let content = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: side * insetFraction, dy: side * insetFraction)
        let spacing = content.width * spacingFraction
        let cell = (content.width - spacing * CGFloat(dimension - 1)) / CGFloat(dimension)

        return (0..<count).map { index in
            let row = index / dimension
            let column = index % dimension
            return CGRect(
                x: content.minX + CGFloat(column) * (cell + spacing),
                y: content.maxY - CGFloat(row + 1) * cell - CGFloat(row) * spacing,
                width: cell,
                height: cell
            )
        }
    }
}
