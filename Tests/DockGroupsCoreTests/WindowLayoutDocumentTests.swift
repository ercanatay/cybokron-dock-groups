import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Window layout document")
struct WindowLayoutDocumentTests {
    // MARK: - Accepted documents

    @Test func acceptsAMinimalDocumentAndKeepsItsContents() throws {
        let group = makeGroup()

        let document = try makeDocument([group])

        #expect(document.formatVersion == WindowLayoutDocument.currentFormatVersion)
        #expect(document.groups == [group])
    }

    @Test func acceptsAnEmptyDocumentAsTheNoLayoutsYetState() throws {
        let document = try makeDocument([])

        #expect(document.groups.isEmpty)
    }

    @Test func acceptsAPartlyOffscreenWindowThatCaptureProduced() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let captured = try #require(WindowLayoutGeometry.capture(
            window: CGRect(x: -50, y: -20, width: 600, height: 900),
            in: visible
        ))
        // The window is legitimately partly off-screen: capture keeps a negative origin and a
        // height larger than the display instead of cropping or refusing it.
        #expect(captured.x < 0 && captured.y < 0 && captured.height > 1)

        let document = try makeDocument([makeGroup(windows: [makeWindow(
            "com.example.Viewer",
            display: WindowLayoutDocument.DisplaySize(width: visible.width, height: visible.height),
            frame: captured
        )])])

        #expect(document.groups.first?.windows.first?.frame == captured)
    }

    /// The validator must accept every geometry `capture` can emit: a window with exactly half its
    /// area inside, one twice the visible frame's size, and one that hangs off both far edges. This
    /// exercises `capture` itself rather than restating its arithmetic.
    @Test func acceptsEveryGeometryCaptureCanProduce() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let candidates = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -300, y: 0, width: 600, height: 100),
            CGRect(x: -100, y: 0, width: 2_880, height: 900),
            CGRect(x: 1_200, y: 700, width: 400, height: 200),
            CGRect(x: -50, y: -20, width: 600, height: 900),
        ]
        let windows = try candidates.enumerated().map { index, window in
            let captured = try #require(WindowLayoutGeometry.capture(window: window, in: visible), "candidate \(index)")
            return makeWindow(
                "com.example.App\(index)",
                display: WindowLayoutDocument.DisplaySize(width: visible.width, height: visible.height),
                frame: captured
            )
        }

        let document = try makeDocument([makeGroup(windows: windows)])

        #expect(document.groups.map(\.windows) == [windows])
    }

    /// Real `capture` output at the acceptance boundary, so the overlap test cannot reject a window
    /// capture keeps. Negative origins are the ordinary shape: a window hanging off the left or
    /// bottom edge with exactly half its area inside.
    @Test func acceptsCaptureOutputAtOrNearTheHalfAreaBoundaryIncludingNegativeOrigins() throws {
        let examples: [(visible: CGRect, window: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1_000, height: 800), CGRect(x: -300, y: 0, width: 600, height: 100)),
            (CGRect(x: 0, y: 0, width: 1_000, height: 800), CGRect(x: -301, y: 0, width: 602, height: 100)),
            (CGRect(x: 0, y: 0, width: 1_000, height: 800), CGRect(x: -299, y: 0, width: 600, height: 100)),
            (CGRect(x: 0, y: 0, width: 1_000, height: 800), CGRect(x: 0, y: -301, width: 1_000, height: 602)),
            (CGRect(x: 0, y: 0, width: 1_440, height: 900), CGRect(x: 0, y: -450, width: 1_440, height: 900)),
            (CGRect(x: -1_440, y: -200, width: 1_000, height: 800),
             CGRect(x: -1_740, y: -200, width: 600, height: 800)),
            (CGRect(x: -2_000, y: 0, width: 1_000, height: 800), CGRect(x: -2_500, y: 300, width: 1_000, height: 500)),
            (CGRect(x: 0, y: 0, width: 1_710, height: 1_079), CGRect(x: -1_055, y: 0, width: 2_110, height: 1_079)),
        ]

        let windows = try examples.enumerated().map { index, example in
            let captured = try #require(
                WindowLayoutGeometry.capture(window: example.window, in: example.visible),
                "example \(index)"
            )
            #expect(captured.x <= 0 || captured.y <= 0)
            return makeWindow(
                "com.example.Half\(index)",
                display: WindowLayoutDocument.DisplaySize(width: example.visible.width, height: example.visible.height),
                frame: captured
            )
        }

        let document = try makeDocument([makeGroup(windows: windows)])

        #expect(document.groups.first?.windows.count == examples.count)
    }

    /// Two relative values computed from one exact half by separate divisions can land one
    /// representable step under half. That is rounding, not a window with less than half inside.
    @Test func acceptsAFrameOneRoundingStepBelowHalf() throws {
        let width: CGFloat = 0.6
        let frame = RelativeWindowFrame(x: -(width / 2).nextUp, y: 0, width: width, height: 1)
        #expect(frame.x + frame.width > 0)
        #expect(frame.x + frame.width < width / 2)

        let document = try makeDocument([makeGroup(windows: [makeWindow("com.example.Rounding", frame: frame)])])

        #expect(document.groups.first?.windows.count == 1)
    }

    /// A frame can be far smaller than the visible frame in absolute terms and still be wholly
    /// inside it: every relative component here is on the order of `1e-200`, so both the frame's
    /// area and its visible area underflow to zero. It is a fully visible window and must be kept.
    @Test func acceptsATinyFrameWhollyInsideTheVisibleFrame() throws {
        let frame = RelativeWindowFrame(x: 0.25e-200, y: 0.25e-200, width: 1e-200, height: 1e-200)
        // The precondition: the frame's area underflows, so an area comparison sees nothing.
        #expect(frame.width * frame.height == 0)
        #expect(frame.x + frame.width <= 1 && frame.y + frame.height <= 1)

        let document = try makeDocument([makeGroup(windows: [makeWindow("com.example.Tiny", frame: frame)])])

        #expect(document.groups.first?.windows.first?.frame == frame)
    }

    /// The same tiny scale at the acceptance boundary: half the width inside and the full height is
    /// exactly half the area, which capture keeps.
    @Test func acceptsATinyFrameWithExactlyHalfItsAreaInside() throws {
        let frame = RelativeWindowFrame(x: -0.5e-200, y: 0, width: 1e-200, height: 1e-200)
        #expect(frame.width * frame.height == 0)
        #expect(frame.x + frame.width > 0)

        let document = try makeDocument([makeGroup(windows: [makeWindow("com.example.TinyHalf", frame: frame)])])

        #expect(document.groups.first?.windows.count == 1)
    }

    @Test func acceptsAnIdentifierWithoutADotLikeTheGroupStore() throws {
        // `CapturePlanner` and `AppItemPolicy` keep an identifier without a dot ("Mail"), so a group
        // the app accepts must be able to have a layout; requiring reverse-DNS here would split them.
        let document = try makeDocument([makeGroup(windows: [makeWindow("Mail")])])

        #expect(document.groups.first?.windows.first?.bundleIdentifier == "Mail")
    }

    @Test func acceptsTheSameBundleIdentifierInDifferentGroups() throws {
        let document = try makeDocument([makeGroup(), makeGroup()])

        #expect(document.groups.count == 2)
    }

    @Test func acceptsDisplaySizesAtTheDocumentedLimits() throws {
        let document = try makeDocument([makeGroup(windows: [
            makeWindow("com.example.Small", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1)),
            makeWindow("com.example.Large", display: WindowLayoutDocument.DisplaySize(
                width: WindowLayoutDocument.maximumDisplayDimension,
                height: WindowLayoutDocument.maximumDisplayDimension
            )),
        ])])

        #expect(document.groups.first?.windows.count == 2)
    }

    /// Windows of one group can come from different displays: each window's frame is normalized
    /// against the display it was captured on, and keeps that display's size as its own hint.
    @Test func acceptsOneGroupWhoseWindowsWereCapturedOnDifferentDisplays() throws {
        let builtIn = CGRect(x: 0, y: 0, width: 1_710, height: 1_079)
        let external = CGRect(x: 1_710, y: -200, width: 2_560, height: 1_440)
        let builtInFrame = try #require(WindowLayoutGeometry.capture(
            window: CGRect(x: 100, y: 100, width: 800, height: 600),
            in: builtIn
        ))
        let externalFrame = try #require(WindowLayoutGeometry.capture(
            window: CGRect(x: 1_810, y: 0, width: 1_200, height: 900),
            in: external
        ))
        let builtInSize = WindowLayoutDocument.DisplaySize(width: builtIn.width, height: builtIn.height)
        let externalSize = WindowLayoutDocument.DisplaySize(width: external.width, height: external.height)
        let group = makeGroup(windows: [
            makeWindow("com.example.BuiltIn", display: builtInSize, frame: builtInFrame),
            makeWindow("com.example.External", display: externalSize, frame: externalFrame),
        ])

        let document = try makeDocument([group])

        let windows = try #require(document.groups.first?.windows)
        #expect(windows.map(\.display) == [builtInSize, externalSize])
        #expect(windows.map(\.frame) == [builtInFrame, externalFrame])
    }

    @Test func acceptsADocumentAtTheDocumentedCountLimits() throws {
        let groups = (0..<WindowLayoutDocument.maximumGroupCount).map { groupIndex in
            makeGroup(windows: (0..<WindowLayoutDocument.maximumWindowCountPerGroup).map { windowIndex in
                makeWindow("com.example.App\(groupIndex).\(windowIndex)")
            })
        }

        let document = try makeDocument(groups)

        #expect(document.groups.count == WindowLayoutDocument.maximumGroupCount)
        #expect(document.groups.allSatisfy { $0.windows.count == WindowLayoutDocument.maximumWindowCountPerGroup })
    }

    // MARK: - Refused documents

    @Test func refusesUnsupportedFormatVersions() {
        for version in [-1, 0, 2, 99] {
            #expect(throws: WindowLayoutDocument.ValidationError.unsupportedFormatVersion(version)) {
                _ = try makeDocument([makeGroup()], version: version)
            }
        }
    }

    @Test func refusesMoreGroupsThanTheLimit() {
        let groups = (0...WindowLayoutDocument.maximumGroupCount).map { _ in makeGroup() }

        #expect(throws: WindowLayoutDocument.ValidationError.tooManyGroups(count: groups.count)) {
            _ = try makeDocument(groups)
        }
    }

    @Test func refusesDuplicateGroupIdentifiers() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.duplicateGroupID(id)) {
            _ = try makeDocument([makeGroup(id: id), makeGroup(id: id)])
        }
    }

    @Test func refusesAGroupWithoutWindows() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.noWindows(groupID: id)) {
            _ = try makeDocument([makeGroup(id: id, windows: [])])
        }
    }

    @Test func refusesMoreWindowsInAGroupThanTheLimit() {
        let id = UUID()
        let windows = (0...WindowLayoutDocument.maximumWindowCountPerGroup).map { makeWindow("com.example.App\($0)") }

        #expect(throws: WindowLayoutDocument.ValidationError.tooManyWindows(groupID: id, count: windows.count)) {
            _ = try makeDocument([makeGroup(id: id, windows: windows)])
        }
    }

    @Test func refusesBundleIdentifiersThatRepeatIgnoringCase() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.duplicateBundleIdentifier(
            groupID: id,
            windowIndex: 1
        )) {
            _ = try makeDocument([makeGroup(id: id, windows: [
                makeWindow("com.apple.Safari"),
                makeWindow("com.apple.safari"),
            ])])
        }
    }

    @Test func refusesMalformedBundleIdentifiers() {
        let id = UUID()
        let identifiers = [
            "",
            " ",
            "com.example app",
            "com.example\tapp",
            "com.example\napp",
            "com.example:app",
            String(repeating: "a", count: WindowLayoutDocument.maximumBundleIdentifierLength + 1),
        ]

        for identifier in identifiers {
            #expect(throws: WindowLayoutDocument.ValidationError.malformedBundleIdentifier(
                groupID: id,
                windowIndex: 0
            )) {
                _ = try makeDocument([makeGroup(id: id, windows: [makeWindow(identifier)])])
            }
        }
    }

    @Test func refusesPathsAndURLsAsBundleIdentifiers() {
        let id = UUID()
        let identities = [
            "/Applications/Safari.app",
            "~/Applications/Safari.app",
            "file:///Applications/Safari.app",
            "https://example.com/apps/safari",
            "com.example/App",
        ]

        for identity in identities {
            #expect(throws: WindowLayoutDocument.ValidationError.malformedBundleIdentifier(
                groupID: id,
                windowIndex: 0
            )) {
                _ = try makeDocument([makeGroup(id: id, windows: [makeWindow(identity)])])
            }
        }
    }

    @Test func refusesNonfiniteGeometry() {
        let id = UUID()
        let frames = [
            RelativeWindowFrame(x: .nan, y: 0, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: .infinity, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: .nan, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: -.infinity),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    @Test func refusesZeroOrNegativeWindowDimensions() {
        let id = UUID()
        let frames = [
            RelativeWindowFrame(x: 0, y: 0, width: 0, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0),
            RelativeWindowFrame(x: 0, y: 0, width: -0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: -1),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    @Test func refusesGeometryBeyondWhatACaptureCanProduce() {
        let id = UUID()
        let tooWide = WindowLayoutGeometry.maximumRelativeDimension.nextUp.nextUp
        let tooFarRight = CGFloat(1).nextUp.nextUp
        let lowestAcceptedOrigin = -WindowLayoutGeometry.maximumRelativeDimension.nextUp
        let tooFarLeft = lowestAcceptedOrigin.nextDown
        let frames = [
            // A window cannot start right of the visible frame and still overlap it.
            RelativeWindowFrame(x: 1.5, y: 0, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: tooFarRight, y: 0, width: 0.5, height: 0.5),
            // Nor can its origin be further left than the widest capturable window.
            RelativeWindowFrame(x: -2.5, y: 0, width: 0.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: tooFarLeft, width: 0.5, height: 0.5),
            // A capture keeps at most twice the visible frame's size on either axis.
            RelativeWindowFrame(x: 0, y: 0, width: 2.5, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: tooWide, height: 0.5),
            RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 2.5),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    /// Bounds alone accept a frame that cannot overlap the visible frame at all: a relative origin
    /// at or past `1`, or a frame whose right/bottom edge stops before `0`.
    @Test func refusesAFrameThatDoesNotOverlapTheVisibleFrame() {
        let id = UUID()
        let frames = [
            RelativeWindowFrame(x: -1, y: 0.2, width: 0.2, height: 0.4),
            RelativeWindowFrame(x: 1, y: 0.2, width: 0.2, height: 0.4),
            RelativeWindowFrame(x: 0.2, y: -1, width: 0.4, height: 0.2),
            RelativeWindowFrame(x: 0.2, y: 1, width: 0.4, height: 0.2),
            RelativeWindowFrame(x: 2, y: 2, width: 0.5, height: 0.5),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    /// Capture keeps a window only when at least half its area is inside the visible frame, so a
    /// frame with a positive overlap but less than half its area inside is not capture output.
    @Test func refusesAFrameWithLessThanHalfItsAreaInside() {
        let id = UUID()
        let frames = [
            // A quarter of the width inside, full height: a quarter of the area.
            RelativeWindowFrame(x: -0.75, y: 0, width: 1, height: 1),
            // 0.49 of the width inside, full height: just under half the area.
            RelativeWindowFrame(x: -0.51, y: 0, width: 1, height: 1),
            // A tenth of the height inside, full width: a tenth of the area.
            RelativeWindowFrame(x: 0, y: -0.9, width: 1, height: 1),
            // Two-thirds of each axis inside: 4/9, just under half.
            RelativeWindowFrame(x: -0.166, y: -0.166, width: 0.5, height: 0.5),
            // Many representable steps under half is no longer rounding: only a few are tolerated.
            RelativeWindowFrame(x: -0.300000000000002, y: 0, width: 0.6, height: 1),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    /// The half-area rule is a share of the window, not an area in absolute points: a frame whose
    /// components are on the order of `1e-200` has both its own area and its visible area underflow
    /// to zero, so a product comparison reads `0 >= 0` and keeps a window with only a quarter of its
    /// area inside. The share has to be measured per axis instead.
    @Test func refusesATinyFrameWithLessThanHalfItsAreaInside() {
        let id = UUID()
        let frames = [
            // A quarter of the width inside, full height: a quarter of the area.
            RelativeWindowFrame(x: -0.75e-200, y: 0, width: 1e-200, height: 1e-200),
            // A quarter of the height inside, full width: a quarter of the area.
            RelativeWindowFrame(x: 0, y: -0.75e-200, width: 1e-200, height: 1e-200),
            // A tenth of each axis inside: a hundredth of the area.
            RelativeWindowFrame(x: -0.9e-200, y: -0.9e-200, width: 1e-200, height: 1e-200),
        ]

        for frame in frames {
            // The precondition this test exists for: both area products underflow, so an area
            // comparison cannot see the missing part.
            #expect(frame.width * frame.height == 0)
            #expect(frame.x + frame.width > 0 && frame.y + frame.height > 0)
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    /// A tiny frame that stops before the visible frame's origin has no overlap at all, so its share
    /// is zero rather than an underflowed area.
    @Test func refusesATinyFrameThatDoesNotOverlapTheVisibleFrame() {
        let id = UUID()
        let frames = [
            RelativeWindowFrame(x: -1e-200, y: 0, width: 1e-200, height: 1e-200),
            RelativeWindowFrame(x: -2e-200, y: 0, width: 1e-200, height: 1e-200),
            RelativeWindowFrame(x: 0, y: -1e-200, width: 1e-200, height: 1e-200),
        ]

        for frame in frames {
            expectGeometryRefusal(frame, groupID: id)
        }
    }

    /// The refusal path must not repeat untrusted input: a malformed identity can be a path, and a
    /// path in a logged error names a user's file. The error keeps the group and the window's
    /// position instead.
    @Test func refusalErrorsDoNotRepeatUntrustedInput() {
        let groups = [
            makeGroup(windows: [makeWindow("/Users/example/Documents/secret.pdf")]),
            makeGroup(windows: [makeWindow("com.example.Safari"), makeWindow("com.example.Safari")]),
        ]

        for group in groups {
            do {
                _ = try makeDocument([group])
                Issue.record("expected a validation error")
            } catch {
                for description in [String(describing: error), String(reflecting: error)] {
                    #expect(!description.contains("/"))
                    #expect(!description.lowercased().contains("secret"))
                    #expect(!description.contains("com.example"))
                }
            }
        }
    }

    @Test func refusesAWindowWhoseDisplayHintIsOutsideTheDocumentedLimits() {
        let id = UUID()
        let displays = [
            WindowLayoutDocument.DisplaySize(width: 0, height: 1_000),
            WindowLayoutDocument.DisplaySize(width: 1_000, height: -1),
            WindowLayoutDocument.DisplaySize(width: .nan, height: 1_000),
            WindowLayoutDocument.DisplaySize(width: 1_000, height: .infinity),
            WindowLayoutDocument.DisplaySize(width: WindowLayoutDocument.maximumDisplayDimension.nextUp, height: 1_000),
            WindowLayoutDocument.DisplaySize(width: 1_000, height: WindowLayoutDocument.maximumDisplayDimension.nextUp),
            WindowLayoutDocument.DisplaySize(width: 0.5, height: 1_000),
        ]

        for display in displays {
            #expect(throws: WindowLayoutDocument.ValidationError.displaySizeOutOfRange(groupID: id, windowIndex: 0)) {
                _ = try makeDocument([makeGroup(id: id, windows: [makeWindow(display: display)])])
            }
        }
    }

    /// The error names the window by its position, which is enough to locate the refusal without
    /// copying the identifier (or a path) into the error. Window index 0 is valid here.
    @Test func identifiesAnOffendingWindowByPositionNotIdentity() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.geometryOutOfRange(groupID: id, windowIndex: 1)) {
            _ = try makeDocument([makeGroup(id: id, windows: [
                makeWindow("com.example.First"),
                makeWindow("com.example.Second", frame: RelativeWindowFrame(x: -1, y: 0, width: 0.2, height: 0.2)),
            ])])
        }
    }

    /// Each window carries its own display hint, so an out-of-range hint on the second window is
    /// refused at that position while the first window's hint stays acceptable.
    @Test func refusesAnOutOfRangeDisplayHintOnASecondWindowByPosition() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.displaySizeOutOfRange(groupID: id, windowIndex: 1)) {
            _ = try makeDocument([makeGroup(id: id, windows: [
                makeWindow("com.example.First"),
                makeWindow("com.example.Second", display: WindowLayoutDocument.DisplaySize(width: 0, height: 1_000)),
            ])])
        }
    }

    @Test func refusesAPathLikeIdentifierWithoutEmbeddingThePathInTheError() {
        let id = UUID()

        #expect(throws: WindowLayoutDocument.ValidationError.malformedBundleIdentifier(groupID: id, windowIndex: 0)) {
            _ = try makeDocument([makeGroup(id: id, windows: [makeWindow("/Applications/Safari.app")])])
        }
    }

    // MARK: - Helpers

    private func expectGeometryRefusal(_ frame: RelativeWindowFrame, groupID: UUID) {
        #expect(throws: WindowLayoutDocument.ValidationError.geometryOutOfRange(
            groupID: groupID,
            windowIndex: 0
        )) {
            _ = try makeDocument([makeGroup(id: groupID, windows: [makeWindow("com.example.App", frame: frame)])])
        }
    }
}

private let standardDisplay = WindowLayoutDocument.DisplaySize(width: 1_710, height: 1_079)

private func makeWindow(
    _ bundleIdentifier: String = "com.apple.Safari",
    display: WindowLayoutDocument.DisplaySize = standardDisplay,
    frame: RelativeWindowFrame = RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
) -> WindowLayoutDocument.Window {
    WindowLayoutDocument.Window(bundleIdentifier: bundleIdentifier, display: display, frame: frame)
}

private func makeGroup(
    id: UUID = UUID(),
    windows: [WindowLayoutDocument.Window] = [makeWindow()]
) -> WindowLayoutDocument.Group {
    WindowLayoutDocument.Group(id: id, windows: windows)
}

private func makeDocument(
    _ groups: [WindowLayoutDocument.Group],
    version: Int = WindowLayoutDocument.currentFormatVersion
) throws -> WindowLayoutDocument {
    try WindowLayoutDocument(formatVersion: version, groups: groups)
}
