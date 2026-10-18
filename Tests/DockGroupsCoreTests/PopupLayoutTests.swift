import CoreGraphics
import Testing
@testable import DockGroupsCore

@Suite("Popup grid layout")
struct PopupGridLayoutTests {
    private let metrics = PopupGridMetrics(cellWidth: 80, cellHeight: 90, spacing: 6, padding: 12)

    @Test func autoKeepsTheStandardWidth() {
        let small = PopupGridLayout(itemCount: 2, columns: .auto, maxRows: 4)
        let large = PopupGridLayout(itemCount: 14, columns: .auto, maxRows: 4)

        #expect(small.columns == PopupGridLayout.standardColumnCount)
        #expect(small.rows == 1)
        #expect(large.columns == PopupGridLayout.standardColumnCount)
        #expect(large.rows == 3)
        #expect(small.visibleSize(metrics: metrics).width == large.visibleSize(metrics: metrics).width)
    }

    @Test func fixedColumnsShrinkToFitTheGroup() {
        let few = PopupGridLayout(itemCount: 2, columns: .fixed(4), maxRows: 4)
        let many = PopupGridLayout(itemCount: 9, columns: .fixed(4), maxRows: 4)

        #expect(few.columns == 2)
        #expect(few.rows == 1)
        #expect(many.columns == 4)
        #expect(many.rows == 3)
    }

    @Test func maxRowsCapsTheHeightAndScrolls() {
        let layout = PopupGridLayout(itemCount: 23, columns: .fixed(5), maxRows: 3)

        #expect(layout.rows == 5)
        #expect(layout.visibleRows == 3)
        #expect(layout.scrolls)
        #expect(layout.contentHeight(metrics: metrics) > layout.visibleSize(metrics: metrics).height)
    }

    @Test func groupThatFitsDoesNotScroll() {
        let layout = PopupGridLayout(itemCount: 10, columns: .fixed(5), maxRows: 2)

        #expect(layout.rows == 2)
        #expect(!layout.scrolls)
    }

    @Test func emptyGroupKeepsOneRow() {
        let fixed = PopupGridLayout(itemCount: 0, columns: .fixed(3), maxRows: 4)
        let auto = PopupGridLayout(itemCount: 0, columns: .auto, maxRows: 4)

        #expect(fixed.columns == 1)
        #expect(fixed.rows == 1)
        #expect(auto.rows == 1)
        #expect(!auto.scrolls)
    }

    @Test func outOfRangeCountsAreClamped() {
        #expect(PopupGridLayout(itemCount: 30, columns: .fixed(50), maxRows: 4).columns == PopupOverrides.allowedCountRange.upperBound)
        #expect(PopupGridLayout(itemCount: 3, columns: .fixed(-2), maxRows: 0).columns == 1)
        #expect(PopupGridLayout(itemCount: 3, columns: .fixed(1), maxRows: 0).visibleRows == 1)
    }

    @Test func sizesIncludeCellsSpacingAndPadding() {
        let layout = PopupGridLayout(itemCount: 7, columns: .fixed(3), maxRows: 2)

        // 3 columns: 3 × 80 + 2 × 6 + 2 × 12; 2 of 3 rows visible: 2 × 90 + 6 + 2 × 12.
        #expect(layout.visibleSize(metrics: metrics) == CGSize(width: 276, height: 210))
        let allRows: CGFloat = 3 * 90 + 2 * 6 + 2 * 12
        #expect(layout.contentHeight(metrics: metrics) == allRows)
    }
}

@Suite("Popup placement")
struct PopupPlacementTests {
    private let size = CGSize(width: 400, height: 200)
    private let bottomDockScreen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 80, width: 1440, height: 795)
    )
    /// A status item in the menu bar above `bottomDockScreen`'s visible frame.
    private let menuBarItem = CGRect(x: 1100, y: 876, width: 28, height: 24)

    @Test func centersOverABottomDock() {
        let frame = PopupPlacement.frame(size: size, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen)

        #expect(frame.midX == 720)
        #expect(frame.minY == 80 + PopupPlacement.dockGap)
        #expect(frame.size == size)
    }

    @Test func sitsBesideASideDock() {
        let leftScreen = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 70, y: 0, width: 1370, height: 875)
        )
        let rightScreen = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1370, height: 875)
        )

        let left = PopupPlacement.frame(size: size, anchor: .dockCenter, dockEdge: .left, screen: leftScreen)
        let right = PopupPlacement.frame(size: size, anchor: .dockCenter, dockEdge: .right, screen: rightScreen)

        #expect(left.minX == 70 + PopupPlacement.dockGap)
        #expect(left.midY == 450)
        #expect(right.maxX == 1370 - PopupPlacement.dockGap)
        #expect(right.midY == 450)
    }

    @Test func aboveTheIconFollowsTheIconAndStaysOnScreen() {
        let centered = PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .dockTile(CGPoint(x: 500, y: 40))
        )
        let nearEdge = PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .dockTile(CGPoint(x: 1420, y: 40))
        )

        #expect(centered.midX == 500)
        #expect(nearEdge.maxX == 1440 - PopupPlacement.screenMargin)
    }

    @Test func aboveTheIconWithoutALocationCentersOverTheDock() {
        let iconAnchored = PopupPlacement.frame(size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen)
        let centered = PopupPlacement.frame(size: size, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen)

        #expect(iconAnchored == centered)
    }

    @Test func centeredAnchorIgnoresTheIconLocation() {
        let frame = PopupPlacement.frame(
            size: size, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen,
            source: .dockTile(CGPoint(x: 100, y: 40))
        )
        let fromMenuBar = PopupPlacement.frame(
            size: size, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen,
            source: .menuBarItem(menuBarItem)
        )

        #expect(frame.midX == 720)
        #expect(fromMenuBar == frame)
    }

    @Test func aboveTheIconFollowsATileBesideASideDock() {
        let leftScreen = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 70, y: 0, width: 1370, height: 875)
        )

        let frame = PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .left, screen: leftScreen,
            source: .dockTile(CGPoint(x: 35, y: 300))
        )

        #expect(frame.minX == 70 + PopupPlacement.dockGap)
        #expect(frame.midY == 300)
    }

    @Test func aboveTheIconHangsFromTheMenuBarItem() {
        let frame = PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .menuBarItem(menuBarItem)
        )

        #expect(frame.midX == menuBarItem.midX)
        #expect(frame.maxY == 875 - PopupPlacement.menuBarGap)
        #expect(frame.size == size)
    }

    @Test func menuBarPopupStaysOnScreenAndBelowTheMenuBar() {
        let nearRightEdge = CGRect(x: 1410, y: 876, width: 28, height: 24)
        let tall = CGSize(width: 400, height: 2000)

        let frame = PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .menuBarItem(nearRightEdge)
        )
        let tallFrame = PopupPlacement.frame(
            size: tall, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .menuBarItem(menuBarItem)
        )

        #expect(frame.maxX == 1440 - PopupPlacement.screenMargin)
        #expect(frame.maxY == 875 - PopupPlacement.menuBarGap)
        #expect(tallFrame.maxY == 875 - PopupPlacement.menuBarGap, "the header stays visible")
    }

    @Test func iconOffTheScreenCountsAsNoIcon() {
        let hiddenItem = CGRect(x: 3000, y: 876, width: 28, height: 24)
        let centered = PopupPlacement.frame(size: size, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen)

        #expect(PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .menuBarItem(hiddenItem)
        ) == centered)
        #expect(PopupPlacement.frame(
            size: size, anchor: .dockIcon, dockEdge: .bottom, screen: bottomDockScreen,
            source: .dockTile(CGPoint(x: -50, y: 40))
        ) == centered)
    }

    @Test func oversizedPopupKeepsItsTopVisible() {
        let tall = CGSize(width: 400, height: 2000)
        let frame = PopupPlacement.frame(size: tall, anchor: .dockCenter, dockEdge: .bottom, screen: bottomDockScreen)

        #expect(frame.maxY == bottomDockScreen.visibleFrame.maxY - PopupPlacement.screenMargin)
    }

    @Test func maximumSizeLeavesMarginsAndTheDockGap() {
        let maximum = PopupPlacement.maximumSize(on: bottomDockScreen)

        #expect(maximum.width == 1440 - 2 * PopupPlacement.screenMargin)
        #expect(maximum.height == 795 - 2 * PopupPlacement.screenMargin - PopupPlacement.dockGap)
    }

    @Test func dockEdgeComesFromTheOrientationOrTheScreenInsets() {
        let leftScreen = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 64, y: 0, width: 1376, height: 875)
        )
        let hiddenDock = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )

        #expect(DockEdge(orientation: "right", screen: bottomDockScreen) == .right)
        #expect(DockEdge(orientation: nil, screen: leftScreen) == .left)
        #expect(DockEdge(orientation: "sideways", screen: bottomDockScreen) == .bottom)
        #expect(DockEdge(orientation: nil, screen: hiddenDock) == .bottom)
    }

    @Test func dockScreenIsTheOneTheDockTakesSpaceFrom() {
        let external = ScreenGeometry(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let withDock = ScreenGeometry(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 70, width: 1920, height: 1010)
        )
        let main = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )

        #expect(PopupPlacement.dockScreenIndex(edge: .bottom, screens: [main, withDock], mouseLocation: nil) == 1)
        #expect(PopupPlacement.dockScreenIndex(edge: .bottom, screens: [main, external], mouseLocation: CGPoint(x: 2000, y: 500)) == 1)
        #expect(PopupPlacement.dockScreenIndex(edge: .bottom, screens: [main, external], mouseLocation: nil) == 0)
        #expect(PopupPlacement.dockScreenIndex(edge: .bottom, screens: [], mouseLocation: nil) == nil)
    }
}

@Suite("Popup source")
struct PopupSourceTests {
    /// The built-in display with the Dock at the bottom, and an external display to its right.
    private let main = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 80, width: 1440, height: 795)
    )
    private let external = ScreenGeometry(
        frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055)
    )
    private var screens: [ScreenGeometry] { [main, external] }

    @Test func locationIsTheTileOrTheMenuBarItemCenter() {
        #expect(PopupSource.unspecified.location == nil)
        #expect(PopupSource.dockTile(CGPoint(x: 10, y: 20)).location == CGPoint(x: 10, y: 20))
        #expect(PopupSource.menuBarItem(CGRect(x: 100, y: 876, width: 20, height: 24)).location == CGPoint(x: 110, y: 888))
    }

    @Test func aboveTheIconOpensOnTheScreenWithTheIcon() {
        let tileOnExternal = PopupSource.dockTile(CGPoint(x: 2400, y: -150))
        let itemOnExternal = PopupSource.menuBarItem(CGRect(x: 3000, y: 876, width: 28, height: 24))

        #expect(PopupPlacement.screenIndex(anchor: .dockIcon, source: tileOnExternal, edge: .bottom, screens: screens, mouseLocation: nil) == 1)
        #expect(PopupPlacement.screenIndex(anchor: .dockIcon, source: itemOnExternal, edge: .bottom, screens: screens, mouseLocation: nil) == 1)
    }

    @Test func otherwiseTheDockScreenIsUsed() {
        let tileOnExternal = PopupSource.dockTile(CGPoint(x: 2400, y: -150))
        let nowhere = PopupSource.dockTile(CGPoint(x: -500, y: -500))

        #expect(PopupPlacement.screenIndex(anchor: .dockCenter, source: tileOnExternal, edge: .bottom, screens: screens, mouseLocation: nil) == 0)
        #expect(PopupPlacement.screenIndex(anchor: .dockIcon, source: .unspecified, edge: .bottom, screens: screens, mouseLocation: nil) == 0)
        #expect(PopupPlacement.screenIndex(anchor: .dockIcon, source: nowhere, edge: .bottom, screens: screens, mouseLocation: nil) == 0)
        #expect(PopupPlacement.screenIndex(anchor: .dockIcon, source: .unspecified, edge: .bottom, screens: [], mouseLocation: nil) == nil)
    }

    @Test func clicksOnTheDockAreTileClicks() {
        let onMainDock = CGPoint(x: 700, y: 30)
        let onHiddenExternalDock = CGPoint(x: 2000, y: -170)

        #expect(PopupPlacement.dockTileSource(pointer: onMainDock, edge: .bottom, screens: screens) == .dockTile(onMainDock))
        #expect(PopupPlacement.dockTileSource(pointer: onHiddenExternalDock, edge: .bottom, screens: screens) == .dockTile(onHiddenExternalDock))
    }

    @Test func clicksAwayFromTheDockAreNot() {
        #expect(PopupPlacement.dockTileSource(pointer: CGPoint(x: 700, y: 500), edge: .bottom, screens: screens) == .unspecified)
        #expect(PopupPlacement.dockTileSource(pointer: CGPoint(x: 700, y: 30), edge: .left, screens: screens) == .unspecified)
        #expect(PopupPlacement.dockTileSource(pointer: CGPoint(x: -100, y: 30), edge: .bottom, screens: screens) == .unspecified)
    }

    @Test func sideDocksAreMeasuredFromTheirEdge() {
        let onLeftDock = CGPoint(x: 40, y: 450)
        let onRightDock = CGPoint(x: 3340, y: 300)

        #expect(PopupPlacement.dockTileSource(pointer: onLeftDock, edge: .left, screens: screens) == .dockTile(onLeftDock))
        #expect(PopupPlacement.dockTileSource(pointer: onRightDock, edge: .right, screens: screens) == .dockTile(onRightDock))
        #expect(PopupPlacement.dockTileSource(pointer: CGPoint(x: 2400, y: 300), edge: .right, screens: screens) == .unspecified)
    }

    @Test func aDockWiderThanTheReachCountsWhole() {
        let wideDock = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 200, width: 1440, height: 675)
        )
        let pointer = CGPoint(x: 700, y: 190)

        #expect(PopupPlacement.dockTileSource(pointer: pointer, edge: .bottom, screens: [wideDock]) == .dockTile(pointer))
    }
}
