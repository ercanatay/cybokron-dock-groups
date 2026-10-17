import AppKit
import CoreText

/// Everything a rendered tile image depends on. Two groups with equal keys get identical images,
/// which is what `TileImageCache` relies on.
public struct TileRenderKey: Hashable, Sendable {
    public let kind: TileKind
    public let backgroundStyle: TileBackgroundStyle
    public let backgroundColor: TileColor
    public let emoji: String
    /// The apps whose icons a grid tile shows (normalized bundle identifiers, display order);
    /// empty for emoji tiles, whose look doesn't depend on the apps.
    public let iconBundleIdentifiers: [String]
    /// Side of the square image, in points.
    public let pointSize: CGFloat
    /// Pixels per point.
    public let scale: CGFloat

    public init(group: DockGroup, pointSize: CGFloat, scale: CGFloat) {
        kind = group.tile.kind
        backgroundStyle = group.tile.backgroundStyle
        backgroundColor = group.tile.backgroundColor
        emoji = group.emoji
        iconBundleIdentifiers = group.tile.kind == .grid
            ? group.apps.prefix(TileGridGeometry.maximumIconCount).map(\.normalizedBundleIdentifier)
            : []
        self.pointSize = pointSize
        self.scale = scale
    }

    /// A grid tile with apps shows their icons; anything else (including a grid tile of an empty
    /// group) shows the emoji.
    public var showsIcons: Bool { kind == .grid && !iconBundleIdentifiers.isEmpty }
}

/// Draws group tiles: the emoji, or a 2×2 / 3×3 grid of app icons, on a rounded square painted
/// with the tile's color and background style.
public enum TileRenderer {
    /// Transparent margin around the rounded square, as a fraction of the image side.
    static let marginFraction: CGFloat = 0.06
    /// Corner radius of the rounded square, as a fraction of its side.
    static let cornerFraction: CGFloat = 0.235
    /// Emoji size, as a fraction of the rounded square's side.
    static let emojiFraction: CGFloat = 0.6

    /// The rounded square inside an image of side `pointSize`.
    public static func shapeRect(pointSize: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
            .insetBy(dx: pointSize * marginFraction, dy: pointSize * marginFraction)
    }

    /// Renders the tile described by `key`. `icons` are the images of the apps in
    /// `key.iconBundleIdentifiers`, in the same order; they are ignored for emoji tiles.
    /// Returns `nil` only when no bitmap could be created.
    public static func render(_ key: TileRenderKey, icons: [NSImage]) -> NSImage? {
        let pixels = Int((key.pointSize * key.scale).rounded())
        guard pixels > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: CGFloat(pixels) / key.pointSize, y: CGFloat(pixels) / key.pointSize)
        context.interpolationQuality = .high
        let shape = shapeRect(pointSize: key.pointSize)

        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        graphics.imageInterpolation = .high
        NSGraphicsContext.current = graphics

        drawBackground(style: key.backgroundStyle, color: key.backgroundColor, in: shape, context: context)
        if key.showsIcons, !icons.isEmpty {
            drawIcons(icons, in: shape)
        } else {
            drawEmoji(key.emoji, in: shape, context: context)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: key.pointSize, height: key.pointSize))
    }

    // MARK: - Background

    private static func drawBackground(style: TileBackgroundStyle, color: TileColor, in shape: CGRect, context: CGContext) {
        let radius = shape.width * cornerFraction
        let path = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let base = RGB(color)
        let lineWidth = max(shape.width * 0.012, 0.5)

        context.saveGState()
        context.addPath(path)
        context.clip()
        switch style {
        case .solid:
            context.setFillColor(base.cgColor())
            context.fill(shape)
        case .gradient:
            // Light from the top left, deeper toward the bottom right.
            drawGradient(
                [base.mixed(with: .white, amount: 0.32).cgColor(), base.mixed(with: .black, amount: 0.3).cgColor()],
                from: CGPoint(x: shape.minX, y: shape.maxY),
                to: CGPoint(x: shape.maxX, y: shape.minY),
                context: context
            )
        case .glass:
            context.setFillColor(base.cgColor(alpha: 0.6))
            context.fill(shape)
            // A sheen over the upper half and a faint shade at the bottom.
            drawGradient(
                [RGB.white.cgColor(alpha: 0.42), RGB.white.cgColor(alpha: 0)],
                from: CGPoint(x: shape.midX, y: shape.maxY),
                to: CGPoint(x: shape.midX, y: shape.midY),
                context: context
            )
            drawGradient(
                [RGB.black.cgColor(alpha: 0), RGB.black.cgColor(alpha: 0.14)],
                from: CGPoint(x: shape.midX, y: shape.midY),
                to: CGPoint(x: shape.midX, y: shape.minY),
                context: context
            )
        }
        context.restoreGState()

        // An inner edge keeps the tile distinct on backgrounds of a similar color.
        let edgeInset = lineWidth / 2
        let edgeRect = shape.insetBy(dx: edgeInset, dy: edgeInset)
        let edgeRadius = max(radius - edgeInset, 0)
        context.addPath(CGPath(roundedRect: edgeRect, cornerWidth: edgeRadius, cornerHeight: edgeRadius, transform: nil))
        context.setStrokeColor(RGB.white.cgColor(alpha: style == .glass ? 0.38 : 0.16))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    private static func drawGradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint, context: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])
        else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: - Content

    private static func drawIcons(_ icons: [NSImage], in shape: CGRect) {
        let frames = TileGridGeometry.iconFrames(iconCount: icons.count, in: shape)
        for (icon, frame) in zip(icons, frames) {
            icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private static func drawEmoji(_ emoji: String, in shape: CGRect, context: CGContext) {
        guard !emoji.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: shape.height * emojiFraction),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): RGB.white.cgColor(),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: attributes))
        context.textMatrix = .identity
        var bounds = CTLineGetImageBounds(line, context)
        if bounds.isNull || bounds.isEmpty {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            bounds = CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
        }
        // Center the glyph's ink, not its line box, so emoji sit in the visual middle.
        context.textPosition = CGPoint(x: shape.midX - bounds.midX, y: shape.midY - bounds.midY)
        CTLineDraw(line, context)
    }
}

/// An sRGB color with components in 0...1, for blending tile colors.
private struct RGB {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let white = RGB(red: 1, green: 1, blue: 1)
    static let black = RGB(red: 0, green: 0, blue: 0)

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: TileColor) {
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    func mixed(with other: RGB, amount: CGFloat) -> RGB {
        RGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
