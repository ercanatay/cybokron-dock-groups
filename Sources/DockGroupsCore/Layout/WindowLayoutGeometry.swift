import CoreGraphics

/// A window's frame stored relative to a display's visible frame: `x` and `y` are offsets as
/// fractions of the visible frame's width and height, `width` and `height` are fractions of them.
/// `(0, 0, 1, 1)` is exactly the visible frame.
///
/// A partly off-screen window keeps its whole geometry, so an origin can be negative and an axis
/// can be wider than `1`; `capture` never crops a window to the display.
public struct RelativeWindowFrame: Equatable, Hashable, Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Pure geometry for the proposed window layouts (spec H): captures a window's frame relative to a
/// display's visible frame and maps it back onto a visible frame supplied now.
///
/// Assumptions and limits:
/// - Both rectangles are supplied by the caller in one coordinate convention. This utility never
///   queries a screen, a window or Accessibility, and never converts AX top-left and AppKit
///   bottom-left origins; `y` increases in whatever direction the caller's rectangles use.
/// - `capture` returns a frame only when at least half the window's area lies inside the visible
///   frame. It keeps the window's off-screen part in the relative frame instead of cropping it.
/// - `restore` maps the relative frame onto the current visible frame, shrinks a target dimension
///   that is wider or taller than that frame, and clamps the origin so the result lies wholly
///   inside it. It does not assume a minimum window size. A visible frame whose coordinates cannot
///   hold the window's two edges apart returns `nil` rather than a frame that isn't inside it.
/// - Invalid, degenerate or nonfinite input, and arithmetic that would overflow, return `nil`
///   instead of trapping.
///
/// A returned frame is a geometry plan only. It does not identify a window, prove that it is
/// visible or on the current Space, or imply Accessibility permission, and it never authorizes
/// moving anything by itself.
public enum WindowLayoutGeometry {
    /// The share of a window's area that must lie inside a visible frame for it to be captured.
    public static let minimumVisibleFraction: CGFloat = 0.5

    /// The widest or tallest relative dimension a capture can produce: a window with at least half
    /// its area on the display is at most twice the visible frame's size in either axis. Larger
    /// stored values are malformed; `restore` rejects them, allowing one representable step of
    /// rounding slack above this bound.
    public static let maximumRelativeDimension: CGFloat = 2

    /// `window` relative to `visibleFrame`, or `nil` when either rectangle is invalid or less than
    /// `minimumVisibleFraction` of the window is inside the visible frame.
    public static func capture(window: CGRect, in visibleFrame: CGRect) -> RelativeWindowFrame? {
        guard isUsable(window), isUsable(visibleFrame) else { return nil }

        let overlapWidth = min(window.maxX, visibleFrame.maxX) - max(window.minX, visibleFrame.minX)
        let overlapHeight = min(window.maxY, visibleFrame.maxY) - max(window.minY, visibleFrame.minY)
        guard overlapWidth > 0, overlapHeight > 0,
              overlapWidth.isFinite, overlapHeight.isFinite else { return nil }

        // The area fraction is the product of two per-axis fractions of the window. Each is at most
        // 1, so a window and a visible frame never have to be multiplied into an area that could
        // overflow, however large their coordinates are.
        let visibleFraction = (overlapWidth / window.width) * (overlapHeight / window.height)
        guard visibleFraction.isFinite, visibleFraction >= minimumVisibleFraction else { return nil }

        let x = (window.minX - visibleFrame.minX) / visibleFrame.width
        let y = (window.minY - visibleFrame.minY) / visibleFrame.height
        let width = window.width / visibleFrame.width
        let height = window.height / visibleFrame.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }

        return RelativeWindowFrame(x: x, y: y, width: width, height: height)
    }

    /// `frame` mapped onto `visibleFrame`, wholly inside it, or `nil` when either input is invalid,
    /// a calculation would be nonfinite, or the visible frame's coordinates are too coarse to hold
    /// the result's edges apart.
    public static func restore(_ frame: RelativeWindowFrame, in visibleFrame: CGRect) -> CGRect? {
        guard isUsable(visibleFrame),
              frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              // One representable step of slack, so a capture at the exact half-area boundary
              // (twice the visible frame's size) survives the division that produced it.
              frame.width <= maximumRelativeDimension.nextUp,
              frame.height <= maximumRelativeDimension.nextUp else { return nil }

        // An axis at or beyond the visible frame's size is pinned to it instead of overshooting.
        let width = frame.width >= 1 ? visibleFrame.width : frame.width * visibleFrame.width
        let height = frame.height >= 1 ? visibleFrame.height : frame.height * visibleFrame.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

        let rawX = visibleFrame.minX + frame.x * visibleFrame.width
        let rawY = visibleFrame.minY + frame.y * visibleFrame.height
        guard rawX.isFinite, rawY.isFinite else { return nil }

        // Clamp against the space left after the width rather than `maxX - width`, so rounding can
        // never place the origin outside the visible frame.
        let maximumX = visibleFrame.minX + (visibleFrame.width - width)
        let maximumY = visibleFrame.minY + (visibleFrame.height - height)
        var origin = CGPoint(
            x: min(max(rawX, visibleFrame.minX), maximumX),
            y: min(max(rawY, visibleFrame.minY), maximumY)
        )

        // `CGRect.maxX` adds the origin and the width again, and that addition rounds too: an origin
        // clamped against the room the width leaves can still land one step past the visible frame's
        // far edge. Check the edges a caller actually reads, and step an overshooting origin inwards
        // (a couple of representable steps at most). A visible frame too coarse to hold the window's
        // edges apart at all fits no origin, so it is refused rather than returned sticking out.
        let adjustmentSteps = 3
        for step in 0...adjustmentSteps {
            let candidate = CGRect(origin: origin, size: CGSize(width: width, height: height))
            if isWhollyInside(candidate, in: visibleFrame) { return candidate }

            let overshootsX = candidate.maxX > visibleFrame.maxX
            let overshootsY = candidate.maxY > visibleFrame.maxY
            // Only an origin whose far edge rounds past the frame can be nudged in; anything else is
            // an extent these coordinates cannot represent.
            guard step < adjustmentSteps,
                  overshootsX || overshootsY,
                  candidate.minX >= visibleFrame.minX,
                  candidate.minY >= visibleFrame.minY else { return nil }
            if overshootsX { origin.x = origin.x.nextDown }
            if overshootsY { origin.y = origin.y.nextDown }
        }

        return nil
    }

    /// Whether every edge `CGRect` reports lies inside `visibleFrame`, and whether the size still
    /// spans a positive extent. Adding an origin and a size can collapse both endpoints onto one
    /// point when consecutive values are further apart than the size.
    private static func isWhollyInside(_ rect: CGRect, in visibleFrame: CGRect) -> Bool {
        rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX > rect.minX && rect.maxY > rect.minY
            && rect.minX >= visibleFrame.minX && rect.maxX <= visibleFrame.maxX
            && rect.minY >= visibleFrame.minY && rect.maxY <= visibleFrame.maxY
    }

    /// A rectangle whose components are finite and whose width and height are positive. Negative
    /// widths and heights are rejected rather than standardized: `CGRect.width` reports their
    /// absolute value, so the sign is read from `size`.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width.isFinite && rect.size.width > 0
            && rect.size.height.isFinite && rect.size.height > 0
    }
}
