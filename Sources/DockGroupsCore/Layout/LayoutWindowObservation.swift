import CoreGraphics

// Read-only inputs for the side-effect-free window layout planners (design spec H).
//
// Every type here is a plain value supplied by a caller. Nothing in this file reads Accessibility,
// a display, a file or a window list; `LayoutWindowObserving` only states the contract a future,
// separately reviewed adapter would have to meet. Facts the caller could not establish are
// `.unknown`, and the planners never treat an unknown as present or absent.
//
// Privacy: an observation holds an app's bundle identifier and window geometry only. There is no
// field for a title, document, URL, process identifier, window number or Accessibility element, so
// a planner cannot match windows by any of them.

/// Accessibility permission as the caller last observed it. `unknown` means the caller did not or
/// could not check; it is never read as granted.
enum LayoutAccessibilityPermission: String, Equatable, Sendable {
    case unknown
    case granted
    case denied
}

/// What the caller observed about one running app's windows. A future adapter would fill this from
/// one app's Accessibility window list; this type only carries the result.
struct LayoutWindowObservation: Equatable, Sendable {
    /// The app's bundle identifier. Untrusted: the capture planner validates it with the layout
    /// document's own rules and never repeats it in a skip reason.
    let bundleIdentifier: String
    /// Whether the app is known to be running and not protected from layout work.
    let appRunningUnprotected: WindowObservations.TriState
    /// How many windows the app's window list reported, or `nil` when the count could not be read.
    /// A count that differs from `windows.count` means some windows could not be read, so the
    /// observation is incomplete.
    let reportedWindowCount: Int?
    /// The windows that could be read, in the order the caller observed them.
    let windows: [Window]

    /// One window as observed. Every fact is tri-state or optional.
    struct Window: Equatable, Sendable {
        /// The window's frame in Accessibility global coordinates (points, origin at the top-left
        /// of the menu-bar display, `y` increasing downwards), or `nil` when it could not be read.
        let topLeftFrame: CGRect?
        let role: Role
        let subrole: Subrole
        let minimized: WindowObservations.TriState
        let visible: WindowObservations.TriState
        let onCurrentSpace: WindowObservations.TriState
        let fullScreen: WindowObservations.TriState
        /// Whether the caller can tell this window apart from the app's other windows without a
        /// title, process identifier plus geometry or a window number.
        let identifiable: WindowObservations.TriState
    }

    /// The window's Accessibility role, reduced to what the planners need.
    enum Role: String, Equatable, Sendable {
        case window
        case other
        case unknown
    }

    /// The window's Accessibility subrole, reduced to what the planners need.
    enum Subrole: String, Equatable, Sendable {
        case standardWindow
        case dialog
        case other
        case unknown
    }
}

extension LayoutWindowObservation {
    /// Whether the window list was read completely: unknown when its count is unknown, no when the
    /// count is negative or differs from the windows that could be read.
    var completeSnapshot: WindowObservations.TriState {
        guard let reportedWindowCount else { return .unknown }
        return reportedWindowCount >= 0 && reportedWindowCount == windows.count ? .yes : .no
    }
}

extension LayoutWindowObservation.Window {
    /// Whether this is a standard window. A known non-window role or a known non-standard subrole
    /// is `no`; otherwise any unknown part keeps the answer unknown.
    var standard: WindowObservations.TriState {
        switch (role, subrole) {
        case (.other, _), (_, .dialog), (_, .other): return .no
        case (.window, .standardWindow): return .yes
        default: return .unknown
        }
    }

    /// The eligibility status of this window, with each tri-state carried over unchanged or negated.
    var eligibilityStatus: WindowStatus {
        WindowStatus(
            standard: standard,
            visible: visible,
            unminimized: minimized.negated,
            currentSpace: onCurrentSpace,
            nonFullscreen: fullScreen.negated,
            identifiable: identifiable
        )
    }
}

extension WindowObservations.TriState {
    /// `yes` and `no` swapped; `unknown` stays unknown.
    var negated: WindowObservations.TriState {
        switch self {
        case .yes: return .no
        case .no: return .yes
        case .unknown: return .unknown
        }
    }
}

/// A display as the caller observed it, in AppKit global coordinates (points, origin at the
/// bottom-left of the menu-bar display). A value, not a display identity.
struct LayoutDisplay: Equatable, Sendable {
    /// The display's whole frame.
    let frame: CGRect
    /// The part of `frame` not covered by the menu bar or the Dock.
    let visibleFrame: CGRect
    /// The display's backing scale factor. Validated, but geometry is planned in points and does
    /// not depend on it.
    let backingScaleFactor: CGFloat
    /// Whether this is the menu-bar display, whose frame height relates AppKit and Accessibility
    /// coordinates. Exactly one display must be primary.
    let isPrimary: Bool
}

/// A display list both planners accept: between one and `DisplayTargetPlanner.maximumCandidateCount`
/// displays, every frame finite with a positive, representable extent, every scale finite and
/// positive, and exactly one primary display whose frame starts at the AppKit origin. Anything else
/// is refused as a whole rather than planned around.
struct LayoutDisplayConfiguration: Equatable, Sendable {
    let displays: [LayoutDisplay]
    /// The position of the primary display in `displays`.
    let primaryIndex: Int

    /// The menu-bar display's full height, the reference for `LayoutCoordinateConversion`.
    var referenceHeight: CGFloat { displays[primaryIndex].frame.height }

    init?(displays: [LayoutDisplay]) {
        guard !displays.isEmpty, displays.count <= DisplayTargetPlanner.maximumCandidateCount else { return nil }
        let primaries = displays.indices.filter { displays[$0].isPrimary }
        guard primaries.count == 1 else { return nil }
        for display in displays {
            guard Self.isUsable(display.frame), Self.isUsable(display.visibleFrame),
                  display.backingScaleFactor.isFinite, display.backingScaleFactor > 0 else { return nil }
        }
        guard displays[primaries[0]].frame.origin == .zero else { return nil }
        self.displays = displays
        self.primaryIndex = primaries[0]
    }

    /// Finite components, positive size, and edges that rounding has not collapsed onto each other.
    static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.width > 0
            && rect.size.height.isFinite && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.maxX > rect.minX && rect.maxY > rect.minY
    }
}

/// The contract a future Accessibility adapter would implement. It is only a contract: no type in
/// this module conforms to it, and the planners take its results as plain values instead of
/// calling it.
///
/// A conforming adapter must read without prompting, writing, raising, unminimizing or activating
/// anything; must not read window titles; and must report `.unknown` for anything it could not
/// establish rather than guessing.
protocol LayoutWindowObserving {
    /// The Accessibility permission, checked without prompting.
    func accessibilityPermission() -> LayoutAccessibilityPermission
    /// One observation per requested bundle identifier, in the same order.
    func observeWindows(bundleIdentifiers: [String]) -> [LayoutWindowObservation]
}
