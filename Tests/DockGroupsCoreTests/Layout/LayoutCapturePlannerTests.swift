import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutCapturePlannerTests {
    typealias F = LayoutPlannerFixtures
    static let onScreen = CGRect(x: 100, y: 100, width: 400, height: 300)

    // MARK: - Permission and input gates

    @Test func unknownPermissionProducesNoGroup() {
        let plan = F.capture([F.app("com.example.A", [F.window(Self.onScreen)])], permission: .unknown)
        #expect(plan == .notCaptured(.accessibilityPermissionUnknown, apps: []))
    }

    @Test func deniedPermissionProducesNoGroup() {
        let plan = F.capture([F.app("com.example.A", [F.window(Self.onScreen)])], permission: .denied)
        #expect(plan == .notCaptured(.accessibilityPermissionDenied, apps: []))
    }

    @Test func permissionIsCheckedBeforeDisplays() {
        #expect(F.capture([], displays: [], permission: .unknown) == .notCaptured(.accessibilityPermissionUnknown, apps: []))
        #expect(F.capture([], displays: [], permission: .denied) == .notCaptured(.accessibilityPermissionDenied, apps: []))
    }

    @Test func invalidDisplaysProduceNoGroup() {
        let plan = F.capture([F.app("com.example.A", [F.window(Self.onScreen)])], displays: [])
        #expect(plan == .notCaptured(.invalidDisplayConfiguration, apps: []))
        let secondaryOnly = F.capture([F.app("com.example.A", [F.window(Self.onScreen)])], displays: [F.left])
        #expect(secondaryOnly == .notCaptured(.invalidDisplayConfiguration, apps: []))
    }

    @Test func tooManyObservationsProduceNoGroup() {
        let observations = (0...LayoutCapturePlanner.maximumObservationCount).map {
            F.app("com.example.app\($0)", [F.window(Self.onScreen)])
        }
        #expect(F.capture(observations) == .notCaptured(.tooManyApps, apps: []))
    }

    @Test func noObservationsProduceNoEmptySnapshot() {
        #expect(F.capture([]) == .notCaptured(.noEligibleWindows, apps: []))
    }

    // MARK: - Capture

    @Test func capturesOneStandardWindowRelativeToVisibleFrame() throws {
        // AX top of the visible frame is y = 1440 - 1410 = 30; the window covers its top-left quarter.
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: 0, y: 30, width: 1280, height: 675.5))])])
        let group = try #require(F.capturedGroup(plan))
        #expect(group.id == UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        #expect(group.windows == [WindowLayoutDocument.Window(
            bundleIdentifier: "com.example.A",
            display: .init(width: 2560, height: 1351),
            frame: RelativeWindowFrame(x: 0, y: 0.5, width: 0.5, height: 0.5)
        )])
        #expect(F.decisions(plan) == [.captured(windowIndex: 0, displayIndex: 0)])
    }

    @Test func capturedGroupPassesDocumentValidation() throws {
        let plan = F.capture([
            F.app("com.example.A", [F.window(Self.onScreen)]),
            F.app("com.example.B", [F.window(CGRect(x: 600, y: 200, width: 800, height: 600))]),
        ])
        let group = try #require(F.capturedGroup(plan))
        let document = try WindowLayoutDocument(groups: [group])
        #expect(document.groups == [group])
    }

    @Test func multipleWindowsSkipOnlyThatApp() throws {
        let plan = F.capture([
            F.app("com.example.Two", [F.window(Self.onScreen), F.window(CGRect(x: 600, y: 200, width: 300, height: 300))]),
            F.app("com.example.One", [F.window(Self.onScreen)]),
        ])
        let group = try #require(F.capturedGroup(plan))
        #expect(group.windows.map(\.bundleIdentifier) == ["com.example.One"])
        #expect(F.decisions(plan) == [.skipped(.ineligible(.multipleWindows)), .captured(windowIndex: 0, displayIndex: 0)])
    }

    @Test func dialogBesideStandardWindowIsAmbiguous() {
        let plan = F.capture([F.app("com.example.A", [
            F.window(Self.onScreen),
            F.window(CGRect(x: 106, y: 106, width: 66, height: 20), subrole: .dialog),
        ])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.ineligible(.multipleWindows))]))
    }

    @Test func loneDialogIsNotStandard() {
        let plan = F.capture([F.app("com.example.A", [F.window(Self.onScreen, subrole: .dialog)])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.ineligible(.windowNotStandard))]))
    }

    @Test func zeroWindowsSkipTheApp() {
        let plan = F.capture([F.app("com.example.A", [])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.ineligible(.zeroWindows))]))
    }

    @Test(arguments: [
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen)], running: .unknown),
         LayoutCandidateEligibility.SkipReason.appNotKnownRunningOrUnprotected),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen)], reported: .unknown),
         .snapshotIncomplete),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen)], reported: .value(2)),
         .snapshotIncomplete),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, role: .unknown)]),
         .windowStandardUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, subrole: .unknown)]),
         .windowStandardUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, visible: .unknown)]),
         .windowVisibleUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, minimized: .unknown)]),
         .windowMinimizedUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, minimized: .yes)]),
         .windowMinimized),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, onCurrentSpace: .unknown)]),
         .windowCurrentSpaceUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, fullScreen: .unknown)]),
         .windowFullscreenStatusUnknown),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, fullScreen: .yes)]),
         .windowIsFullscreen),
        (LayoutPlannerFixtures.app("com.example.A", [LayoutPlannerFixtures.window(LayoutCapturePlannerTests.onScreen, identifiable: .unknown)]),
         .windowIdentifiableUnknown),
    ])
    func unknownOrNegativeFactsSkipTheApp(
        observation: LayoutWindowObservation,
        expected: LayoutCandidateEligibility.SkipReason
    ) {
        #expect(F.capture([observation]) == .notCaptured(.noEligibleWindows, apps: [.skipped(.ineligible(expected))]))
    }

    @Test func missingFrameSkipsTheApp() {
        let plan = F.capture([F.app("com.example.A", [F.window(nil)])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.frameUnavailable)]))
    }

    @Test func nonfiniteFrameSkipsTheApp() {
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.coordinateConversionFailed)]))
    }

    // MARK: - Half-area boundary and displays

    @Test func exactlyHalfOnTheDisplayIsCaptured() throws {
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: -100, y: 300, width: 200, height: 200))])],
                             displays: [F.simple])
        let window = try #require(F.capturedGroup(plan)?.windows.first)
        #expect(window.frame == RelativeWindowFrame(x: -0.1, y: 0.375, width: 0.2, height: 0.25))
    }

    @Test func justUnderHalfIsSkipped() {
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: -100.5, y: 300, width: 200, height: 200))])],
                             displays: [F.simple])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.lessThanHalfOnAnyDisplay)]))
    }

    @Test func windowOffEveryDisplayIsSkipped() {
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: 5000, y: 5000, width: 200, height: 200))])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.lessThanHalfOnAnyDisplay)]))
    }

    @Test func halfOnEachOfTwoDisplaysIsAmbiguous() {
        let right = LayoutDisplay(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                  visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                  backingScaleFactor: 1, isPrimary: false)
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: 900, y: 600, width: 200, height: 100))])],
                             displays: [F.simple, right])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.ambiguousDisplay)]))
    }

    @Test func capturesOnSecondaryDisplayWithNegativeX() throws {
        // AppKit (-1820, 100, 800, 600) is AX y = 1440 - 700 = 740.
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: -1820, y: 740, width: 800, height: 600))])],
                             displays: [F.primary, F.left])
        let window = try #require(F.capturedGroup(plan)?.windows.first)
        #expect(window.display == .init(width: 1920, height: 1055))
        #expect(window.frame == RelativeWindowFrame(x: 100.0 / 1920, y: 100.0 / 1055, width: 800.0 / 1920, height: 600.0 / 1055))
        #expect(F.decisions(plan) == [.captured(windowIndex: 0, displayIndex: 1)])
    }

    @Test func capturesOnDisplayAboveWithNegativeAccessibilityY() throws {
        // AppKit (100, 1500, 600, 400) is AX y = 1440 - 1900 = -460.
        let plan = F.capture([F.app("com.example.A", [F.window(CGRect(x: 100, y: -460, width: 600, height: 400))])],
                             displays: [F.primary, F.above])
        let window = try #require(F.capturedGroup(plan)?.windows.first)
        #expect(window.display == .init(width: 1680, height: 1050))
        #expect(window.frame == RelativeWindowFrame(x: 100.0 / 1680, y: 60.0 / 1050, width: 600.0 / 1680, height: 400.0 / 1050))
    }

    @Test func oneGroupCanSpanDisplays() throws {
        let plan = F.capture([
            F.app("com.example.A", [F.window(Self.onScreen)]),
            F.app("com.example.B", [F.window(CGRect(x: -1820, y: 740, width: 800, height: 600))]),
        ], displays: [F.primary, F.left])
        let group = try #require(F.capturedGroup(plan))
        #expect(group.windows.map(\.display) == [.init(width: 2560, height: 1351), .init(width: 1920, height: 1055)])
    }

    // MARK: - Document rules applied per app

    @Test func pathShapedIdentifierIsSkipped() {
        let plan = F.capture([F.app("/Applications/Example.app", [F.window(Self.onScreen)])])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.malformedBundleIdentifier)]))
    }

    @Test func displayHintOutsideDocumentRangeIsSkipped() {
        let wide = LayoutDisplay(frame: CGRect(x: 0, y: 0, width: 150_000, height: 800),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 150_000, height: 800),
                                 backingScaleFactor: 1, isPrimary: true)
        let plan = F.capture([F.app("com.example.A", [F.window(Self.onScreen)])], displays: [wide])
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.displaySizeOutOfRange)]))
    }

    @Test func caseInsensitiveDuplicateAppIsSkipped() throws {
        let plan = F.capture([
            F.app("com.example.App", [F.window(Self.onScreen)]),
            F.app("COM.EXAMPLE.APP", [F.window(Self.onScreen)]),
        ])
        #expect(try #require(F.capturedGroup(plan)).windows.count == 1)
        #expect(F.decisions(plan) == [.captured(windowIndex: 0, displayIndex: 0), .skipped(.duplicateApp)])
    }

    @Test func appsBeyondTheWindowLimitAreSkipped() throws {
        let limit = WindowLayoutDocument.maximumWindowCountPerGroup
        let plan = F.capture((0...limit).map { F.app("com.example.app\($0)", [F.window(Self.onScreen)]) })
        #expect(try #require(F.capturedGroup(plan)).windows.count == limit)
        #expect(F.decisions(plan).last == .skipped(.windowLimitReached))
    }

    @Test func skippedAppsStillAllowOthersAndKeepPositions() throws {
        let plan = F.capture([
            F.app("com.example.Min", [F.window(Self.onScreen, minimized: .yes)]),
            F.app("com.example.A", [F.window(Self.onScreen)]),
            F.app("com.example.Off", [F.window(nil)]),
            F.app("com.example.B", [F.window(CGRect(x: 600, y: 200, width: 800, height: 600))]),
        ])
        #expect(try #require(F.capturedGroup(plan)).windows.map(\.bundleIdentifier) == ["com.example.A", "com.example.B"])
        #expect(F.decisions(plan) == [
            .skipped(.ineligible(.windowMinimized)),
            .captured(windowIndex: 0, displayIndex: 0),
            .skipped(.frameUnavailable),
            .captured(windowIndex: 1, displayIndex: 0),
        ])
    }

    // MARK: - Privacy

    @Test func skipReasonsCarryNoIdentifierOrPath() {
        let secretIdentifiers = ["com.secret.Private", "/Users/secret/Private.app", "com.secret.Other"]
        let plan = F.capture([
            F.app(secretIdentifiers[0], [F.window(Self.onScreen), F.window(Self.onScreen)]),
            F.app(secretIdentifiers[1], [F.window(Self.onScreen)]),
            F.app(secretIdentifiers[2], [F.window(nil)]),
        ])
        guard case .notCaptured(let reason, let apps) = plan else {
            Issue.record("expected no group")
            return
        }
        let text = String(describing: reason) + apps.map { String(describing: $0) }.joined()
            + apps.compactMap { if case .skipped(let skip) = $0 { return skip.code } else { return nil } }.joined()
        #expect(!text.contains("secret"))
        #expect(!text.contains("/"))
    }

    @Test func skipCodesAreFixedStrings() {
        let reasons: [LayoutCapturePlanner.AppSkipReason] = [
            .ineligible(.multipleWindows), .frameUnavailable, .coordinateConversionFailed,
            .lessThanHalfOnAnyDisplay, .ambiguousDisplay, .malformedBundleIdentifier,
            .displaySizeOutOfRange, .geometryRejected, .duplicateApp, .windowLimitReached,
        ]
        let codes = reasons.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.first == "ineligible.multipleWindows")
        #expect(codes.allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == ".") } })
    }
}
