import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutWindowObservationTests {
    typealias F = LayoutPlannerFixtures

    // MARK: - Tri-state mapping

    @Test(arguments: [
        (LayoutWindowObservation.Role.window, LayoutWindowObservation.Subrole.standardWindow, WindowObservations.TriState.yes),
        (.window, .unknown, .unknown),
        (.unknown, .standardWindow, .unknown),
        (.unknown, .unknown, .unknown),
        (.window, .dialog, .no),
        (.unknown, .dialog, .no),
        (.window, .other, .no),
        (.other, .standardWindow, .no),
        (.other, .unknown, .no),
    ])
    func standardIsUnknownUnlessKnown(
        role: LayoutWindowObservation.Role,
        subrole: LayoutWindowObservation.Subrole,
        expected: WindowObservations.TriState
    ) {
        #expect(F.window(nil, role: role, subrole: subrole).standard == expected)
    }

    @Test func negationKeepsUnknown() {
        #expect(WindowObservations.TriState.yes.negated == .no)
        #expect(WindowObservations.TriState.no.negated == .yes)
        #expect(WindowObservations.TriState.unknown.negated == .unknown)
    }

    @Test func eligibilityStatusNegatesMinimizedAndFullScreenOnly() {
        let status = F.window(nil, minimized: .unknown, visible: .no, onCurrentSpace: .unknown,
                              fullScreen: .yes, identifiable: .no).eligibilityStatus
        #expect(status.unminimized == .unknown)
        #expect(status.nonFullscreen == .no)
        #expect(status.visible == .no)
        #expect(status.currentSpace == .unknown)
        #expect(status.identifiable == .no)
        #expect(status.standard == .yes)
    }

    @Test func snapshotCompletenessIsTriState() {
        let window = F.window(CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(F.app("com.example.A", [window]).completeSnapshot == .yes)
        #expect(F.app("com.example.A", [window], reported: .unknown).completeSnapshot == .unknown)
        #expect(F.app("com.example.A", [window], reported: .value(2)).completeSnapshot == .no)
        #expect(F.app("com.example.A", [], reported: .value(-1)).completeSnapshot == .no)
        #expect(F.app("com.example.A", []).completeSnapshot == .yes)
    }

    // MARK: - Display configuration

    @Test func validConfigurationUsesPrimaryHeight() throws {
        let configuration = try #require(LayoutDisplayConfiguration(displays: [F.left, F.primary]))
        #expect(configuration.primaryIndex == 1)
        #expect(configuration.referenceHeight == 1440)
    }

    @Test func configurationRejectsMissingOrDuplicatePrimary() {
        let secondary = LayoutDisplay(frame: F.primary.frame, visibleFrame: F.primary.visibleFrame,
                                      backingScaleFactor: 2, isPrimary: false)
        #expect(LayoutDisplayConfiguration(displays: []) == nil)
        #expect(LayoutDisplayConfiguration(displays: [secondary]) == nil)
        #expect(LayoutDisplayConfiguration(displays: [F.primary, F.primary]) == nil)
    }

    @Test func configurationRejectsBadGeometryAndScale() {
        let offOrigin = LayoutDisplay(frame: CGRect(x: 10, y: 0, width: 100, height: 100),
                                      visibleFrame: CGRect(x: 10, y: 0, width: 100, height: 100),
                                      backingScaleFactor: 1, isPrimary: true)
        let zeroScale = LayoutDisplay(frame: F.simple.frame, visibleFrame: F.simple.visibleFrame,
                                      backingScaleFactor: 0, isPrimary: true)
        let nanScale = LayoutDisplay(frame: F.simple.frame, visibleFrame: F.simple.visibleFrame,
                                     backingScaleFactor: .nan, isPrimary: true)
        let infiniteVisible = LayoutDisplay(frame: F.simple.frame,
                                            visibleFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
                                            backingScaleFactor: 1, isPrimary: true)
        let emptyVisible = LayoutDisplay(frame: F.simple.frame, visibleFrame: .zero,
                                         backingScaleFactor: 1, isPrimary: true)
        for display in [offOrigin, zeroScale, nanScale, infiniteVisible, emptyVisible] {
            #expect(LayoutDisplayConfiguration(displays: [display]) == nil)
        }
        // One bad secondary refuses the whole list instead of being skipped.
        #expect(LayoutDisplayConfiguration(displays: [F.primary, emptyVisible.withPrimary(false)]) == nil)
    }

    @Test func configurationRejectsOversizedList() {
        let secondaries = Array(repeating: F.left, count: DisplayTargetPlanner.maximumCandidateCount)
        #expect(LayoutDisplayConfiguration(displays: [F.primary] + secondaries) == nil)
        #expect(LayoutDisplayConfiguration(displays: [F.primary] + secondaries.dropLast()) != nil)
    }

    // MARK: - Contract

    @Test func fakeObserverFeedsThePlannerAsPlainValues() throws {
        struct FakeObserver: LayoutWindowObserving {
            let permission: LayoutAccessibilityPermission
            func accessibilityPermission() -> LayoutAccessibilityPermission { permission }
            func observeWindows(bundleIdentifiers: [String]) -> [LayoutWindowObservation] {
                bundleIdentifiers.map {
                    LayoutPlannerFixtures.app($0, [LayoutPlannerFixtures.window(CGRect(x: 100, y: 100, width: 400, height: 300))])
                }
            }
        }

        let granted = FakeObserver(permission: .granted)
        let plan = F.capture(granted.observeWindows(bundleIdentifiers: ["com.example.A"]),
                             permission: granted.accessibilityPermission())
        #expect(try #require(F.capturedGroup(plan)).windows.count == 1)

        let unknown = FakeObserver(permission: .unknown)
        let refused = F.capture(unknown.observeWindows(bundleIdentifiers: ["com.example.A"]),
                                permission: unknown.accessibilityPermission())
        #expect(refused == .notCaptured(.accessibilityPermissionUnknown, apps: []))
    }
}

private extension LayoutDisplay {
    func withPrimary(_ isPrimary: Bool) -> LayoutDisplay {
        LayoutDisplay(frame: frame, visibleFrame: visibleFrame, backingScaleFactor: backingScaleFactor, isPrimary: isPrimary)
    }
}
