import CoreGraphics
import Foundation
@testable import DockGroupsCore

/// Shared fixtures for the side-effect-free layout planner tests. Values only: nothing here reads
/// a display, Accessibility or a file.
enum LayoutPlannerFixtures {
    /// 2560 × 1440 primary display with a 30 pt menu bar and a 59 pt Dock (as in the spike).
    static let primary = LayoutDisplay(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 59, width: 2560, height: 1351),
        backingScaleFactor: 2,
        isPrimary: true
    )

    /// 1920 × 1080 display to the left of the primary: negative AppKit and Accessibility x.
    static let left = LayoutDisplay(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055),
        backingScaleFactor: 1,
        isPrimary: false
    )

    /// 1680 × 1050 display above the primary: negative Accessibility y.
    static let above = LayoutDisplay(
        frame: CGRect(x: 0, y: 1440, width: 1680, height: 1050),
        visibleFrame: CGRect(x: 0, y: 1440, width: 1680, height: 1050),
        backingScaleFactor: 2,
        isPrimary: false
    )

    /// A simple 1000 × 800 primary display whose visible frame is the whole display.
    static let simple = LayoutDisplay(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        backingScaleFactor: 1,
        isPrimary: true
    )

    static func window(
        _ topLeftFrame: CGRect?,
        role: LayoutWindowObservation.Role = .window,
        subrole: LayoutWindowObservation.Subrole = .standardWindow,
        minimized: WindowObservations.TriState = .no,
        visible: WindowObservations.TriState = .yes,
        onCurrentSpace: WindowObservations.TriState = .yes,
        fullScreen: WindowObservations.TriState = .no,
        identifiable: WindowObservations.TriState = .yes
    ) -> LayoutWindowObservation.Window {
        LayoutWindowObservation.Window(
            topLeftFrame: topLeftFrame,
            role: role,
            subrole: subrole,
            minimized: minimized,
            visible: visible,
            onCurrentSpace: onCurrentSpace,
            fullScreen: fullScreen,
            identifiable: identifiable
        )
    }

    enum ReportedCount {
        case matching
        case unknown
        case value(Int)
    }

    /// An app observation; the reported window count defaults to the windows given.
    static func app(
        _ bundleIdentifier: String,
        _ windows: [LayoutWindowObservation.Window],
        reported: ReportedCount = .matching,
        running: WindowObservations.TriState = .yes
    ) -> LayoutWindowObservation {
        let count: Int?
        switch reported {
        case .matching: count = windows.count
        case .unknown: count = nil
        case .value(let value): count = value
        }
        return LayoutWindowObservation(
            bundleIdentifier: bundleIdentifier,
            appRunningUnprotected: running,
            reportedWindowCount: count,
            windows: windows
        )
    }

    static func capture(
        _ observations: [LayoutWindowObservation],
        displays: [LayoutDisplay] = [primary],
        permission: LayoutAccessibilityPermission = .granted,
        groupID: UUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    ) -> LayoutCapturePlanner.Plan {
        LayoutCapturePlanner.plan(
            groupID: groupID, permission: permission, observations: observations, displays: displays
        )
    }

    static func capturedGroup(_ plan: LayoutCapturePlanner.Plan) -> WindowLayoutDocument.Group? {
        if case .captured(let group, _) = plan { return group }
        return nil
    }

    static func decisions(_ plan: LayoutCapturePlanner.Plan) -> [LayoutCapturePlanner.AppDecision] {
        switch plan {
        case .captured(_, let apps), .notCaptured(_, let apps): return apps
        }
    }

    static func targets(_ preview: LayoutRestorePreviewPlanner.Preview) -> [LayoutRestorePreviewPlanner.Target?] {
        guard case .planned(let decisions) = preview else { return [] }
        return decisions.map { decision in
            if case .target(let target) = decision { return target }
            return nil
        }
    }

    static func isInside(_ rect: CGRect, _ container: CGRect) -> Bool {
        rect.minX >= container.minX && rect.maxX <= container.maxX
            && rect.minY >= container.minY && rect.maxY <= container.maxY
            && rect.width > 0 && rect.height > 0
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Deterministic generator for the randomized round trip (SplitMix64).
struct LayoutPlannerSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
