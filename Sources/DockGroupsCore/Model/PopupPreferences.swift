import Foundation

/// Light or dark look of the popup panel. The app's own windows always follow the system setting.
public enum PanelTheme: String, Codable, CaseIterable, Sendable {
    case dark
    case light
    /// Follows the macOS appearance setting.
    case system
}

/// App-wide preferences, stored in `preferences.json`: the popup's look, the layout and position
/// defaults (a group can override those with its own `PopupOverrides`), the global shortcuts, the
/// Most Used list, the standalone groups' Dock menus, and whether the app looks for updates on its
/// own.
public struct PopupPreferences: Hashable, Sendable {
    public static let defaultMaxRows = 4
    public static let defaultMostUsedSessionSeconds = Int(UsageTracker.defaultSessionLength)
    /// Session lengths offered in Settings: 2, 5, 10, 15, 30 and 60 minutes.
    public static let allowedMostUsedSessionSeconds = [120, 300, 600, 900, 1800, 3600]

    public var theme: PanelTheme
    /// Frosted-glass blur behind the panel instead of a solid background.
    public var usesFrostedGlass: Bool
    public var columns: PopupColumns
    /// Caps the popup's height; extra rows scroll.
    public var maxRows: Int
    /// Shows app names under the icons.
    public var showsTitles: Bool
    public var anchor: PopupAnchor
    /// Free Layout: apps stay in the popup grid cell they're dragged to, and moving one doesn't
    /// shift the others (see `FreeLayout`). Off, the apps fill the grid in list order.
    public var usesFreeLayout: Bool
    /// Whether the modifiers plus 1…9 open the first nine groups' popups from any app.
    public var shortcutsEnabled: Bool
    /// Modifier keys of the global shortcuts.
    public var shortcutModifiers: ShortcutModifiers
    /// Whether the menu bar shows the Most Used list. Launches are counted either way.
    public var showsMostUsed: Bool
    /// How many apps the Most Used list shows; one of `MostUsedRanking.allowedLimits`.
    public var mostUsedLimit: Int
    /// Apps launched within this many seconds of each other count as launched together; one of
    /// `allowedMostUsedSessionSeconds`.
    public var mostUsedSessionSeconds: Int
    /// Whether the app checks GitHub for a new release at launch and every six hours. "Check for
    /// Updates…" works either way.
    public var automaticallyChecksForUpdates: Bool
    /// Whether a standalone group's Dock icon has a menu (right-click or Control-click) with the
    /// group's apps, Open All, Hide All and Close All. The Dock asks only apps it shows as running
    /// for a menu, so with this on a running group agent is a regular app: it has a running
    /// indicator in the Dock and appears in the app switcher.
    public var showsStandaloneDockMenus: Bool

    public init(
        theme: PanelTheme = .dark,
        usesFrostedGlass: Bool = true,
        columns: PopupColumns = .auto,
        maxRows: Int = PopupPreferences.defaultMaxRows,
        showsTitles: Bool = true,
        anchor: PopupAnchor = .dockCenter,
        usesFreeLayout: Bool = false,
        shortcutsEnabled: Bool = true,
        shortcutModifiers: ShortcutModifiers = .controlOption,
        showsMostUsed: Bool = true,
        mostUsedLimit: Int = MostUsedRanking.defaultLimit,
        mostUsedSessionSeconds: Int = PopupPreferences.defaultMostUsedSessionSeconds,
        automaticallyChecksForUpdates: Bool = true,
        showsStandaloneDockMenus: Bool = true
    ) {
        self.theme = theme
        self.usesFrostedGlass = usesFrostedGlass
        self.columns = columns
        self.maxRows = maxRows
        self.showsTitles = showsTitles
        self.anchor = anchor
        self.usesFreeLayout = usesFreeLayout
        self.shortcutsEnabled = shortcutsEnabled
        self.shortcutModifiers = shortcutModifiers
        self.showsMostUsed = showsMostUsed
        self.mostUsedLimit = mostUsedLimit
        self.mostUsedSessionSeconds = mostUsedSessionSeconds
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.showsStandaloneDockMenus = showsStandaloneDockMenus
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

    /// The preferences with out-of-range values replaced by their defaults.
    public func sanitized() -> PopupPreferences {
        var copy = self
        if !MostUsedRanking.allowedLimits.contains(copy.mostUsedLimit) {
            copy.mostUsedLimit = MostUsedRanking.defaultLimit
        }
        if !Self.allowedMostUsedSessionSeconds.contains(copy.mostUsedSessionSeconds) {
            copy.mostUsedSessionSeconds = Self.defaultMostUsedSessionSeconds
        }
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
        case usesFreeLayout = "freeLayout"
        case shortcutsEnabled = "globalShortcutsEnabled"
        case shortcutModifiers = "globalShortcutModifiers"
        case showsMostUsed = "popupShowsMostUsed"
        case mostUsedLimit
        case mostUsedSessionSeconds
        case automaticallyChecksForUpdates
        case showsStandaloneDockMenus = "standaloneDockMenu"
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
        usesFreeLayout = container.decodeLeniently(Bool.self, forKey: .usesFreeLayout) ?? defaults.usesFreeLayout
        shortcutsEnabled = container.decodeLeniently(Bool.self, forKey: .shortcutsEnabled) ?? defaults.shortcutsEnabled
        shortcutModifiers = container.decodeLeniently(ShortcutModifiers.self, forKey: .shortcutModifiers)
            ?? defaults.shortcutModifiers
        showsMostUsed = container.decodeLeniently(Bool.self, forKey: .showsMostUsed) ?? defaults.showsMostUsed
        mostUsedLimit = container.decodeLeniently(Int.self, forKey: .mostUsedLimit)
            .flatMap { MostUsedRanking.allowedLimits.contains($0) ? $0 : nil }
            ?? defaults.mostUsedLimit
        mostUsedSessionSeconds = container.decodeLeniently(Int.self, forKey: .mostUsedSessionSeconds)
            .flatMap { Self.allowedMostUsedSessionSeconds.contains($0) ? $0 : nil }
            ?? defaults.mostUsedSessionSeconds
        automaticallyChecksForUpdates = container.decodeLeniently(Bool.self, forKey: .automaticallyChecksForUpdates)
            ?? defaults.automaticallyChecksForUpdates
        showsStandaloneDockMenus = container.decodeLeniently(Bool.self, forKey: .showsStandaloneDockMenus)
            ?? defaults.showsStandaloneDockMenus
    }
}
