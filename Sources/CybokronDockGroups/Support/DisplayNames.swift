import AppKit
import DockGroupsCore
import SwiftUI

extension TileBackgroundStyle {
    var title: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .glass: return "Glass"
        }
    }
}

extension PopupAnchor {
    var title: String {
        switch self {
        case .dockCenter: return "Centered Over the Dock"
        case .dockIcon: return "Above the Clicked Icon"
        }
    }
}

extension TileColor {
    var color: Color {
        Color(.sRGB, red: redComponent, green: greenComponent, blue: blueComponent)
    }

    /// Converts a SwiftUI color to sRGB; `nil` for colors without RGB components (e.g. patterns).
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            normalizedRed: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}
