import AppKit

/// Rendered group tiles, kept per group and size until the group's tile changes.
///
/// A cached image is reused only while its `TileRenderKey` still matches the group, so a stale
/// tile is never returned even without explicit invalidation; `synchronize(with:)` additionally
/// frees the images of changed and deleted groups.
@MainActor
public final class TileImageCache {
    /// Renders the tile for `key`; the group is passed along to look up its apps' icons.
    public typealias Renderer = @MainActor (TileRenderKey, DockGroup) -> NSImage?

    private struct Slot: Hashable {
        let groupID: DockGroup.ID
        let pointSize: CGFloat
    }

    private struct Entry {
        let key: TileRenderKey
        let image: NSImage
    }

    private let scale: CGFloat
    private let renderer: Renderer
    private var entries: [Slot: Entry] = [:]

    /// How many images have been rendered so far (cache misses).
    public private(set) var renderCount = 0
    public var cachedImageCount: Int { entries.count }

    /// - Parameter scale: Pixels per point of the rendered images; 2 keeps tiles sharp on Retina
    ///   displays and downsamples cleanly elsewhere.
    public init(scale: CGFloat = 2, renderer: @escaping Renderer) {
        self.scale = scale
        self.renderer = renderer
    }

    /// A cache rendering with `TileRenderer` and icons from `iconProvider`.
    public convenience init(iconProvider: AppIconProviding, scale: CGFloat = 2) {
        self.init(scale: scale) { [weak iconProvider] key, group in
            let icons = key.showsIcons
                ? group.apps.prefix(TileGridGeometry.maximumIconCount).compactMap { iconProvider?.icon(for: $0) }
                : []
            return TileRenderer.render(key, icons: icons)
        }
    }

    /// The group's tile with a side of `pointSize` points, rendered on first use.
    public func image(for group: DockGroup, pointSize: CGFloat) -> NSImage {
        let key = TileRenderKey(group: group, pointSize: pointSize, scale: scale)
        let slot = Slot(groupID: group.id, pointSize: pointSize)
        if let entry = entries[slot], entry.key == key {
            return entry.image
        }
        renderCount += 1
        let image = renderer(key, group) ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        entries[slot] = Entry(key: key, image: image)
        return image
    }

    /// Forgets every image of one group.
    public func invalidate(groupID: DockGroup.ID) {
        entries = entries.filter { $0.key.groupID != groupID }
    }

    public func removeAll() {
        entries.removeAll()
    }

    /// Drops images of groups that no longer exist or whose tile looks different now.
    public func synchronize(with groups: [DockGroup]) {
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = entries.filter { slot, entry in
            guard let group = groupsByID[slot.groupID] else { return false }
            return TileRenderKey(group: group, pointSize: slot.pointSize, scale: scale) == entry.key
        }
    }
}
