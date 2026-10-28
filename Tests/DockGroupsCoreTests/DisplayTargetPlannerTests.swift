import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("DisplayTargetPlanner RED→GREEN")
struct DisplayTargetPlannerTests {
    private let hint = WindowLayoutDocument.DisplaySize(width: 1920, height: 1080)
    private let goodFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let otherFrame = CGRect(x: 100, y: 100, width: 3840, height: 2160)

    // MARK: - Stub / compilation verification (already green after impl)

    @Test func compilesAndReturnsPlanForExactMatch() {
        let candidate = DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [candidate]
        )
        #expect(result != nil)
        // proposedIndex is the array offset (0), not a caller-controlled identity.
        #expect(result?.proposedIndex == 0)
        #expect(result?.isPrimaryProposed == true)
        #expect(result?.reason == .exactMatch(hintSize: CGSize(width: 1920, height: 1080)))
    }

    // MARK: - Fail closed: input validity

    @Test func emptyArrayRejected() {
        #expect(DisplayTargetPlanner.plan(relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5), captureHint: hint, candidates: []) == nil)
    }

    @Test func oversizedArrayRejected() {
        let big = Array(repeating: DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: false), count: DisplayTargetPlanner.maximumCandidateCount + 1)
        // Need exactly one primary; adjust last
        var arr = big
        arr[arr.count - 1] = DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
        #expect(DisplayTargetPlanner.plan(relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5), captureHint: hint, candidates: arr) == nil)
    }

    @Test func noPrimaryRejected() {
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: false)]
        ) == nil)
    }

    @Test func twoPrimariesRejected() {
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true),
                DisplayTargetPlanner.Candidate(visibleFrame: otherFrame, isPrimary: true)
            ]
        ) == nil)
    }

    // MARK: - Primary invalid / unavailable geometry

    @Test func primaryInvalidFrameRejected() {
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: CGRect(x: 0, y: 0, width: 0, height: 1080), isPrimary: true)
            ]
        ) == nil)
    }

    @Test func nonfiniteVisibleFrameRejected() {
        for bad in [
            CGRect(x: CGFloat.nan, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: -CGFloat.infinity)
        ] {
            #expect(DisplayTargetPlanner.plan(
                relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.3, height: 0.3),
                captureHint: hint,
                candidates: [DisplayTargetPlanner.Candidate(visibleFrame: bad, isPrimary: true)]
            ) == nil)
        }
    }

    // MARK: - Capture hint invalid

    @Test func nonpositiveHintRejected() {
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: WindowLayoutDocument.DisplaySize(width: 0, height: 100),
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        ) == nil)
    }

    @Test func nonfiniteHintRejected() {
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: WindowLayoutDocument.DisplaySize(width: CGFloat.nan, height: 1080),
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        ) == nil)
    }

    // MARK: - All invalid CGRect forms in array

    @Test func allInvalidRectFormsRejected() {
        let badFrames: [CGRect] = [
            CGRect(x: 0, y: 0, width: -100, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -100),
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)
        ]
        for bad in badFrames {
            #expect(DisplayTargetPlanner.plan(
                relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.3, height: 0.3),
                captureHint: hint,
                candidates: [
                    DisplayTargetPlanner.Candidate(visibleFrame: bad, isPrimary: true),
                    DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: false)
                ]
            ) == nil)
        }
    }

    // MARK: - Negative coordinates are allowed when size positive

    @Test func negativeOriginAllowedWhenPositiveSize() {
        let negativeFrame = CGRect(x: -100, y: -200, width: 1920, height: 1080)
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1),
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: negativeFrame, isPrimary: true)]
        )
        #expect(result != nil)
        #expect(result?.proposedFrame.origin.x == -100)
    }

    // MARK: - Collapsed-edge display rejected at huge coordinates
    // A CGRect may have positive raw size (width > 0, height > 0) yet maxX == minX
    // at huge coordinate due to double rounding (e.g., minX = 1e16, width = 1 rounds
    // back to the same value). Even when such a display is not selected, the planner
    // rejects the whole array because every entry must represent a meaningful visible
    // area; a collapsed edge implies zero span and cannot support restore.

    @Test func collapsedEdgeAtHugeCoordinateRejectedEvenWhenNotSelected() {
        // Huge origin where positive width rounds back to same minX.
        let hugeCollapsed = CGRect(x: 1e16, y: 0, width: 1, height: 1080)
        #expect(hugeCollapsed.size.width > 0)
        #expect(hugeCollapsed.maxX == hugeCollapsed.minX)
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: hugeCollapsed, isPrimary: false),
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
            ]
        ) == nil)
    }

    @Test func collapsedEdgePrimaryRejected() {
        let hugeCollapsed = CGRect(x: 1e16, y: 100, width: 1, height: 1080)
        #expect(hugeCollapsed.maxX == hugeCollapsed.minX)
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: hugeCollapsed, isPrimary: true)]
        ) == nil)
    }

    // MARK: - No match (missing hint)

    @Test func noMatchProposesPrimaryWithMissingReason() {
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: otherFrame, isPrimary: true)
            ]
        )
        #expect(result != nil)
        #expect(result?.proposedIndex == 0)
        #expect(result?.isPrimaryProposed == true)
        #expect(result?.reason == .missingHint)
    }

    // MARK: - One match

    @Test func oneMatchProposesMatchedDisplay() {
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: otherFrame, isPrimary: false),
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
            ]
        )
        #expect(result != nil)
        #expect(result?.proposedIndex == 1)
        #expect(result?.isPrimaryProposed == true) // primary also matches
        #expect(result?.reason == .exactMatch(hintSize: CGSize(width: 1920, height: 1080)))
        #expect(result?.targetFrame.width == 960)
    }

    // MARK: - Exactly one dimension match on a NON-primary display with negative origin;
    // restore keeps the target wholly inside that display.

    @Test func oneDimensionMatchOnNonPrimaryWithNegativeOriginTargetInside() {
        let nonPrimaryMatch = CGRect(x: -500, y: -300, width: 1920, height: 1080)
        let primaryNoMatch = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: nonPrimaryMatch, isPrimary: false),
                DisplayTargetPlanner.Candidate(visibleFrame: primaryNoMatch, isPrimary: true)
            ]
        )
        #expect(result != nil)
        #expect(result?.proposedIndex == 0)
        #expect(result?.isPrimaryProposed == false)
        #expect(result?.reason == .exactMatch(hintSize: CGSize(width: 1920, height: 1080)))
        #expect(result?.targetFrame != nil)
        let target = result!.targetFrame
        #expect(target.minX >= nonPrimaryMatch.minX)
        #expect(target.minY >= nonPrimaryMatch.minY)
        #expect(target.maxX <= nonPrimaryMatch.maxX)
        #expect(target.maxY <= nonPrimaryMatch.maxY)
    }

    // MARK: - Two matches (duplicate dimensions) -> ambiguous

    @Test func twoMatchesAmbiguousProposesPrimaryWithReason() {
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: false),
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
            ]
        )
        #expect(result != nil)
        #expect(result?.proposedIndex == 1)
        #expect(result?.isPrimaryProposed == true)
        if case .ambiguousMatch(let count, let sz) = result?.reason {
            #expect(count == 2)
            #expect(sz.width == 1920 && sz.height == 1080)
        } else {
            Issue.record("expected ambiguousMatch")
        }
    }

    // MARK: - Malformed relative geometry (restore failure => nil)

    @Test func malformedGeometryReturnsNil() {
        // Restore fails when relative width > maximum relative dimension.
        let hugeRel = RelativeWindowFrame(x: 0, y: 0, width: 3, height: 0.5)
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: hugeRel,
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        ) == nil)
    }

    // MARK: - Restore clamps; no out-of-bounds results

    @Test func restoreClampsInsideVisibleFrameNoOutOfBounds() throws {
        // A partially offscreen but capturable geometry (at least half visible); restore clamps
        // the overshooting origin back into the visible frame.
        let result = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: -0.2, y: -0.2, width: 1.2, height: 1.2),
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        )
        let plan = try #require(result)
        #expect(plan.targetFrame.minX >= 0)
        #expect(plan.targetFrame.minY >= 0)
        #expect(plan.targetFrame.maxX <= 1920)
        #expect(plan.targetFrame.maxY <= 1080)
    }

    // MARK: - Array offset is the exact array used for planning

    @Test func proposedIndexIsArrayOffsetNotCallerIndex() {
        // The planner uses the array offset directly; reordering changes
        // the proposedIndex without altering any Candidate identity.
        let r = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.2, y: 0.3, width: 0.4, height: 0.4),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
            ]
        )
        #expect(r?.proposedIndex == 0)
        let r2 = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0.2, y: 0.3, width: 0.4, height: 0.4),
            captureHint: hint,
            candidates: [
                DisplayTargetPlanner.Candidate(visibleFrame: otherFrame, isPrimary: false),
                DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)
            ]
        )
        #expect(r2?.proposedIndex == 1)
    }

    // MARK: - Security review: malformed far-offscreen geometry rejected; legitimate partial offscreen accepted

    @Test func farOffscreenFiniteOriginRejected() {
        // Geometry with far-offscreen origin that restore clamps but could never have
        // been captured with at least half visible.
        let malformed = RelativeWindowFrame(x: 100, y: 0, width: 0.5, height: 0.5)
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: malformed,
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        ) == nil)
    }

    @Test func legitimatePartiallyOffscreenCaptureAccepted() {
        // At least half the window is inside the display; capture can produce this.
        let partial = RelativeWindowFrame(x: -0.2, y: -0.2, width: 0.8, height: 0.8)
        #expect(DisplayTargetPlanner.plan(
            relativeFrame: partial,
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        ) != nil)
    }

    // MARK: - Size equality is only a hint; physical identity not claimed

    @Test func matchDoesNotImplyPhysicalIdentity() {
        let r = DisplayTargetPlanner.plan(
            relativeFrame: RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            captureHint: hint,
            candidates: [DisplayTargetPlanner.Candidate(visibleFrame: goodFrame, isPrimary: true)]
        )
        #expect(r != nil)
        // No claim of screen serial/name/identity in Plan.
        #expect(r?.proposedFrame == goodFrame)
    }

}
