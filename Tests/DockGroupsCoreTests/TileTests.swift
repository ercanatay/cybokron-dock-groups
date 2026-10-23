import AppKit
import Testing
@testable import DockGroupsCore

@Suite("Tile grid geometry")
struct TileGridGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func twoByTwoUpToFourIconsThenThreeByThree() {
        #expect(TileGridGeometry.dimension(forIconCount: 0) == 0)
        #expect((1...4).map(TileGridGeometry.dimension(forIconCount:)) == [2, 2, 2, 2])
        #expect((5...12).map(TileGridGeometry.dimension(forIconCount:)).allSatisfy { $0 == 3 })
    }

    @Test func showsAtMostNineIcons() {
        #expect(TileGridGeometry.iconFrames(iconCount: 0, in: bounds).isEmpty)
        #expect(TileGridGeometry.iconFrames(iconCount: 3, in: bounds).count == 3)
        #expect(TileGridGeometry.iconFrames(iconCount: 14, in: bounds).count == 9)
    }

    @Test func framesFillRowsFromTheTopLeftWithoutOverlapping() {
        for count in [1, 4, 5, 9] {
            let frames = TileGridGeometry.iconFrames(iconCount: count, in: bounds)
            #expect(frames.allSatisfy { bounds.contains($0) })
            #expect(frames.allSatisfy { $0.width == $0.height && $0.width > 0 })
            for (index, frame) in frames.enumerated() {
                for other in frames[(index + 1)...] {
                    #expect(!frame.intersects(other))
                }
            }
            let first = frames[0]
            #expect(first.minX == frames.map(\.minX).min())
            #expect(first.maxY == frames.map(\.maxY).max())
        }
        let two = TileGridGeometry.iconFrames(iconCount: 2, in: bounds)
        #expect(two[1].minX > two[0].minX && two[1].minY == two[0].minY)
    }

    @Test func gridIsCenteredInNonSquareBounds() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frames = TileGridGeometry.iconFrames(iconCount: 4, in: wide)
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }

        #expect(abs(union.midX - wide.midX) < 0.001)
        #expect(abs(union.midY - wide.midY) < 0.001)
    }
}

@Suite("Tile rendering")
@MainActor
struct TileRendererTests {
    private let red = TileColor(red: 0xD0, green: 0x20, blue: 0x30)

    @Test func emojiTileHasTheRequestedPixelSizeAndTransparentMargin() throws {
        let group = DockGroup(name: "Work", emoji: "🟩", tile: TileAppearance(kind: .emoji, backgroundColor: red))
        let image = try #require(TileRenderer.render(TileRenderKey(group: group, pointSize: 32, scale: 2), icons: []))
        let bitmap = try Bitmap(image)

        #expect(image.size == NSSize(width: 32, height: 32))
        #expect(bitmap.width == 64 && bitmap.height == 64)
        #expect(bitmap.pixel(x: 0, y: 0).alpha == 0)
        // The emoji covers the middle, so the center isn't the plain background.
        #expect(bitmap.pixel(x: 32, y: 32).alpha > 0)
        #expect(!bitmap.pixel(x: 32, y: 32).isClose(to: red))
    }

    @Test func solidBackgroundUsesTheTileColor() throws {
        let group = DockGroup(name: "Work", emoji: "🚀", tile: TileAppearance(kind: .emoji, backgroundStyle: .solid, backgroundColor: red))
        let bitmap = try Bitmap(#require(TileRenderer.render(TileRenderKey(group: group, pointSize: 64, scale: 1), icons: [])))

        // Inside the rounded square, left of the emoji.
        #expect(bitmap.pixel(x: 10, y: 32).isClose(to: red))
    }

    @Test func gradientAndGlassDifferFromSolid() throws {
        func sample(_ style: TileBackgroundStyle) throws -> Bitmap.Pixel {
            let group = DockGroup(name: "Work", tile: TileAppearance(kind: .emoji, backgroundStyle: style, backgroundColor: red))
            let bitmap = try Bitmap(#require(TileRenderer.render(TileRenderKey(group: group, pointSize: 64, scale: 1), icons: [])))
            return bitmap.pixel(x: 10, y: 12)
        }
        let solid = try sample(.solid)
        #expect(try sample(.gradient) != solid)
        #expect(try sample(.glass) != solid)
    }

    @Test func gridTileDrawsTheAppIcons() throws {
        let apps = [AppReference(bundleIdentifier: "com.example.a", name: "A"), AppReference(bundleIdentifier: "com.example.b", name: "B")]
        let group = DockGroup(name: "Grid", apps: apps, tile: TileAppearance(kind: .grid, backgroundColor: TileColor(red: 0, green: 0, blue: 0)))
        let key = TileRenderKey(group: group, pointSize: 100, scale: 1)
        let green = TileColor(red: 0x10, green: 0xC0, blue: 0x40)
        let bitmap = try Bitmap(#require(TileRenderer.render(key, icons: [.filled(green), .filled(green)])))

        let firstFrame = TileGridGeometry.iconFrames(iconCount: 2, in: TileRenderer.shapeRect(pointSize: 100))[0]
        // Bitmap rows run top to bottom; tile frames bottom to top.
        #expect(bitmap.pixel(x: Int(firstFrame.midX), y: 100 - Int(firstFrame.midY)).isClose(to: green))
    }

    @Test func gridTileOfAnEmptyGroupShowsTheEmoji() {
        let group = DockGroup(name: "Empty", emoji: "🎧", tile: TileAppearance(kind: .grid))
        let key = TileRenderKey(group: group, pointSize: 32, scale: 1)

        #expect(!key.showsIcons)
        #expect(key.iconBundleIdentifiers.isEmpty)
    }

    @Test func renderKeyOfAnEmojiTileIgnoresTheApps() {
        var group = DockGroup(name: "Work", tile: TileAppearance(kind: .emoji))
        let before = TileRenderKey(group: group, pointSize: 18, scale: 2)
        group.apps = [AppReference(bundleIdentifier: "com.example.a", name: "A")]

        #expect(TileRenderKey(group: group, pointSize: 18, scale: 2) == before)
    }
}

@Suite("Tile image cache")
@MainActor
struct TileImageCacheTests {
    private func countingCache() -> TileImageCache {
        TileImageCache(scale: 1) { key, _ in NSImage(size: NSSize(width: key.pointSize, height: key.pointSize)) }
    }

    @Test func reusesTheImageUntilTheTileChanges() {
        let cache = countingCache()
        var group = DockGroup(name: "Work", emoji: "💼")

        let first = cache.image(for: group, pointSize: 18)
        #expect(cache.image(for: group, pointSize: 18) === first)
        #expect(cache.renderCount == 1)

        group.name = "Renamed"
        _ = cache.image(for: group, pointSize: 18)
        #expect(cache.renderCount == 1)

        group.emoji = "🎨"
        #expect(cache.image(for: group, pointSize: 18) !== first)
        #expect(cache.renderCount == 2)

        group.tile.backgroundColor = TileColor(red: 1, green: 2, blue: 3)
        _ = cache.image(for: group, pointSize: 18)
        #expect(cache.renderCount == 3)
    }

    @Test func gridTilesFollowTheFirstNineApps() {
        let cache = countingCache()
        let apps = (1...10).map { AppReference(bundleIdentifier: "com.example.app\($0)", name: "App \($0)") }
        var group = DockGroup(name: "Grid", apps: Array(apps.prefix(9)), tile: TileAppearance(kind: .grid))

        _ = cache.image(for: group, pointSize: 18)
        group.apps.append(apps[9])
        _ = cache.image(for: group, pointSize: 18)
        #expect(cache.renderCount == 1)

        group.apps.swapAt(0, 1)
        _ = cache.image(for: group, pointSize: 18)
        #expect(cache.renderCount == 2)
    }

    @Test func sizesAreCachedSeparately() {
        let cache = countingCache()
        let group = DockGroup(name: "Work")

        let small = cache.image(for: group, pointSize: 18)
        let large = cache.image(for: group, pointSize: 64)

        #expect(small.size.width == 18 && large.size.width == 64)
        #expect(cache.renderCount == 2)
        #expect(cache.cachedImageCount == 2)
    }

    @Test func invalidateForcesANewRender() {
        let cache = countingCache()
        let group = DockGroup(name: "Work")
        let other = DockGroup(name: "Other")
        _ = cache.image(for: group, pointSize: 18)
        _ = cache.image(for: other, pointSize: 18)

        cache.invalidate(groupID: group.id)
        _ = cache.image(for: group, pointSize: 18)
        _ = cache.image(for: other, pointSize: 18)

        #expect(cache.renderCount == 3)
    }

    @Test func synchronizeDropsDeletedAndChangedGroups() {
        let cache = countingCache()
        var changed = DockGroup(name: "Changed")
        let unchanged = DockGroup(name: "Unchanged")
        let deleted = DockGroup(name: "Deleted")
        for group in [changed, unchanged, deleted] {
            _ = cache.image(for: group, pointSize: 18)
        }

        changed.tile.kind = .grid
        changed.apps = [AppReference(bundleIdentifier: "com.example.a", name: "A")]
        cache.synchronize(with: [changed, unchanged])

        #expect(cache.cachedImageCount == 1)
        _ = cache.image(for: unchanged, pointSize: 18)
        #expect(cache.renderCount == 3)
    }

    @Test func realRendererUsesTheIconProvider() throws {
        let provider = FakeIconProvider(color: TileColor(red: 0x10, green: 0xC0, blue: 0x40))
        let cache = TileImageCache(iconProvider: provider, scale: 1)
        let apps = (1...3).map { AppReference(bundleIdentifier: "com.example.app\($0)", name: "App \($0)") }
        let group = DockGroup(name: "Grid", apps: apps, tile: TileAppearance(kind: .grid))

        let image = cache.image(for: group, pointSize: 64)

        #expect(provider.requested == apps.map(\.bundleIdentifier))
        #expect(try Bitmap(image).width == 64)
    }
}

// MARK: - Helpers

@MainActor
private final class FakeIconProvider: AppIconProviding {
    private let color: TileColor
    private(set) var requested: [String] = []

    init(color: TileColor) {
        self.color = color
    }

    func icon(for app: AppReference) -> NSImage {
        requested.append(app.bundleIdentifier)
        return .filled(color)
    }

    func icon(for item: GroupItem, presence: ItemPresence) -> NSImage {
        icon(for: item)
    }

    func presence(of item: GroupItem) -> ItemPresence { .online }
}

private extension NSImage {
    static func filled(_ color: TileColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(srgbRed: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }
}

/// An image's pixels as 8-bit sRGB, rows from top to bottom.
private struct Bitmap {
    struct Pixel: Equatable {
        let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8

        func isClose(to color: TileColor, tolerance: Int = 6) -> Bool {
            alpha == 255
                && abs(Int(red) - Int(color.red)) <= tolerance
                && abs(Int(green) - Int(color.green)) <= tolerance
                && abs(Int(blue) - Int(color.blue)) <= tolerance
        }
    }

    struct NoImage: Error {}

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: NSImage) throws {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw NoImage() }
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw NoImage() }
        self.width = width
        self.height = height
        bytes = buffer
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }
}
