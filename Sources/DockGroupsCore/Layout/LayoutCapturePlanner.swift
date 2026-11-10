import CoreGraphics
import Foundation

/// Plans one group's window layout snapshot from caller-supplied observations (design spec H).
///
/// Side-effect free: the planner reads no Accessibility attribute, display, file or window list,
/// writes nothing and moves nothing. It turns values into either a validated
/// `WindowLayoutDocument.Group` or a reason no snapshot is made, and reports a decision for every
/// observed app.
///
/// Rules:
/// - Accessibility permission that is `unknown` or `denied` produces no group, before any
///   observation is looked at, so absent access never yields a partial snapshot.
/// - Each app is judged by `LayoutCandidateEligibility`: one standard, visible, unminimized,
///   identifiable, non-full-screen window on the current Space, with a complete window list.
///   Anything unknown, any second window and any dialog skips that app.
/// - The window's Accessibility frame is converted to AppKit coordinates with the primary
///   display's height, then captured with `WindowLayoutGeometry.capture` against each display's
///   visible frame. Exactly one display must hold at least half the window; none or a tie skips
///   the app.
/// - Every captured window passes `WindowLayoutDocument`'s validation on its own, then once more
///   as a whole group. A group with no captured window produces no group (no empty snapshot).
///
/// A captured group is a geometry proposal only. It does not prove the windows still exist, own
/// the identifiers given, or may be moved later.
///
/// Privacy: no reason carries a bundle identifier, path or geometry. App decisions are positional,
/// aligned with the observations passed in.
enum LayoutCapturePlanner {
    /// The most app observations one plan accepts: a provisional bound against a corrupt or hostile
    /// array, not a product limit. A group's snapshot is separately limited to
    /// `WindowLayoutDocument.maximumWindowCountPerGroup` windows.
    static let maximumObservationCount = 256

    /// Why no group was produced.
    enum GroupSkipReason: String, Equatable, Sendable {
        case accessibilityPermissionUnknown
        case accessibilityPermissionDenied
        case invalidDisplayConfiguration
        case tooManyApps
        case noEligibleWindows
        /// The assembled group failed the document's validation. Not expected once every window
        /// passed on its own; kept so the planner fails closed instead of trapping.
        case documentRejected
    }

    /// Why one app's window was left out. Fixed cases only, so a reason never repeats an untrusted
    /// identifier.
    enum AppSkipReason: Equatable, Sendable {
        /// `LayoutCandidateEligibility` refused the app's observation.
        case ineligible(LayoutCandidateEligibility.SkipReason)
        case frameUnavailable
        case coordinateConversionFailed
        case lessThanHalfOnAnyDisplay
        case ambiguousDisplay
        case malformedBundleIdentifier
        case displaySizeOutOfRange
        case geometryRejected
        case duplicateApp
        case windowLimitReached

        /// A stable, payload-free code for logs and tests.
        var code: String {
            switch self {
            case .ineligible(let reason): return "ineligible.\(reason.rawValue)"
            case .frameUnavailable: return "frameUnavailable"
            case .coordinateConversionFailed: return "coordinateConversionFailed"
            case .lessThanHalfOnAnyDisplay: return "lessThanHalfOnAnyDisplay"
            case .ambiguousDisplay: return "ambiguousDisplay"
            case .malformedBundleIdentifier: return "malformedBundleIdentifier"
            case .displaySizeOutOfRange: return "displaySizeOutOfRange"
            case .geometryRejected: return "geometryRejected"
            case .duplicateApp: return "duplicateApp"
            case .windowLimitReached: return "windowLimitReached"
            }
        }
    }

    /// What happened to one observed app.
    enum AppDecision: Equatable, Sendable {
        /// Captured as `group.windows[windowIndex]`, on `displays[displayIndex]`.
        case captured(windowIndex: Int, displayIndex: Int)
        case skipped(AppSkipReason)
    }

    /// The planner's result. `apps` is aligned with the observations; it is empty when the plan
    /// stopped before looking at any of them.
    enum Plan: Equatable, Sendable {
        case captured(WindowLayoutDocument.Group, apps: [AppDecision])
        case notCaptured(GroupSkipReason, apps: [AppDecision])
    }

    static func plan(
        groupID: UUID,
        permission: LayoutAccessibilityPermission,
        observations: [LayoutWindowObservation],
        displays: [LayoutDisplay]
    ) -> Plan {
        switch permission {
        case .unknown: return .notCaptured(.accessibilityPermissionUnknown, apps: [])
        case .denied: return .notCaptured(.accessibilityPermissionDenied, apps: [])
        case .granted: break
        }
        guard let configuration = LayoutDisplayConfiguration(displays: displays) else {
            return .notCaptured(.invalidDisplayConfiguration, apps: [])
        }
        guard observations.count <= maximumObservationCount else {
            return .notCaptured(.tooManyApps, apps: [])
        }

        var windows: [WindowLayoutDocument.Window] = []
        var identifiers = Set<String>()
        var decisions: [AppDecision] = []
        decisions.reserveCapacity(observations.count)

        for observation in observations {
            switch captureWindow(groupID: groupID, observation: observation, configuration: configuration) {
            case .failure(let reason):
                decisions.append(.skipped(reason))
            case .success(let (window, displayIndex)):
                // Bundle identifiers differ in case across apps, as in `WindowLayoutDocument`.
                guard !identifiers.contains(window.bundleIdentifier.lowercased()) else {
                    decisions.append(.skipped(.duplicateApp))
                    continue
                }
                guard windows.count < WindowLayoutDocument.maximumWindowCountPerGroup else {
                    decisions.append(.skipped(.windowLimitReached))
                    continue
                }
                identifiers.insert(window.bundleIdentifier.lowercased())
                decisions.append(.captured(windowIndex: windows.count, displayIndex: displayIndex))
                windows.append(window)
            }
        }

        guard !windows.isEmpty else { return .notCaptured(.noEligibleWindows, apps: decisions) }
        let group = WindowLayoutDocument.Group(id: groupID, windows: windows)
        guard (try? WindowLayoutDocument(groups: [group])) != nil else {
            return .notCaptured(.documentRejected, apps: decisions)
        }
        return .captured(group, apps: decisions)
    }

    private enum WindowCapture {
        case success((WindowLayoutDocument.Window, Int))
        case failure(AppSkipReason)
    }

    private static func captureWindow(
        groupID: UUID,
        observation: LayoutWindowObservation,
        configuration: LayoutDisplayConfiguration
    ) -> WindowCapture {
        let eligibility = LayoutCandidateEligibility.decide(WindowObservations(
            permissionGranted: .yes,
            appRunningUnprotected: observation.appRunningUnprotected,
            completeSnapshot: observation.completeSnapshot,
            windows: observation.windows.map(\.eligibilityStatus)
        ))
        if case .skip(let reason) = eligibility { return .failure(.ineligible(reason)) }

        guard let topLeftFrame = observation.windows[0].topLeftFrame else { return .failure(.frameUnavailable) }
        guard let frame = LayoutCoordinateConversion.convert(
            topLeftFrame, referenceHeight: configuration.referenceHeight
        ) else { return .failure(.coordinateConversionFailed) }

        var matches: [(index: Int, frame: RelativeWindowFrame)] = []
        for (index, display) in configuration.displays.enumerated() {
            if let relative = WindowLayoutGeometry.capture(window: frame, in: display.visibleFrame) {
                matches.append((index, relative))
            }
        }
        guard !matches.isEmpty else { return .failure(.lessThanHalfOnAnyDisplay) }
        // Exactly half on each of two displays: neither is the window's display.
        guard matches.count == 1 else { return .failure(.ambiguousDisplay) }

        let match = matches[0]
        let visibleSize = configuration.displays[match.index].visibleFrame.size
        let window = WindowLayoutDocument.Window(
            bundleIdentifier: observation.bundleIdentifier,
            display: WindowLayoutDocument.DisplaySize(width: visibleSize.width, height: visibleSize.height),
            frame: match.frame
        )

        // The document's own gate, one window at a time, so one bad app skips only itself.
        do {
            _ = try WindowLayoutDocument(groups: [WindowLayoutDocument.Group(id: groupID, windows: [window])])
        } catch WindowLayoutDocument.ValidationError.displaySizeOutOfRange {
            return .failure(.displaySizeOutOfRange)
        } catch WindowLayoutDocument.ValidationError.malformedBundleIdentifier {
            return .failure(.malformedBundleIdentifier)
        } catch {
            return .failure(.geometryRejected)
        }
        return .success((window, match.index))
    }
}
