import CoreGraphics

/// Pure, internal display-target planning: no IO, no NSScreen, no AX,
/// no window identity, no motion, no persistence. Inputs are caller-supplied.
///
/// A returned `Plan` is a geometry proposal only; it does not authorize a move,
/// confirm Space/permission/identity, or imply accessibility access.
internal enum DisplayTargetPlanner {
    internal struct Candidate: Equatable, Sendable {
        /// Preview reference only; not a window identity.
        /// The array offset into the `candidates` array passed to `plan` is used
        /// for `Plan.proposedIndex`, so the caller controls ordering but the
        /// planner indexes exactly the same array used for planning.
        public let visibleFrame: CGRect
        public let isPrimary: Bool
        internal init(visibleFrame: CGRect, isPrimary: Bool) {
            self.visibleFrame = visibleFrame; self.isPrimary = isPrimary
        }
    }

    internal enum MatchReason: Equatable, Sendable {
        /// Exactly one display matched the capture hint dimensions.
        case exactMatch(hintSize: CGSize)
        /// Zero displays matched the capture hint dimensions.
        case missingHint
        /// More than one display matched the capture hint dimensions.
        case ambiguousMatch(count: Int, hintSize: CGSize)
    }

    internal struct Plan: Equatable, Sendable {
        /// The array offset of the proposed display in the `candidates` array
        /// used for planning (not a caller-controlled identity).
        internal let proposedIndex: Int
        /// The proposed display's visible frame.
        internal let proposedFrame: CGRect
        /// Whether the proposed display is the primary.
        internal let isPrimaryProposed: Bool
        /// Why the proposal was made (exact, missing, ambiguous).
        internal let reason: MatchReason
        /// The restored target frame computed by `WindowLayoutGeometry.restore`.
        internal let targetFrame: CGRect
    }

    /// Provisional array limit; empty or oversized arrays are rejected.
    internal static let maximumCandidateCount = 256

    /// Fail-closed planner. Returns `nil` for any invalid input, unavailable
    /// geometry, ambiguous primary, or when `WindowLayoutGeometry.restore` fails.
    internal static func plan(
        relativeFrame: RelativeWindowFrame,
        captureHint: WindowLayoutDocument.DisplaySize,
        candidates: [Candidate]
    ) -> Plan? {
        // 1. Array bounds: must have at least one and at most the provisional limit.
        guard !candidates.isEmpty, candidates.count <= maximumCandidateCount else { return nil }

        // 2. Must have exactly one primary.
        let primaryIndices = candidates.indices.filter { candidates[$0].isPrimary }
        guard primaryIndices.count == 1 else { return nil }
        let primaryOffset = primaryIndices[0]
        let primaryCandidate = candidates[primaryOffset]

        // 3. Capture hint must be positive and finite (never a physical identity).
        guard captureHint.width.isFinite, captureHint.height.isFinite,
              captureHint.width > 0, captureHint.height > 0 else { return nil }

        // 4. All candidate frames must be valid; do not silently ignore bad entries.
        // Array offsets are unique by construction, so duplicate-preview references
        // are impossible; the caller orders the array, and `proposedIndex` indexes
        // exactly that array.
        for idx in candidates.indices {
            guard isUsable(candidates[idx].visibleFrame) else { return nil }
        }

        // 5. Relative frame must be valid and finite for restore.
        guard relativeFrame.width.isFinite, relativeFrame.height.isFinite,
              relativeFrame.width > 0, relativeFrame.height > 0,
              relativeFrame.x.isFinite, relativeFrame.y.isFinite else { return nil }

        // 5b. The shared geometry gate: a relative frame must be capturable with at least half the
        //     area visible, not just something restore can clamp into existence. A far-offscreen
        //     origin survives that clamping only by restoring a wholly on-screen rectangle, which
        //     never happened, so fail closed instead of silently accepting it.
        guard WindowLayoutDocument.isAcceptable(relativeWindowFrame: relativeFrame) else { return nil }

        // 6. Match exact width AND height against the capture hint.
        let hintW = captureHint.width
        let hintH = captureHint.height
        let matchingOffsets = candidates.indices.filter { offset in
            let s = candidates[offset].visibleFrame.size
            return (s.width == hintW) && (s.height == hintH)
        }

        let proposedOffset: Int
        let isPrimaryProposed: Bool
        let reason: MatchReason

        if matchingOffsets.count == 1 {
            proposedOffset = matchingOffsets[0]
            isPrimaryProposed = candidates[proposedOffset].isPrimary
            reason = .exactMatch(hintSize: CGSize(width: hintW, height: hintH))
        } else {
            proposedOffset = primaryOffset
            isPrimaryProposed = true
            if matchingOffsets.isEmpty {
                reason = .missingHint
            } else {
                reason = .ambiguousMatch(count: matchingOffsets.count, hintSize: CGSize(width: hintW, height: hintH))
            }
        }

        // 7. Compute target with existing restore; failure = nil (no authorization claim).
        guard let restored = WindowLayoutGeometry.restore(relativeFrame, in: candidates[proposedOffset].visibleFrame) else {
            return nil
        }

        return Plan(
            proposedIndex: proposedOffset,
            proposedFrame: candidates[proposedOffset].visibleFrame,
            isPrimaryProposed: isPrimaryProposed,
            reason: reason,
            targetFrame: restored
        )
    }

    /// Same validity criteria as `WindowLayoutGeometry.isUsable`: finite components,
    /// positive width/height. Negative widths/heights are rejected (CGRect reports
    /// absolute value from size).
    ///
    /// Behavioral addition: a collapsed edge (`maxX == minX` or `maxY == minY`)
    /// is rejected even when `size.width > 0` and `size.height > 0`. At huge
    /// coordinate values finite double arithmetic can round so that
    /// `minX + width == minX`, yielding a non-zero raw size but a zero-span
    /// rectangle. Such a display cannot represent a meaningful visible area,
    /// so it is excluded regardless of whether it is selected or proposed.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width.isFinite && rect.size.width > 0
            && rect.size.height.isFinite && rect.size.height > 0
            // Collapsed edge due to rounding at huge coordinates:
            && rect.maxX > rect.minX && rect.maxY > rect.minY
    }
}
