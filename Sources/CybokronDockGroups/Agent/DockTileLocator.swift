import AppKit
import ApplicationServices
import DockGroupsCore

/// Finds where a standalone group's Dock tile is, so its popup can open above it.
@MainActor
enum DockTileLocator {
    private static let dockBundleIdentifier = "com.apple.dock"
    /// Longest wait for the Dock to answer.
    private static let messagingTimeout: Float = 0.5

    /// The source of a popup opened by a click on the Dock tile of the app at `bundleURL`: the
    /// tile's center as the Dock reports it — which needs Accessibility access for this app — else
    /// the pointer, when it's over the Dock, else `.unspecified` (the popup then centers over the
    /// Dock).
    static func source(forTileOf bundleURL: URL) -> PopupSource {
        let screens = DockScreenReader.screens()
        if let center = tileCenter(of: bundleURL, screens: screens) {
            return .dockTile(center)
        }
        guard let edge = DockScreenReader.edge(on: screens) else { return .unspecified }
        return PopupPlacement.dockTileSource(pointer: NSEvent.mouseLocation, edge: edge, screens: screens)
    }

    /// The center of the Dock item for `bundleURL`, in global coordinates with the origin at the
    /// bottom left; `nil` without Accessibility access or such an item on a screen.
    private static func tileCenter(of bundleURL: URL, screens: [ScreenGeometry]) -> CGPoint? {
        guard AXIsProcessTrusted(),
              let primary = screens.first,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleIdentifier).first
        else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, messagingTimeout)
        let location = RunningApplicationLookup.normalizedLocation(of: bundleURL)
        for list in children(of: dockElement) where string(kAXRoleAttribute, of: list) == kAXListRole {
            for item in children(of: list) {
                guard let url = value(kAXURLAttribute, of: item) as? URL,
                      RunningApplicationLookup.normalizedLocation(of: url) == location,
                      let frame = frame(of: item)
                else { continue }
                // Accessibility frames have their origin at the top left of the primary screen.
                let center = CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
                return screens.contains { $0.frame.contains(center) } ? center : nil
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        value(attribute, of: element) as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: element),
              let size = value(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // The type IDs were checked above, so the casts can't fail.
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
