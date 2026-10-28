import Foundation

/// A draft, in-memory window layout document (design spec H) and the single gate that accepts one.
///
/// Privacy: a document holds only what a layout needs — group UUIDs, app bundle identifiers,
/// geometry normalized against a display's visible frame and that display's dimensions. There is no
/// field for a window title, URL, document path, screenshot, Accessibility element or display
/// identity, so none can be stored by accident. A `ValidationError` carries the group's UUID and a
/// window's position, never the untrusted string it refused, so a malformed identifier cannot put a
/// path into a log.
///
/// Scope: this type is a value model and validator only. It does not read or write a file, encode or
/// decode JSON, query a display, touch Accessibility, move a window or talk to `GroupStore`; a future
/// persistence layer is expected to hand it decoded, still-untrusted values.
///
/// Immutability: every stored property is a `let`, every component is a value type, and `init` is
/// the only way to make a document, so accepted contents cannot be edited afterwards into something
/// validation would have refused. Invalid input is rejected with a `ValidationError`; validation
/// stops at the first problem.
struct WindowLayoutDocument: Equatable, Sendable {
    /// The only document format this draft understands.
    static let currentFormatVersion = 1

    /// The most groups one document may hold: 256. A provisional product limit, not a claim about
    /// how many groups people keep; it exists to bound a corrupt or hostile array. With
    /// `maximumWindowCountPerGroup` the two limits cap a document at 16,384 window records.
    static let maximumGroupCount = 256

    /// The most windows one group's snapshot may hold: 64. A provisional product limit, not a claim
    /// about how many windows a real group has: a group's windows can span several displays, and
    /// the proposed capture behavior of keeping one standard window per running app does not fix
    /// the number either. The limit rejects a corrupt array and bounds the records one group adds.
    static let maximumWindowCountPerGroup = 64

    /// The longest bundle identifier kept: 255 characters, the limit this app's own capture accepts
    /// (`CapturePlanner.maximumNameLength`), so a captured identity is never refused here for its
    /// length alone.
    static let maximumBundleIdentifierLength = 255

    /// The most UTF-8 bytes a bundle identifier may occupy: 1,020 — four bytes for each of
    /// `maximumBundleIdentifierLength` characters. A provisional product limit, not a fact about
    /// bundle identifiers: it exists because `String.count` counts extended grapheme clusters, not
    /// bytes, so a *one-character* identifier can still be arbitrarily large. A single "a" followed
    /// by tens of thousands of combining marks is one cluster and passes the 255-character limit
    /// while occupying hundreds of kilobytes, which would make that limit no bound at all.
    ///
    /// Four bytes per character is the widest a UTF-8 scalar gets, so a string whose characters are
    /// each one scalar is never refused here for its size alone: 255 ASCII characters are 255 bytes
    /// and 255 four-byte scalars are exactly 1,020. Only a character built from several scalars
    /// (combining marks, a ZWJ sequence, a flag) can reach the byte cap first. Capture currently
    /// has no equivalent byte limit, so this provisional model can reject an identifier capture
    /// accepts; that compatibility needs review before the model is used for persistence.
    static let maximumBundleIdentifierByteCount = 4 * maximumBundleIdentifierLength

    /// The largest display visible frame per axis a document may record, in points: 100,000. A
    /// provisional product limit, not a verified bound on displays: it is set well above any
    /// plausible visible frame so a corrupt hint cannot carry meaningless fractions.
    static let maximumDisplayDimension: CGFloat = 100_000

    /// The smallest display visible frame per axis a document may record, in points: 1. A
    /// provisional product limit: a smaller hint is treated as too coarse to match a display.
    static let minimumDisplayDimension: CGFloat = 1

    /// The value of a document's format version; only `currentFormatVersion` is accepted.
    let formatVersion: Int
    /// One entry per group with a saved layout, in the document's order.
    let groups: [Group]

    /// A group's saved snapshot: which group, and its windows. A group's windows can come from more
    /// than one display, so the capture display is a hint on each window, not one value for the
    /// group.
    struct Group: Equatable, Sendable {
        let id: UUID
        /// The group's windows; never empty (a group without eligible windows has no snapshot).
        let windows: [Window]
    }

    /// One app window in a snapshot. `RelativeWindowFrame` is already geometry normalized against
    /// the visible frame of the display the window was captured on, and `display` keeps that
    /// display's size as a best-effort hint; `bundleIdentifier` is the app's identity — nothing
    /// identifies the window itself.
    struct Window: Equatable, Sendable {
        let bundleIdentifier: String
        let display: DisplaySize
        let frame: RelativeWindowFrame
    }

    /// A display's visible frame size in points, as `NSScreen.visibleFrame` reports a visible frame.
    /// Only the dimensions are kept: no name, serial number, position or "is main" flag, and
    /// restore may map the same frame onto a different display. A hint, never an identity.
    struct DisplaySize: Equatable, Sendable {
        let width: CGFloat
        let height: CGFloat
    }

    /// Why a document was refused. No case carries an untrusted string: a bundle identifier can be
    /// a path, and an error that repeats it puts a user's file into any log that prints the error.
    /// A window is identified by its position in the group instead, which is enough to locate it.
    enum ValidationError: Error, Equatable, Sendable {
        case unsupportedFormatVersion(Int)
        case tooManyGroups(count: Int)
        case duplicateGroupID(UUID)
        case noWindows(groupID: UUID)
        case tooManyWindows(groupID: UUID, count: Int)
        case displaySizeOutOfRange(groupID: UUID, windowIndex: Int)
        case malformedBundleIdentifier(groupID: UUID, windowIndex: Int)
        case duplicateBundleIdentifier(groupID: UUID, windowIndex: Int)
        case geometryOutOfRange(groupID: UUID, windowIndex: Int)
    }

    /// The largest relative width or height a capture can produce, plus one representable step of
    /// rounding slack — the same tolerance `WindowLayoutGeometry.restore` allows.
    private static let maximumRelativeDimension = WindowLayoutGeometry.maximumRelativeDimension.nextUp

    /// The highest relative origin either axis may have (`x < 1` for a capture), plus one step. A
    /// necessary bound only: an origin this high has no overlap, which `isAcceptable` refuses.
    private static let maximumRelativeOrigin = CGFloat(1).nextUp

    /// The lowest relative origin either axis may have (`x > -width >= -2` for a capture), plus one
    /// step. A necessary bound only; the overlap test decides.
    private static let minimumRelativeOrigin = -(WindowLayoutGeometry.maximumRelativeDimension.nextUp)

    /// How far below half a frame's measured visible fraction may fall: eight representable steps
    /// on the unit interval. Capture stores each relative component from a separate division, so an
    /// exact half can measure a few steps under, while a window that really has less than half
    /// inside is far beyond rounding.
    private static let halfAreaRoundingSlack = 8 * CGFloat.ulpOfOne

    /// A document with `groups`, or the first reason it cannot be one. Format version, group count,
    /// duplicate group UUIDs, an empty or oversized window list, and then each window's display
    /// hint, bundle identifier and geometry are checked in that order; the first failure is thrown.
    init(formatVersion: Int = Self.currentFormatVersion, groups: [Group]) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ValidationError.unsupportedFormatVersion(formatVersion)
        }
        guard groups.count <= Self.maximumGroupCount else {
            throw ValidationError.tooManyGroups(count: groups.count)
        }

        var groupIDs = Set<UUID>(minimumCapacity: groups.count)
        for group in groups {
            guard groupIDs.insert(group.id).inserted else {
                throw ValidationError.duplicateGroupID(group.id)
            }
            guard !group.windows.isEmpty else {
                throw ValidationError.noWindows(groupID: group.id)
            }
            guard group.windows.count <= Self.maximumWindowCountPerGroup else {
                throw ValidationError.tooManyWindows(groupID: group.id, count: group.windows.count)
            }

            // Bundle identifiers differ in case across apps ("com.apple.Safari" and
            // "com.apple.safari"), so two windows of one group count as the same app ignoring case.
            var identifiers = Set<String>(minimumCapacity: group.windows.count)
            for (index, window) in group.windows.enumerated() {
                guard Self.isAcceptable(window.display) else {
                    throw ValidationError.displaySizeOutOfRange(groupID: group.id, windowIndex: index)
                }
                guard Self.isAcceptableBundleIdentifier(window.bundleIdentifier) else {
                    throw ValidationError.malformedBundleIdentifier(groupID: group.id, windowIndex: index)
                }
                guard identifiers.insert(window.bundleIdentifier.lowercased()).inserted else {
                    throw ValidationError.duplicateBundleIdentifier(groupID: group.id, windowIndex: index)
                }
                guard Self.isAcceptable(window.frame) else {
                    throw ValidationError.geometryOutOfRange(groupID: group.id, windowIndex: index)
                }
            }
        }

        self.formatVersion = formatVersion
        self.groups = groups
    }

    /// Whether `display` is a usable matching hint: finite and between the documented provisional
    /// minimum and maximum on both axes.
    private static func isAcceptable(_ display: DisplaySize) -> Bool {
        display.width.isFinite && display.height.isFinite
            && display.width >= minimumDisplayDimension
            && display.width <= maximumDisplayDimension
            && display.height >= minimumDisplayDimension
            && display.height <= maximumDisplayDimension
    }

    /// Whether `identifier` has the shape of an app's bundle identifier rather than that of a path,
    /// URL or other string: non-empty, at most `maximumBundleIdentifierLength` characters and at
    /// most `maximumBundleIdentifierByteCount` UTF-8 bytes, with no "/" or ":" (the marks of a
    /// location or web address, `AppItemPolicy.isBundleIdentifier`) and no whitespace or control
    /// characters. Capture applies the character and syntax checks but not the byte cap. A dot is
    /// not required, because
    /// the group store and capture both keep identifiers without one.
    ///
    /// Both size limits are needed. `count` is the limit capture applies and is what an identity is
    /// measured in, but it counts extended grapheme clusters, so one character made of many scalars
    /// slips under it at any size; the byte cap is the bound that does not. Neither limit's value is
    /// reported in an error (see `ValidationError`), so a hostile string stays out of logs.
    ///
    /// This is syntax only. It cannot prove that an app with this identifier is installed, that the
    /// identifier resolves to a bundle, or that any window belongs to it; those are separate checks
    /// for capture and restore.
    private static func isAcceptableBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= maximumBundleIdentifierLength,
              identifier.utf8.count <= maximumBundleIdentifierByteCount,
              AppItemPolicy.isBundleIdentifier(identifier)
        else { return false }
        return !identifier.unicodeScalars.contains {
            $0.properties.isWhitespace || $0.properties.generalCategory == .control
        }
    }

    /// Whether `frame` is geometry that `WindowLayoutGeometry.capture` can have produced. Capture
    /// keeps a window only when at least half its area lies inside the captured display's visible
    /// frame. A relative frame is normalized to that frame, so the visible frame is the unit square
    /// `[0, 1] × [0, 1]` and the overlap between the stored rectangle and that square is the
    /// decisive test.
    ///
    /// The dimension and origin bounds are necessary conditions of the half-area rule, not a
    /// characterization of it: each axis's overlap share lies in `(0, 1]`, so half the area bounds a
    /// dimension at `2` and an origin at `(-2, 1)`. Bounds alone would also accept frames that miss
    /// the display (`x = -1, width = 0.2`) or cover too little of it (`x = -0.75, width = 1`), which
    /// is why the overlap test below is required.
    ///
    /// One representable step of slack is allowed on the bounds and eight on the visible-fraction
    /// comparison, because capture computes each relative component with a separate division: an
    /// exact half can land just under half and must not be falsely refused. A frame further than
    /// that from the boundary is refused.
    ///
    /// The stored display hint is deliberately not used to re-run `capture` or `restore`: it is a
    /// best-effort match that may describe another display than the one restore picks, and a round
    /// trip would add floating-point tolerance rules without rejecting anything these checks miss.
    private static func isAcceptable(_ frame: RelativeWindowFrame) -> Bool {
        guard frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              frame.width <= maximumRelativeDimension,
              frame.height <= maximumRelativeDimension,
              frame.x >= minimumRelativeOrigin, frame.x <= maximumRelativeOrigin,
              frame.y >= minimumRelativeOrigin, frame.y <= maximumRelativeOrigin
        else { return false }

        let overlapWidth = visibleOverlap(of: frame.width, at: frame.x)
        let overlapHeight = visibleOverlap(of: frame.height, at: frame.y)
        guard overlapWidth > 0, overlapHeight > 0 else { return false }

        // Measure the visible share per axis and compare two ratios, not two areas. A relative
        // frame's components are arbitrary fractions of the visible frame, so `width * height` and
        // `overlapWidth * overlapHeight` can each underflow to zero for a window far smaller than
        // the display, and an area comparison would then read `0 >= 0` and keep a window with a
        // quarter of its area inside. A ratio is scale-free, so it holds at any magnitude. Each
        // ratio is clamped to at most 1 so rounding cannot report more than a fully visible axis,
        // and the slack is stated on that same unit interval.
        let visibleWidthRatio = min(overlapWidth / frame.width, 1)
        let visibleHeightRatio = min(overlapHeight / frame.height, 1)
        let visibleFraction = visibleWidthRatio * visibleHeightRatio
        return visibleFraction >= WindowLayoutGeometry.minimumVisibleFraction - halfAreaRoundingSlack
    }

    /// The part of an interval of `length` that starts at `origin` and lies inside `0...1`.
    ///
    /// Written per side rather than as `min(origin + length, 1) - max(origin, 0)`: for a thin window
    /// far from the origin, that subtraction adds a small length to a large origin and then removes
    /// the origin again, losing the window's own length to rounding and falsely refusing geometry
    /// capture produced. On a side that starts inside, the overlap is the length capped by the room
    /// left; on a side that starts outside, it is capped by the far edge. A negative result means
    /// that side does not reach the square at all.
    private static func visibleOverlap(of length: CGFloat, at origin: CGFloat) -> CGFloat {
        origin >= 0 ? min(length, 1 - origin) : min(origin + length, 1)
    }
}
