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

/// Where the popup panel goes on screen.
public enum PopupPlacement {
    /// Space between the Dock and the popup.
    public static let dockGap: CGFloat = 10
    /// Minimum space between the popup and the edges of the usable screen area.
    public static let screenMargin: CGFloat = 8

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

    /// The largest popup size that fits the usable area of `screen` next to the Dock.
    public static func maximumSize(on screen: ScreenGeometry) -> CGSize {
        let visible = screen.visibleFrame
        return CGSize(
            width: max(visible.width - 2 * screenMargin, 0),
            height: max(visible.height - 2 * screenMargin - dockGap, 0)
        )
    }

    /// The popup's frame. `.dockCenter` centers it over the Dock; `.dockIcon` centers it on
    /// `iconLocation` (the clicked Dock tile) and falls back to the Dock's center when that location
    /// is unknown. The result always lies within the screen's usable area.
    public static func frame(
        size: CGSize,
        anchor: PopupAnchor,
        dockEdge: DockEdge,
        screen: ScreenGeometry,
        iconLocation: CGPoint? = nil
    ) -> CGRect {
        let visible = screen.visibleFrame
        let focus = anchor == .dockIcon ? iconLocation : nil
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
        let bounds = visible.insetBy(dx: screenMargin, dy: screenMargin)
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
