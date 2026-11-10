import AppKit
import CoreGraphics
import Testing
@testable import DockGroupsCore

struct LayoutScreenProviderTests {
    private typealias Screen = LayoutScreenProvider.Screen

    private static let primary = Screen(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 63, width: 2560, height: 1347),
        backingScaleFactor: 2
    )
    /// Left of and below the primary: negative x and y, standard resolution.
    private static let left = Screen(
        frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1055),
        backingScaleFactor: 1
    )

    @Test func noScreensGiveNoConfiguration() {
        let displays = LayoutScreenProvider.displays(screens: [], hasMainScreen: true)
        #expect(displays.isEmpty)
        #expect(LayoutDisplayConfiguration(displays: displays) == nil)
    }

    @Test func noMainScreenGivesNoDisplays() {
        let displays = LayoutScreenProvider.displays(screens: [Self.primary], hasMainScreen: false)
        #expect(displays.isEmpty)
        #expect(LayoutDisplayConfiguration(displays: displays) == nil)
        let plan = LayoutCapturePlanner.plan(groupID: UUID(), permission: .granted, observations: [], displays: displays)
        #expect(plan == .notCaptured(.invalidDisplayConfiguration, apps: []))
    }

    @Test func negativeSecondaryAndMixedScalesArePassedOn() throws {
        let displays = LayoutScreenProvider.displays(screens: [Self.left, Self.primary], hasMainScreen: true)
        #expect(displays == [
            LayoutDisplay(frame: Self.left.frame, visibleFrame: Self.left.visibleFrame, backingScaleFactor: 1, isPrimary: false),
            LayoutDisplay(frame: Self.primary.frame, visibleFrame: Self.primary.visibleFrame, backingScaleFactor: 2, isPrimary: true),
        ])
        let configuration = try #require(LayoutDisplayConfiguration(displays: displays))
        #expect(configuration.primaryIndex == 1)
        #expect(configuration.referenceHeight == 1440)
    }

    @Test func noScreenAtTheOriginIsRefused() {
        let displays = LayoutScreenProvider.displays(screens: [Self.left], hasMainScreen: true)
        #expect(displays.map(\.isPrimary) == [false])
        #expect(LayoutDisplayConfiguration(displays: displays) == nil)
    }

    @Test func twoScreensAtTheOriginAreRefused() {
        let displays = LayoutScreenProvider.displays(screens: [Self.primary, Self.primary], hasMainScreen: true)
        #expect(displays.map(\.isPrimary) == [true, true])
        #expect(LayoutDisplayConfiguration(displays: displays) == nil)
    }

    @Test func invalidScaleIsLeftForTheConfigurationToRefuse() {
        let screen = Screen(frame: Self.primary.frame, visibleFrame: Self.primary.visibleFrame, backingScaleFactor: 0)
        let displays = LayoutScreenProvider.displays(screens: [screen], hasMainScreen: true)
        #expect(displays.first?.backingScaleFactor == 0)
        #expect(LayoutDisplayConfiguration(displays: displays) == nil)
    }

    /// Reads the current screens; values depend on the machine, so only their shape is checked.
    @MainActor
    @Test func currentDisplaysMirrorNSScreen() {
        let displays = LayoutScreenProvider.currentDisplays()
        if NSScreen.main == nil {
            #expect(displays.isEmpty)
        } else {
            #expect(displays.count == NSScreen.screens.count)
            #expect(displays.filter(\.isPrimary).count <= 1 || LayoutScreenProvider.currentConfiguration() == nil)
        }
    }
}
