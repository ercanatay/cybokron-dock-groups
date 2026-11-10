import AppKit

/// Reads the current displays for the window layout planners (design spec H). Reads only: it
/// changes no display setting and asks for no permission.
///
/// The list is passed on unvalidated; `LayoutDisplayConfiguration` decides whether the planners
/// accept it. An empty list, which is what this returns when AppKit reports no main screen, makes
/// the planners refuse with `invalidDisplayConfiguration`.
enum LayoutScreenProvider {
    /// One screen's values, as AppKit reported them.
    struct Screen: Equatable, Sendable {
        let frame: CGRect
        let visibleFrame: CGRect
        let backingScaleFactor: CGFloat
    }

    /// The displays macOS currently reports. Must run on the main thread, as `NSScreen` does.
    @MainActor
    static func currentDisplays() -> [LayoutDisplay] {
        displays(
            screens: NSScreen.screens.map {
                Screen(frame: $0.frame, visibleFrame: $0.visibleFrame, backingScaleFactor: $0.backingScaleFactor)
            },
            hasMainScreen: NSScreen.main != nil
        )
    }

    /// The displays for these screens, in the same order. Only the screen whose frame starts at
    /// the AppKit origin is primary (the menu-bar display); none or several primaries are left for
    /// `LayoutDisplayConfiguration` to refuse. Without a main screen the list is empty.
    static func displays(screens: [Screen], hasMainScreen: Bool) -> [LayoutDisplay] {
        guard hasMainScreen else { return [] }
        return screens.map {
            LayoutDisplay(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame,
                backingScaleFactor: $0.backingScaleFactor,
                isPrimary: $0.frame.origin == .zero
            )
        }
    }

    /// The configuration for the current displays, or `nil` when the planners would refuse it.
    @MainActor
    static func currentConfiguration() -> LayoutDisplayConfiguration? {
        LayoutDisplayConfiguration(displays: currentDisplays())
    }
}
