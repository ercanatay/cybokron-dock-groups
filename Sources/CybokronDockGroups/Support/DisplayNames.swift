import AppKit
import DockGroupsCore
import SwiftUI

extension TileBackgroundStyle {
    var title: String {
        switch self {
        case .solid: return L10n.Choices.tileSolid
        case .gradient: return L10n.Choices.tileGradient
        case .glass: return L10n.Choices.tileGlass
        }
    }
}

extension PopupAnchor {
    var title: String {
        switch self {
        case .dockCenter: return L10n.Choices.anchorDockCenter
        case .dockIcon: return L10n.Choices.anchorDockIcon
        }
    }
}

extension Text {
    /// Text with its inline Markdown (`code`, **bold**, links) rendered, as `Text` does for string
    /// literals; a looked-up string (`L10n`) would otherwise show its Markdown as it is.
    init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self.init((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
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

extension GroupSwitching.OnStart {
    var title: String {
        switch self {
        case .leaveOthers: return L10n.Switching.GroupWindow.leaveOthers
        case .hidePreviousGroup: return L10n.Switching.GroupWindow.hidePreviousGroup
        case .hideAllOtherApps: return L10n.Switching.GroupWindow.hideAllOtherApps
        case .quitPreviousGroup: return L10n.Switching.GroupWindow.quitPreviousGroup
        }
    }
}

extension GroupSwitching.OnFinish {
    var title: String {
        switch self {
        case .hideApps: return L10n.Switching.GroupWindow.hideApps
        case .quitApps: return L10n.Switching.GroupWindow.quitApps
        case .leaveApps: return L10n.Switching.GroupWindow.leaveApps
        }
    }
}

extension GroupSwitching.AfterFinish {
    var title: String {
        switch self {
        case .showPreviousGroup: return L10n.Switching.GroupWindow.showPreviousGroup
        case .nothing: return L10n.Switching.GroupWindow.doNothing
        }
    }
}
