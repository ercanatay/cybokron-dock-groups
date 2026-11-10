import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutRestorePreviewPlannerTests {
    typealias F = LayoutPlannerFixtures
    static let groupID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    static func group(_ windows: [WindowLayoutDocument.Window]) -> WindowLayoutDocument.Group {
        WindowLayoutDocument.Group(id: groupID, windows: windows)
    }

    static func window(
        _ frame: RelativeWindowFrame,
        id: String = "com.example.A",
        display: (CGFloat, CGFloat) = (2560, 1351)
    ) -> WindowLayoutDocument.Window {
        WindowLayoutDocument.Window(
            bundleIdentifier: id,
            display: .init(width: display.0, height: display.1),
            frame: frame
        )
    }

    // MARK: - Gates

    @Test func invalidDisplaysPlanNothing() {
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5))])
        #expect(LayoutRestorePreviewPlanner.preview(group: group, displays: []) == .notPlanned(.invalidDisplayConfiguration))
        #expect(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.left]) == .notPlanned(.invalidDisplayConfiguration))
    }

    @Test func groupTheDocumentWouldRefuseIsNotPlanned() {
        let empty = Self.group([])
        let pathLike = Self.group([Self.window(RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5), id: "/Applications/Example.app")])
        let offScreen = Self.group([Self.window(RelativeWindowFrame(x: 0.9, y: 0, width: 0.5, height: 0.5))])
        for group in [empty, pathLike, offScreen] {
            #expect(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary]) == .notPlanned(.invalidGroup))
        }
    }

    // MARK: - Targets

    @Test func exactMatchOnPrimaryRestoresTheFrame() throws {
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0, y: 0.5, width: 0.5, height: 0.5))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary])).first ?? nil)
        #expect(target.displayIndex == 0)
        #expect(!target.usesPrimaryFallback)
        #expect(target.matchReason == DisplayTargetPlanner.MatchReason.exactMatch(hintSize: CGSize(width: 2560, height: 1351)))
        #expect(target.frame == CGRect(x: 0, y: 734.5, width: 1280, height: 675.5))
        #expect(target.topLeftFrame == CGRect(x: 0, y: 30, width: 1280, height: 675.5))
    }

    @Test func exactMatchOnNegativeCoordinateSecondary() throws {
        let frame = RelativeWindowFrame(x: 100.0 / 1920, y: 100.0 / 1055, width: 800.0 / 1920, height: 600.0 / 1055)
        let group = Self.group([Self.window(frame, display: (1920, 1055))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary, F.left])).first ?? nil)
        #expect(target.displayIndex == 1)
        #expect(!target.usesPrimaryFallback)
        #expect(F.isClose(target.frame, CGRect(x: -1820, y: 100, width: 800, height: 600)))
        #expect(F.isClose(target.topLeftFrame, CGRect(x: -1820, y: 740, width: 800, height: 600)))
        #expect(F.isInside(target.frame, F.left.visibleFrame))
    }

    @Test func displayAboveGivesNegativeAccessibilityY() throws {
        let frame = RelativeWindowFrame(x: 100.0 / 1680, y: 60.0 / 1050, width: 600.0 / 1680, height: 400.0 / 1050)
        let group = Self.group([Self.window(frame, display: (1680, 1050))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary, F.above])).first ?? nil)
        #expect(target.displayIndex == 1)
        #expect(F.isClose(target.topLeftFrame, CGRect(x: 100, y: -460, width: 600, height: 400)))
    }

    @Test func missingDisplayFallsBackToPrimary() throws {
        let frame = RelativeWindowFrame(x: 100.0 / 1920, y: 100.0 / 1055, width: 800.0 / 1920, height: 600.0 / 1055)
        let group = Self.group([Self.window(frame, display: (1920, 1055))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.above, F.primary])).first ?? nil)
        #expect(target.displayIndex == 1)
        #expect(target.usesPrimaryFallback)
        #expect(target.matchReason == .missingHint)
        #expect(F.isInside(target.frame, F.primary.visibleFrame))
    }

    @Test func ambiguousDisplaySizeFallsBackToPrimary() throws {
        let right = LayoutDisplay(frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1055),
                                  backingScaleFactor: 1, isPrimary: false)
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0.1, y: 0.1, width: 0.5, height: 0.5), display: (1920, 1055))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.left, F.primary, right])).first ?? nil)
        #expect(target.displayIndex == 1)
        #expect(target.usesPrimaryFallback)
        #expect(target.matchReason == .ambiguousMatch(count: 2, hintSize: CGSize(width: 1920, height: 1055)))
    }

    @Test func partlyOffScreenFrameIsClampedInside() throws {
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0.6, y: 0.6, width: 0.5, height: 0.5))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary])).first ?? nil)
        #expect(F.isInside(target.frame, F.primary.visibleFrame))
        #expect(target.frame == CGRect(x: 1280, y: 734.5, width: 1280, height: 675.5))
        #expect(F.isInside(target.topLeftFrame, CGRect(x: 0, y: 30, width: 2560, height: 1351)))
    }

    @Test func oversizedFrameShrinksToVisibleFrame() throws {
        let group = Self.group([Self.window(RelativeWindowFrame(x: -0.25, y: 0.25, width: 1.5, height: 0.5))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary])).first ?? nil)
        #expect(target.frame.width == 2560)
        #expect(target.frame.minX == 0)
        #expect(F.isInside(target.frame, F.primary.visibleFrame))
    }

    @Test func smallerCurrentDisplayStillContainsTarget() throws {
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0.5, y: 0.5, width: 0.6, height: 0.6))])
        let target = try #require(F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.simple])).first ?? nil)
        #expect(target.usesPrimaryFallback)
        #expect(F.isInside(target.frame, F.simple.visibleFrame))
        #expect(F.isInside(target.topLeftFrame, F.simple.visibleFrame))
    }

    @Test func decisionsFollowTheGroupOrder() throws {
        let group = Self.group([
            Self.window(RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5), id: "com.example.A", display: (1920, 1055)),
            Self.window(RelativeWindowFrame(x: 0.5, y: 0, width: 0.5, height: 0.5), id: "com.example.B"),
        ])
        let targets = F.targets(LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary, F.left]))
        #expect(targets.count == 2)
        #expect(targets.map { $0?.displayIndex } == [1, 0])
    }

    @Test func previewCarriesNoIdentifier() {
        let group = Self.group([Self.window(RelativeWindowFrame(x: 0, y: 0, width: 0.5, height: 0.5), id: "com.secret.Private")])
        let text = String(describing: LayoutRestorePreviewPlanner.preview(group: group, displays: [F.primary]))
            + String(describing: LayoutRestorePreviewPlanner.preview(group: group, displays: []))
        #expect(!text.contains("secret"))
    }

    // MARK: - Randomized capture → encode → decode → preview

    /// A random display arrangement: a primary display and, half the time, a secondary to its left
    /// (negative x), above it (negative Accessibility y) or to its right, with a different size.
    static func randomDisplays(_ generator: inout LayoutPlannerSeededGenerator) -> [LayoutDisplay] {
        let width = CGFloat(Int.random(in: 1280...3000, using: &generator))
        let height = CGFloat(Int.random(in: 800...2000, using: &generator))
        let dock = CGFloat(Int.random(in: 0...80, using: &generator))
        let primary = LayoutDisplay(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: dock, width: width, height: height - 25 - dock),
            backingScaleFactor: 2, isPrimary: true
        )
        guard Bool.random(using: &generator) else { return [primary] }

        var secondaryWidth = CGFloat(Int.random(in: 800...2500, using: &generator))
        if secondaryWidth == width { secondaryWidth += 1 }
        let secondaryHeight = CGFloat(Int.random(in: 600...1600, using: &generator))
        let origin: CGPoint
        switch Int.random(in: 0...2, using: &generator) {
        case 0: origin = CGPoint(x: -secondaryWidth, y: CGFloat(Int.random(in: -200...200, using: &generator)))
        case 1: origin = CGPoint(x: CGFloat(Int.random(in: -300...300, using: &generator)), y: height)
        default: origin = CGPoint(x: width, y: CGFloat(Int.random(in: -200...200, using: &generator)))
        }
        let frame = CGRect(origin: origin, size: CGSize(width: secondaryWidth, height: secondaryHeight))
        let secondary = LayoutDisplay(frame: frame, visibleFrame: frame, backingScaleFactor: 1, isPrimary: false)
        return Bool.random(using: &generator) ? [primary, secondary] : [secondary, primary]
    }

    @Test func randomWholeWindowsRoundTripThroughTheFile() throws {
        var generator = LayoutPlannerSeededGenerator(seed: 0x5EED_1A70)
        for _ in 0..<200 {
            let displays = Self.randomDisplays(&generator)
            let referenceHeight = try #require(LayoutDisplayConfiguration(displays: displays)).referenceHeight
            var expected: [(display: Int, appKit: CGRect, topLeft: CGRect)] = []
            var observations: [LayoutWindowObservation] = []
            for index in 0..<Int.random(in: 1...6, using: &generator) {
                let display = Int.random(in: 0..<displays.count, using: &generator)
                let visible = displays[display].visibleFrame
                let width = visible.width * CGFloat.random(in: 0.1...0.9, using: &generator)
                let height = visible.height * CGFloat.random(in: 0.1...0.9, using: &generator)
                let appKit = CGRect(
                    x: visible.minX + CGFloat.random(in: 0...(visible.width - width), using: &generator),
                    y: visible.minY + CGFloat.random(in: 0...(visible.height - height), using: &generator),
                    width: width, height: height
                )
                let topLeft = try #require(LayoutCoordinateConversion.convert(appKit, referenceHeight: referenceHeight))
                expected.append((display, appKit, topLeft))
                observations.append(F.app("com.example.app\(index)", [F.window(topLeft)]))
            }

            let plan = F.capture(observations, displays: displays)
            let group = try #require(F.capturedGroup(plan))
            #expect(F.decisions(plan) == expected.indices.map { .captured(windowIndex: $0, displayIndex: expected[$0].display) })

            let data = try WindowLayoutJSONEncoder.encode(try WindowLayoutDocument(groups: [group]))
            let decoded = try WindowLayoutJSONDecoder.decode(data)
            #expect(decoded.groups == [group])

            let targets = F.targets(LayoutRestorePreviewPlanner.preview(group: decoded.groups[0], displays: displays))
            #expect(targets.count == expected.count)
            for (target, want) in zip(targets, expected) {
                let target = try #require(target)
                #expect(target.displayIndex == want.display)
                #expect(!target.usesPrimaryFallback)
                #expect(F.isInside(target.frame, displays[want.display].visibleFrame))
                #expect(F.isClose(target.frame, want.appKit))
                #expect(F.isClose(target.topLeftFrame, want.topLeft))
            }
        }
    }

    @Test func randomWindowsOnChangedDisplaysStayInsideVisibleFrames() throws {
        var generator = LayoutPlannerSeededGenerator(seed: 0xD15B_1A75)
        var capturedCount = 0
        for _ in 0..<300 {
            let displays = Self.randomDisplays(&generator)
            let observations = (0..<Int.random(in: 1...6, using: &generator)).map { index in
                let width = CGFloat.random(in: 50...2500, using: &generator)
                let height = CGFloat.random(in: 50...1500, using: &generator)
                let frame = CGRect(x: CGFloat.random(in: -2500...3500, using: &generator),
                                   y: CGFloat.random(in: -1500...2500, using: &generator),
                                   width: width, height: height)
                return F.app("com.example.app\(index)", [F.window(frame)])
            }

            let plan = F.capture(observations, displays: displays)
            for decision in F.decisions(plan) {
                switch decision {
                case .captured: break
                case .skipped(let reason):
                    #expect([.lessThanHalfOnAnyDisplay, .ambiguousDisplay].contains(reason))
                }
            }
            guard let group = F.capturedGroup(plan) else { continue }
            capturedCount += 1
            let decoded = try WindowLayoutJSONDecoder.decode(
                try WindowLayoutJSONEncoder.encode(try WindowLayoutDocument(groups: [group]))
            )

            // Restore on the same displays and on a freshly drawn arrangement.
            let later = Self.randomDisplays(&generator)
            for current in [displays, later] {
                let height = try #require(LayoutDisplayConfiguration(displays: current)).referenceHeight
                let targets = F.targets(LayoutRestorePreviewPlanner.preview(group: decoded.groups[0], displays: current))
                #expect(targets.count == group.windows.count)
                for target in targets {
                    let target = try #require(target)
                    let visible = current[target.displayIndex].visibleFrame
                    #expect(F.isInside(target.frame, visible))
                    let topLeftVisible = try #require(LayoutCoordinateConversion.convert(visible, referenceHeight: height))
                    #expect(F.isInside(target.topLeftFrame, topLeftVisible))
                }
            }
        }
        #expect(capturedCount > 0)
    }
}
