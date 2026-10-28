/// Tests for the LayoutCandidateEligibility decision core.
///
/// These tests verify conservative candidate eligibility: a single observed window
/// is eligible ONLY when every prerequisite is .yes AND every required window condition
/// is .yes. Any .no, .unknown, zero windows, or multiple windows produces a deterministic
/// skip reason. No window IDs or capabilities are ever returned.
import XCTest
@testable import DockGroupsCore

final class LayoutCandidateEligibilityTests: XCTestCase {

    // MARK: - Positive decision

    func testEligibleWhenAllPrerequisitesAndAllWindowConditionsYes_singleWindow() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        switch decision {
        case .eligible:
            break // expected
        case .skip(let reason):
            XCTFail("Expected eligible, got skip: \(reason)")
        }
    }

    // MARK: - Prerequisite negatives and unknowns

    func testSkipWhenPermissionUnknown() {
        let observations = WindowObservations(
            permissionGranted: .unknown,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .accessibilityPermissionUnknown)
    }

    func testSkipWhenPermissionNo() {
        let observations = WindowObservations(
            permissionGranted: .no,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .accessibilityPermissionNotGranted)
    }

    func testSkipWhenAppRunningUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .unknown,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .appNotKnownRunningOrUnprotected)
    }

    func testSkipWhenAppRunningNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .no,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .appNotKnownRunningOrUnprotected)
    }

    func testSkipWhenSnapshotUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .unknown,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .snapshotIncomplete)
    }

    func testSkipWhenSnapshotNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .no,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .snapshotIncomplete)
    }

    // MARK: - Prerequisite ordering: first failing prerequisite wins

    func testSkipReportsFirstFailingPrerequisiteWhenMultipleMissing() {
        // permission unknown, app no, snapshot unknown — permission is checked first
        let observations = WindowObservations(
            permissionGranted: .unknown,
            appRunningUnprotected: .no,
            completeSnapshot: .unknown,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .accessibilityPermissionUnknown)
    }

    // MARK: - Zero windows

    func testSkipWhenZeroWindows() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: []
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .zeroWindows)
    }

    // MARK: - Multiple windows (ambiguity): skip regardless of eligibility

    func testSkipWhenMultipleWindowsEvenIfBothEligible() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [
                .init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes),
                .init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes),
            ]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .multipleWindows)
    }

    func testSkipWhenMultipleWindowsEvenIfOneIneligible() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [
                .init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes),
                .init(standard: .no, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes),
            ]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .multipleWindows)
    }

    // MARK: - Window condition negatives and unknowns

    func testSkipWhenWindowStandardNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .no, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowNotStandard)
    }

    func testSkipWhenWindowStandardUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .unknown, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowStandardUnknown)
    }

    func testSkipWhenWindowVisibleNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .no, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowNotVisible)
    }

    func testSkipWhenWindowVisibleUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .unknown, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowVisibleUnknown)
    }

    func testSkipWhenWindowUnminimizedNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .no, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowMinimized)
    }

    func testSkipWhenWindowUnminimizedUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .unknown, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowMinimizedUnknown)
    }

    func testSkipWhenWindowCurrentSpaceNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .no, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowNotInCurrentSpace)
    }

    func testSkipWhenWindowCurrentSpaceUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .unknown, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowCurrentSpaceUnknown)
    }

    func testSkipWhenWindowNonFullscreenNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .no, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowIsFullscreen)
    }

    func testSkipWhenWindowNonFullscreenUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .unknown, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowFullscreenStatusUnknown)
    }

    func testSkipWhenWindowIdentifiableNo() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .no)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowNotIdentifiable)
    }

    func testSkipWhenWindowIdentifiableUnknown() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .unknown)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowIdentifiableUnknown)
    }

    // MARK: - Window condition ordering: first failing condition wins

    func testSkipReportsFirstFailingWindowCondition() {
        // standard unknown AND visible unknown: standard is checked first
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .unknown, visible: .unknown, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decision = LayoutCandidateEligibility.decide(observations)

        guard case .skip(let reason) = decision else {
            XCTFail("Expected skip, got eligible"); return
        }
        XCTAssertEqual(reason, .windowStandardUnknown)
    }

    // MARK: - Input bounds / determinism

    func testDecisionIsDeterministicForIdenticalInputs() {
        let observations = WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let d1 = LayoutCandidateEligibility.decide(observations)
        let d2 = LayoutCandidateEligibility.decide(observations)

        switch (d1, d2) {
        case (.eligible, .eligible):
            break
        case (.skip(let r1), .skip(let r2)):
            XCTAssertEqual(r1, r2)
        default:
            XCTFail("Decisions differ across calls")
        }
    }

    func testSkipReasonIsStableAcrossNegativeStates() {
        // Repeated calls with the same negative input must yield the same reason every time.
        let observations = WindowObservations(
            permissionGranted: .no,
            appRunningUnprotected: .yes,
            completeSnapshot: .yes,
            windows: [.init(standard: .yes, visible: .yes, unminimized: .yes, currentSpace: .yes, nonFullscreen: .yes, identifiable: .yes)]
        )

        let decisions = (0..<5).map { _ in LayoutCandidateEligibility.decide(observations) }

        for d in decisions {
            guard case .skip(let reason) = d else {
                XCTFail("Expected skip, got eligible"); return
            }
            XCTAssertEqual(reason, .accessibilityPermissionNotGranted)
        }
    }
}
