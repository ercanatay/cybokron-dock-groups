import CoreGraphics
import Foundation

/// Plans where each window of a saved group would go on the displays supplied now (design spec H),
/// for a preview the user confirms before anything moves.
///
/// Side-effect free: it reads no Accessibility attribute, display or file and writes nothing.
/// A target is a geometry proposal only. It does not find a window, prove one exists or is on the
/// current Space, or authorize moving it; a future writer has to recheck all of that.
///
/// Rules:
/// - The group is first run through `WindowLayoutDocument`'s validation; a group that would not be
///   accepted from a file is not planned.
/// - Each window's display is chosen by `DisplayTargetPlanner`: the one display whose visible
///   frame has the captured size, otherwise the primary display (`usesPrimaryFallback`).
/// - The target is `WindowLayoutGeometry.restore` of the stored frame on that visible frame, so it
///   always lies wholly inside it, shrunk if the visible frame is now smaller. It is reported in
///   AppKit coordinates and converted to Accessibility coordinates with the primary display's
///   height; the converted target is checked against the converted visible frame again.
///
/// Privacy: decisions are positional, aligned with `group.windows`; no reason carries a bundle
/// identifier, path or geometry.
enum LayoutRestorePreviewPlanner {
    /// Why no window was planned.
    enum GroupSkipReason: String, Equatable, Sendable {
        case invalidDisplayConfiguration
        case invalidGroup
    }

    /// Why one window has no target.
    enum WindowSkipReason: String, Equatable, Sendable {
        /// `DisplayTargetPlanner` found no usable target for the stored geometry.
        case noTargetGeometry
        case coordinateConversionFailed
        /// The converted target no longer lies inside the converted visible frame.
        case targetOutsideVisibleFrame
    }

    struct Target: Equatable, Sendable {
        /// The proposed display's position in the displays passed in.
        let displayIndex: Int
        /// The captured display size matched no display, or more than one.
        let usesPrimaryFallback: Bool
        let matchReason: DisplayTargetPlanner.MatchReason
        /// The target in AppKit coordinates, inside `displays[displayIndex].visibleFrame`.
        let frame: CGRect
        /// The same target in Accessibility coordinates (top-left origin of the primary display).
        let topLeftFrame: CGRect
    }

    enum WindowDecision: Equatable, Sendable {
        case target(Target)
        case skipped(WindowSkipReason)
    }

    enum Preview: Equatable, Sendable {
        /// One decision per window of the group, in its order.
        case planned([WindowDecision])
        case notPlanned(GroupSkipReason)
    }

    static func preview(group: WindowLayoutDocument.Group, displays: [LayoutDisplay]) -> Preview {
        guard let configuration = LayoutDisplayConfiguration(displays: displays) else {
            return .notPlanned(.invalidDisplayConfiguration)
        }
        guard (try? WindowLayoutDocument(groups: [group])) != nil else { return .notPlanned(.invalidGroup) }

        let candidates = configuration.displays.map {
            DisplayTargetPlanner.Candidate(visibleFrame: $0.visibleFrame, isPrimary: $0.isPrimary)
        }
        return .planned(group.windows.map { window in
            decide(window, candidates: candidates, referenceHeight: configuration.referenceHeight)
        })
    }

    private static func decide(
        _ window: WindowLayoutDocument.Window,
        candidates: [DisplayTargetPlanner.Candidate],
        referenceHeight: CGFloat
    ) -> WindowDecision {
        guard let plan = DisplayTargetPlanner.plan(
            relativeFrame: window.frame, captureHint: window.display, candidates: candidates
        ) else { return .skipped(.noTargetGeometry) }

        guard let topLeftFrame = LayoutCoordinateConversion.convert(plan.targetFrame, referenceHeight: referenceHeight),
              let topLeftVisible = LayoutCoordinateConversion.convert(plan.proposedFrame, referenceHeight: referenceHeight)
        else { return .skipped(.coordinateConversionFailed) }

        guard topLeftFrame.minX >= topLeftVisible.minX, topLeftFrame.maxX <= topLeftVisible.maxX,
              topLeftFrame.minY >= topLeftVisible.minY, topLeftFrame.maxY <= topLeftVisible.maxY
        else { return .skipped(.targetOutsideVisibleFrame) }

        let usesPrimaryFallback: Bool
        if case .exactMatch = plan.reason { usesPrimaryFallback = false } else { usesPrimaryFallback = true }
        return .target(Target(
            displayIndex: plan.proposedIndex,
            usesPrimaryFallback: usesPrimaryFallback,
            matchReason: plan.reason,
            frame: plan.targetFrame,
            topLeftFrame: topLeftFrame
        ))
    }
}
