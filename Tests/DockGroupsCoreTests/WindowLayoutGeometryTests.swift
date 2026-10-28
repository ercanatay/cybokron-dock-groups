import CoreGraphics
import Testing
@testable import DockGroupsCore

@Suite("Window layout capture")
struct WindowLayoutCaptureTests {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func fullyVisibleWindowIsStoredRelativeToTheVisibleFrame() {
        let captured = WindowLayoutGeometry.capture(
            window: CGRect(x: 250, y: 200, width: 500, height: 400),
            in: visibleFrame
        )

        #expect(captured == RelativeWindowFrame(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test func offsetsAreMeasuredFromAVisibleFrameWithANegativeOrigin() {
        let visible = CGRect(x: -1440, y: -200, width: 1000, height: 800)

        let captured = WindowLayoutGeometry.capture(
            window: CGRect(x: -1190, y: 0, width: 500, height: 400),
            in: visible
        )

        #expect(captured == RelativeWindowFrame(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test func windowWithExactlyHalfItsAreaInsideIsCaptured() {
        let captured = WindowLayoutGeometry.capture(
            window: CGRect(x: -300, y: 0, width: 600, height: 100),
            in: visibleFrame
        )

        #expect(captured == RelativeWindowFrame(x: -0.3, y: 0, width: 0.6, height: 0.125))
    }

    @Test func windowWithLessThanHalfItsAreaInsideIsSkipped() {
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: -301, y: 0, width: 600, height: 100),
            in: visibleFrame
        ) == nil)
    }

    @Test func windowWithAQuarterOfItsAreaInsideIsSkipped() {
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: -750, y: 0, width: 1000, height: 100),
            in: visibleFrame
        ) == nil)
    }

    @Test func windowTouchingOrOutsideTheVisibleFrameIsSkipped() {
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: 1000, y: 0, width: 100, height: 100),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: -200, y: 0, width: 200, height: 100),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: 0, y: 800, width: 400, height: 100),
            in: visibleFrame
        ) == nil)
    }

    @Test func partlyOffscreenWindowKeepsItsNegativeOriginAndOversizedHeight() {
        let captured = WindowLayoutGeometry.capture(
            window: CGRect(x: -50, y: -20, width: 600, height: 900),
            in: visibleFrame
        )

        #expect(captured == RelativeWindowFrame(x: -0.05, y: -0.025, width: 0.6, height: 1.125))
    }

    @Test func windowLargerThanTheVisibleFrameIsCapturedUncropped() {
        let captured = WindowLayoutGeometry.capture(
            window: CGRect(x: -100, y: -100, width: 1200, height: 1000),
            in: visibleFrame
        )

        #expect(captured == RelativeWindowFrame(x: -0.1, y: -0.125, width: 1.2, height: 1.25))
    }

    @Test func zeroOrNegativeWindowSizesAreRejected() {
        let origin = CGPoint(x: 250, y: 200)
        for size in [
            CGSize(width: 0, height: 100),
            CGSize(width: 100, height: 0),
            CGSize(width: -100, height: 100),
            CGSize(width: 100, height: -100),
        ] {
            #expect(WindowLayoutGeometry.capture(window: CGRect(origin: origin, size: size), in: visibleFrame) == nil)
        }
    }

    @Test func nonfiniteWindowValuesAreRejected() {
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: 0, y: 0, width: 100, height: -CGFloat.infinity),
            in: visibleFrame
        ) == nil)
    }

    @Test func degenerateOrNonfiniteVisibleFramesAreRejected() {
        let window = CGRect(x: 250, y: 200, width: 500, height: 400)
        for visible in [
            CGRect(x: 0, y: 0, width: 0, height: 800),
            CGRect(x: 0, y: 0, width: 1000, height: -800),
            CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 800),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800),
        ] {
            #expect(WindowLayoutGeometry.capture(window: window, in: visible) == nil)
        }
    }

    @Test func extremeCoordinatesAreRejectedWithoutTrapping() {
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: -CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.capture(
            window: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 100, height: 100),
            in: visibleFrame
        ) == nil)
    }
}

@Suite("Window layout restore")
struct WindowLayoutRestoreTests {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func aCapturedWindowRestoresToItsOriginalFrame() {
        let window = CGRect(x: 250, y: 200, width: 500, height: 400)
        let restored = WindowLayoutGeometry.capture(window: window, in: visibleFrame)
            .flatMap { WindowLayoutGeometry.restore($0, in: visibleFrame) }

        #expect(restored == window)
    }

    @Test func aRelativeFrameMapsIntoAVisibleFrameWithANegativeOrigin() {
        let visible = CGRect(x: -1440, y: -200, width: 1000, height: 800)

        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1),
            in: visible
        ) == visible)
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.25, y: 0.125, width: 0.5, height: 0.25),
            in: visible
        ) == CGRect(x: -1190, y: -100, width: 500, height: 200))
    }

    @Test func aSmallerDisplayTopologyScalesTheFrameDown() {
        let smaller = CGRect(x: 0, y: 0, width: 500, height: 400)

        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: smaller
        ) == CGRect(x: 125, y: 100, width: 250, height: 200))
    }

    @Test func oversizedTargetDimensionsShrinkToTheVisibleFrame() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.1, y: 0.1, width: 1.5, height: 1.25),
            in: visibleFrame
        ) == visibleFrame)
    }

    @Test func anOversizedAxisShrinksWithoutShrinkingTheOther() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.2, y: 0.25, width: 1.5, height: 0.5),
            in: visibleFrame
        ) == CGRect(x: 0, y: 200, width: 1000, height: 400))
    }

    @Test func aPartlyOffscreenCaptureRestoresWhollyInside() {
        let restored = WindowLayoutGeometry.capture(
            window: CGRect(x: -50, y: -20, width: 600, height: 900),
            in: visibleFrame
        ).flatMap { WindowLayoutGeometry.restore($0, in: visibleFrame) }

        #expect(restored == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test func anOffscreenOriginIsClampedWithItsSizeKept() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.95, y: 0.95, width: 0.1, height: 0.1),
            in: visibleFrame
        ) == CGRect(x: 900, y: 720, width: 100, height: 80))
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: -0.2, y: -0.1, width: 0.1, height: 0.1),
            in: visibleFrame
        ) == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func anUnusuallyLargeFiniteOriginIsClampedInside() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 1_000_000, y: -1_000_000, width: 0.5, height: 0.5),
            in: visibleFrame
        ) == CGRect(x: 500, y: 0, width: 500, height: 400))
    }

    @Test func anOriginTooLargeToMapIsRejected() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: .greatestFiniteMagnitude, y: 0, width: 0.5, height: 0.5),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: -.greatestFiniteMagnitude, width: 0.5, height: 0.5),
            in: visibleFrame
        ) == nil)
    }

    @Test func tinyFramesHaveNoMinimumSize() {
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        guard let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0.0005, y: 0.0005, width: 0.0005, height: 0.0005),
            in: wide
        ) else {
            Issue.record("a finite tiny relative frame should restore")
            return
        }

        #expect(abs(restored.minX - 1) < 1e-9)
        #expect(abs(restored.minY - 0.5) < 1e-9)
        #expect(abs(restored.width - 1) < 1e-9)
        #expect(abs(restored.height - 0.5) < 1e-9)
    }

    @Test func aShrunkVisibleFrameKeepsTheRestoredWindowInside() {
        let shrunk = CGRect(x: 0, y: 100, width: 1000, height: 700)
        let restored = WindowLayoutGeometry.capture(
            window: CGRect(x: 250, y: 200, width: 500, height: 400),
            in: visibleFrame
        ).flatMap { WindowLayoutGeometry.restore($0, in: shrunk) }

        #expect(restored == CGRect(x: 250, y: 275, width: 500, height: 350))
        if let restored {
            #expect(shrunk.contains(restored))
        }
    }

    @Test func aWindowExactlyTwiceTheVisibleWidthRoundTripsToTheVisibleFrame() {
        let window = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let captured = WindowLayoutGeometry.capture(window: window, in: visibleFrame)

        #expect(captured == RelativeWindowFrame(x: 0, y: 0, width: 2, height: 1))
        #expect(captured.flatMap { WindowLayoutGeometry.restore($0, in: visibleFrame) } == visibleFrame)
    }

    @Test func nonfiniteRelativeValuesAreRejected() {
        for frame in [
            RelativeWindowFrame(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: CGFloat.infinity, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: CGFloat.infinity, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: CGFloat.nan),
        ] {
            #expect(WindowLayoutGeometry.restore(frame, in: visibleFrame) == nil)
        }
    }

    @Test func nonpositiveRelativeDimensionsAreRejected() {
        for frame in [
            RelativeWindowFrame(x: 0, y: 0, width: 0, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0),
            RelativeWindowFrame(x: 0, y: 0, width: -0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: -1),
        ] {
            #expect(WindowLayoutGeometry.restore(frame, in: visibleFrame) == nil)
        }
    }

    @Test func relativeDimensionsBeyondWhatACaptureCanProduceAreRejected() {
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 2.5, height: 1),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 1, height: 2.5),
            in: visibleFrame
        ) == nil)
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 2, height: 1),
            in: visibleFrame
        ) == visibleFrame)
    }

    @Test func degenerateOrNonfiniteVisibleFramesAreRejected() {
        let frame = RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5)
        for visible in [
            CGRect(x: 0, y: 0, width: 0, height: 800),
            CGRect(x: 0, y: 0, width: 1000, height: -800),
            CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 800),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800),
        ] {
            #expect(WindowLayoutGeometry.restore(frame, in: visible) == nil)
        }
    }
}

/// Restore at the edge of what `CGRect`'s components can represent: an origin plus a size can round
/// past a visible frame's far edge, and a visible frame can be too narrow to hold distinct endpoints.
@Suite("Window layout restore at unrepresentable edges")
struct WindowLayoutRestoreEdgeTests {
    /// The display the coordinator used: 16.97…e16 wide, with a window whose width leaves almost
    /// exactly its last representable step. (The counterexample's origin `169759730344763650` is not
    /// a `Double`; `169_759_730_344_763_648` is the value it stores, so the arithmetic is the same.)
    private let hugeOffset: CGFloat = 169_759_730_344_763_648
    private let hugeWidth: CGFloat = 5_742_176_080_526.272
    private let hugeRelativeWidth: CGFloat = 4_451_869_344_594.591 / 5_742_176_080_526.272

    /// Every edge a caller reads lies inside `visible`, and the rectangle still spans a positive
    /// extent: adding an origin and a size can collapse both endpoints onto one point.
    private func isWhollyInside(_ rect: CGRect, _ visible: CGRect) -> Bool {
        rect.minX >= visible.minX && rect.maxX <= visible.maxX
            && rect.minY >= visible.minY && rect.maxY <= visible.maxY
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX > rect.minX && rect.maxY > rect.minY
    }

    @Test func anOriginThatWouldRoundPastTheFarXEdgeComesBackInside() {
        let visible = CGRect(x: hugeOffset, y: 0, width: hugeWidth, height: 100)

        let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 1, y: 0, width: hugeRelativeWidth, height: 0.2),
            in: visible
        )

        // One representable step inwards fits, so this is clamped rather than refused.
        #expect(restored != nil)
        if let restored { #expect(isWhollyInside(restored, visible)) }
    }

    @Test func aNegativeOriginThatWouldRoundPastTheFarXEdgeComesBackInside() {
        let visible = CGRect(x: -hugeOffset, y: 0, width: hugeWidth, height: 100)

        let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 1, y: 0, width: hugeRelativeWidth, height: 0.2),
            in: visible
        )

        #expect(restored != nil)
        if let restored { #expect(isWhollyInside(restored, visible)) }
    }

    @Test func anOriginThatWouldRoundPastTheFarYEdgeComesBackInside() {
        let visible = CGRect(x: 0, y: hugeOffset, width: 100, height: hugeWidth)

        let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 1, width: 0.2, height: hugeRelativeWidth),
            in: visible
        )

        #expect(restored != nil)
        if let restored { #expect(isWhollyInside(restored, visible)) }
    }

    @Test func aNegativeOriginThatWouldRoundPastTheFarYEdgeComesBackInside() {
        let visible = CGRect(x: 0, y: -hugeOffset, width: 100, height: hugeWidth)

        let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 1, width: 0.2, height: hugeRelativeWidth),
            in: visible
        )

        #expect(restored != nil)
        if let restored { #expect(isWhollyInside(restored, visible)) }
    }

    @Test func aVisibleFrameTooNarrowToHoldDistinctEndpointsIsRejected() {
        let frame = RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5)

        // 1e16 + 1 rounds back to 1e16, so this frame is a single point however it is read.
        let collapsedX = CGRect(x: 1e16, y: 0, width: 1, height: 100)
        #expect(collapsedX.maxX == collapsedX.minX)
        #expect(WindowLayoutGeometry.restore(frame, in: collapsedX) == nil)

        let collapsedY = CGRect(x: 0, y: 1e16, width: 100, height: 1)
        #expect(collapsedY.maxY == collapsedY.minY)
        #expect(WindowLayoutGeometry.restore(frame, in: collapsedY) == nil)
    }

    @Test func aWindowTooThinToRepresentIsRejectedButAWiderOneOnTheSameFrameRestores() {
        let narrow = CGRect(x: 1e16, y: 0, width: 4, height: 100)

        // 4 × 1e-8 is far below one ulp at 1e16: its endpoints collapse even though the visible
        // frame itself is representable.
        #expect(WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 1e-8, height: 0.5),
            in: narrow
        ) == nil)

        let restored = WindowLayoutGeometry.restore(
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            in: narrow
        )
        #expect(restored != nil)
        if let restored { #expect(isWhollyInside(restored, narrow)) }
    }
}
