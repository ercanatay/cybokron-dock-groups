import Foundation

/// Light or dark look of the popup panel. The app's own windows always follow the system setting.
public enum PanelTheme: String, Codable, CaseIterable, Sendable {
    case dark
    case light
    /// Follows the macOS appearance setting.
    case system
}

/// App-wide popup preferences. A group can override the layout and position fields with its own
/// `PopupOverrides`; theme and background apply to every group.
public struct PopupPreferences: Hashable, Sendable {
    public static let defaultMaxRows = 4

    public var theme: PanelTheme
    /// Frosted-glass blur behind the panel instead of a solid background.
    public var usesFrostedGlass: Bool
    public var columns: PopupColumns
    /// Caps the popup's height; extra rows scroll.
    public var maxRows: Int
    /// Shows app names under the icons.
    public var showsTitles: Bool
    public var anchor: PopupAnchor

    public init(
        theme: PanelTheme = .dark,
        usesFrostedGlass: Bool = true,
        columns: PopupColumns = .auto,
        maxRows: Int = PopupPreferences.defaultMaxRows,
        showsTitles: Bool = true,
        anchor: PopupAnchor = .dockCenter
    ) {
        self.theme = theme
        self.usesFrostedGlass = usesFrostedGlass
        self.columns = columns
        self.maxRows = maxRows
        self.showsTitles = showsTitles
        self.anchor = anchor
    }

    /// The settings a group's popup uses: the group's overrides where it has them, these defaults
    /// everywhere else.
    public func resolved(with overrides: PopupOverrides) -> PopupSettings {
        PopupSettings(
            columns: overrides.columns ?? columns,
            maxRows: overrides.maxRows ?? maxRows,
            showsTitles: overrides.showsTitles ?? showsTitles,
            anchor: overrides.anchor ?? anchor
        )
    }

    /// The preferences with out-of-range counts replaced by their defaults.
    public func sanitized() -> PopupPreferences {
        var copy = self
        if !PopupOverrides.allowedCountRange.contains(copy.maxRows) {
            copy.maxRows = Self.defaultMaxRows
        }
        if case .fixed(let count) = copy.columns, !PopupOverrides.allowedCountRange.contains(count) {
            copy.columns = .auto
        }
        return copy
    }
}

/// Fully resolved layout and position of one group's popup.
public struct PopupSettings: Hashable, Sendable {
    public var columns: PopupColumns
    public var maxRows: Int
    public var showsTitles: Bool
    public var anchor: PopupAnchor

    public init(columns: PopupColumns, maxRows: Int, showsTitles: Bool, anchor: PopupAnchor) {
        self.columns = columns
        self.maxRows = maxRows
        self.showsTitles = showsTitles
        self.anchor = anchor
    }
}

// MARK: - Codable

extension PopupPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case theme = "panelTheme"
        case usesFrostedGlass = "glassyStyle"
        case columns = "popupColumns"
        case maxRows = "popupMaxRows"
        case showsTitles = "popupShowsTitles"
        case anchor = "popupAnchor"
    }

    /// Every field is optional: a missing, unknown or out-of-range value falls back to its default,
    /// and unknown keys are ignored, so a file written by another version always loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PopupPreferences()
        theme = container.decodeLeniently(PanelTheme.self, forKey: .theme) ?? defaults.theme
        usesFrostedGlass = container.decodeLeniently(Bool.self, forKey: .usesFrostedGlass) ?? defaults.usesFrostedGlass
        columns = container.decodeLeniently(PopupColumns.self, forKey: .columns) ?? defaults.columns
        maxRows = container.decodeLeniently(Int.self, forKey: .maxRows)
            .flatMap { PopupOverrides.allowedCountRange.contains($0) ? $0 : nil }
            ?? defaults.maxRows
        showsTitles = container.decodeLeniently(Bool.self, forKey: .showsTitles) ?? defaults.showsTitles
        anchor = container.decodeLeniently(PopupAnchor.self, forKey: .anchor) ?? defaults.anchor
    }
}
