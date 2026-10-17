import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The agent's app icon: the group's tile (emoji or app icon grid, in its background style),
/// rendered by `TileRenderer` at every size the Dock and Finder use and packed into an `.icns`.
public enum AgentIcon {
    /// Representations in the `.icns`, as (side in points, scale): 16 to 512 points at 1× and 2×,
    /// which takes 16, 32, 64, 128, 256, 512 and 1024 pixel images.
    static let representations: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]
    /// Image sides rendered for the `.icns`, in pixels.
    public static var pixelSizes: [Int] {
        Array(Set(representations.map { $0.points * $0.scale })).sorted()
    }

    /// Share of the icon's side the tile's rounded square covers, as in macOS app icons (824 of 1024
    /// pixels), so the agent sits in the Dock at the size of the apps around it.
    static let shapeFraction: CGFloat = 824.0 / 1024.0

    /// Whether the two versions of a group have different icons (emoji, background, color, or the
    /// apps a grid tile shows).
    public static func differs(_ group: DockGroup, from other: DockGroup) -> Bool {
        TileRenderKey(group: group, pointSize: 512, scale: 1) != TileRenderKey(group: other, pointSize: 512, scale: 1)
    }

    /// The group's tile as an app icon image, `pixelSize` pixels square.
    /// `icons` are the images of the group's first apps, for grid tiles.
    @MainActor
    public static func image(for group: DockGroup, pixelSize: Int, icons: [NSImage]) -> CGImage? {
        guard pixelSize > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // TileRenderer leaves its own margin around the rounded square; scale the tile so the
        // square ends up `shapeFraction` of the icon.
        let side = CGFloat(pixelSize) * shapeFraction / (1 - 2 * TileRenderer.marginFraction)
        let key = TileRenderKey(group: group, pointSize: side, scale: 1)
        guard let tile = TileRenderer.render(key, icons: key.showsIcons ? icons : []),
              let tileImage = tile.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        context.interpolationQuality = .high
        let origin = (CGFloat(pixelSize) - side) / 2
        context.draw(tileImage, in: CGRect(x: origin, y: origin, width: side, height: side))
        return context.makeImage()
    }

    /// The `.icns` file contents for the group's agent.
    @MainActor
    public static func icnsData(for group: DockGroup, icons: [NSImage]) throws -> Data {
        var images: [Int: CGImage] = [:]
        for size in pixelSizes {
            guard let image = image(for: group, pixelSize: size, icons: icons) else {
                throw AgentInstallError.iconRenderFailed
            }
            images[size] = image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.icns.identifier as CFString,
            representations.count,
            nil
        ) else { throw AgentInstallError.iconRenderFailed }
        for representation in representations {
            guard let image = images[representation.points * representation.scale] else { continue }
            let dpi = 72 * representation.scale
            let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { throw AgentInstallError.iconRenderFailed }
        return data as Data
    }
}
