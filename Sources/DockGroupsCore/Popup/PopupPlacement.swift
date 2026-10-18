import CoreGraphics

/// The screen edge the Dock sits on.
public enum DockEdge: String, CaseIterable, Sendable {
    case bottom
    case left
    case right

    /// Uses the Dock's `orientation` preference when it is known; otherwise infers the edge from
    /// the space the Dock takes away from the screen, defaulting to the bottom (where a hidden Dock
    /// usually is).
    public init(orientation: String?, screen: ScreenGeometry) {
        if let orientation, let edge = DockEdge(rawValue: orientation) {
            self = edge
            return
        }
        let widest = DockEdge.allCases.max { $0.inset(on: screen) < $1.inset(on: screen) } ?? .bottom
        self = widest.inset(on: screen) > Self.insetTolerance ? widest : .bottom
    }

    /// Insets smaller than this are rounding noise, not a Dock.
    static let insetTolerance: CGFloat = 0.5

    /// How much of `screen` the Dock covers on this edge; 0 when it's hidden or elsewhere.
    public func inset(on screen: ScreenGeometry) -> CGFloat {
        let frame = screen.frame
        let visible = screen.visibleFrame
        switch self {
        case .bottom: return max(visible.minY - frame.minY, 0)
        case .left: return max(visible.minX - frame.minX, 0)
        case .right: return max(frame.maxX - visible.maxX, 0)
        }
    }
}

/// A screen's full frame and the part not covered by the menu bar and the Dock, in global
/// coordinates with the origin at the bottom left (as `NSScreen` reports them).
public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// What a popup was opened from. With `PopupAnchor.dockIcon` the popup opens at the clicked icon;
/// opened without one — a global shortcut, a link, Siri, a button in a window — it's centered over
/// the Dock.
public enum PopupSource: Equatable, Sendable {
    /// No icon was clicked.
    case unspecified
    /// A standalone group's Dock tile: its center, or the clicked point on it, in global coordinates.
    case dockTile(CGPoint)
    /// The menu bar item, whose menu the group was chosen from: its frame in global coordinates.
    case menuBarItem(CGRect)

    /// The point that decides the popup's screen; `nil` without an icon.
    public var location: CGPoint? {
        switch self {
        case .unspecified: return nil
        case .dockTile(let point): return point
        case .menuBarItem(let frame): return CGPoint(x: frame.midX, y: frame.midY)
        }
    }
}

/// Where the popup panel goes on screen.
public enum PopupPlacement {
    /// Space between the Dock and the popup.
    public static let dockGap: CGFloat = 10
    /// Space between the menu bar and a popup hanging from its item.
    public static let menuBarGap: CGFloat = 4
    /// Minimum space between the popup and the edges of the usable screen area.
    public static let screenMargin: CGFloat = 8
    /// How far from a screen's Dock edge a click still counts as a click on a Dock tile, when the
    /// Dock takes less space than that: room for a Dock that hides until the pointer reaches it,
    /// and for magnified tiles.
    public static let dockTileReach: CGFloat = 160

    /// The screen showing the Dock: the first one the Dock takes space from, else the one under the
    /// pointer (a hidden Dock appears where the pointer is), else the first screen.
    public static func dockScreenIndex(edge: DockEdge, screens: [ScreenGeometry], mouseLocation: CGPoint?) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let index = screens.firstIndex(where: { edge.inset(on: $0) > DockEdge.insetTolerance }) {
            return index
        }
        if let mouseLocation, let index = screens.firstIndex(where: { $0.frame.contains(mouseLocation) }) {
            return index
        }
        return 0
    }

    /// The screen the popup opens on: for `.dockIcon`, the one showing the clicked icon (each
    /// display can have its own Dock and menu bar); otherwise, or without an icon on any screen, the
    /// Dock's (`dockScreenIndex`).
    public static func screenIndex(
        anchor: PopupAnchor,
        source: PopupSource,
        edge: DockEdge,
        screens: [ScreenGeometry],
        mouseLocation: CGPoint?
    ) -> Int? {
        if anchor == .dockIcon, let location = source.location,
           let index = screens.firstIndex(where: { $0.frame.contains(location) }) {
            return index
        }
        return dockScreenIndex(edge: edge, screens: screens, mouseLocation: mouseLocation)
    }

    /// A click at `pointer` as the source of a popup: a Dock tile when the pointer is over the
    /// Dock — within the Dock's inset, or `dockTileReach` if that's more, of the Dock edge of the
    /// screen under it — and `.unspecified` anywhere else (the app was opened some other way).
    public static func dockTileSource(pointer: CGPoint, edge: DockEdge, screens: [ScreenGeometry]) -> PopupSource {
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) else { return .unspecified }
        let reach = max(edge.inset(on: screen), dockTileReach)
        let frame = screen.frame
        let distance: CGFloat
        switch edge {
        case .bottom: distance = pointer.y - frame.minY
        case .left: distance = pointer.x - frame.minX
        case .right: distance = frame.maxX - pointer.x
        }
        return distance <= reach ? .dockTile(pointer) : .unspecified
    }

    /// The largest popup size that fits the usable area of `screen` next to the Dock.
    public static func maximumSize(on screen: ScreenGeometry) -> CGSize {
        let visible = screen.visibleFrame
        return CGSize(
            width: max(visible.width - 2 * screenMargin, 0),
            height: max(visible.height - 2 * screenMargin - dockGap, 0)
        )
    }

    /// The popup's frame. `.dockCenter` centers it over the Dock. `.dockIcon` centers it on the
    /// clicked icon: over the Dock at a Dock tile, or hanging from the menu bar under its item. An
    /// icon that isn't on `screen` (a menu bar item hidden behind the notch, say) counts as none,
    /// and without one `.dockIcon` centers over the Dock too. The result always lies within the
    /// screen's usable area.
    public static func frame(
        size: CGSize,
        anchor: PopupAnchor,
        dockEdge: DockEdge,
        screen: ScreenGeometry,
        source: PopupSource = .unspecified
    ) -> CGRect {
        let visible = screen.visibleFrame
        let bounds = visible.insetBy(dx: screenMargin, dy: screenMargin)
        let isIconOnScreen = source.location.map { screen.frame.contains($0) } ?? false
        let source = anchor == .dockIcon && isIconOnScreen ? source : .unspecified

        if case .menuBarItem(let item) = source {
            let top = min(item.minY, visible.maxY) - menuBarGap
            let rect = CGRect(x: item.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
            var belowMenuBar = bounds
            belowMenuBar.size.height = max(top - bounds.minY, 0)
            return clamp(rect, into: belowMenuBar)
        }

        let focus = source.location
        let origin: CGPoint
        switch dockEdge {
        case .bottom:
            let midX = focus?.x ?? screen.frame.midX
            origin = CGPoint(x: midX - size.width / 2, y: visible.minY + dockGap)
        case .left:
            let midY = focus?.y ?? screen.frame.midY
            origin = CGPoint(x: visible.minX + dockGap, y: midY - size.height / 2)
        case .right:
            let midY = focus?.y ?? screen.frame.midY
            origin = CGPoint(x: visible.maxX - dockGap - size.width, y: midY - size.height / 2)
        }
        return clamp(CGRect(origin: origin, size: size), into: bounds)
    }

    /// Moves `rect` inside `bounds`. A rect larger than `bounds` is aligned with its left and top
    /// edges, so the popup's header stays visible.
    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        result.origin.y = min(bounds.maxY - rect.height, max(rect.minY, bounds.minY))
        return result
    }
}
