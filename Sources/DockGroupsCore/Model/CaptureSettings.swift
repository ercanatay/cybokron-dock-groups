import Foundation

/// How capturing the open apps lists them, as the capture sheet's last choices left it: the order
/// and whether only apps with an open window start selected. Stored in `preferences.json` under
/// `"capture"`, only when it isn't the default (`PopupPreferences`), and never more than an order
/// and a switch: nothing here names an app, a location or anything to run.
public struct CaptureSettings: Hashable, Sendable {
    /// The order the open apps are listed — and added — in.
    public enum Order: String, Codable, CaseIterable, Sendable {
        /// The app brought to the front most recently first (`ActivationHistory`), then the others
        /// by their frontmost window on screen, launch date and name.
        case recentlyUsed
        /// A to Z, the way Finder sorts names.
        case name
    }

    public var order: Order
    /// Whether only the apps with an open window (on screen or not) start selected. The others are
    /// still listed: window information decides nothing but the first selection (spec Decision 4).
    public var selectsOnlyAppsWithWindows: Bool

    public init(order: Order = .recentlyUsed, selectsOnlyAppsWithWindows: Bool = false) {
        self.order = order
        self.selectsOnlyAppsWithWindows = selectsOnlyAppsWithWindows
    }

    /// Whether these are the settings a new install has.
    public var isDefault: Bool { self == CaptureSettings() }
}

extension CaptureSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case order, selectsOnlyAppsWithWindows
    }

    /// Each value is read on its own: an unknown order, a value of another type or a missing key is
    /// its default, and other keys are ignored. Only a value that isn't an object at all is
    /// unreadable, which `PopupPreferences` reads as the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        order = container.decodeLeniently(Order.self, forKey: .order) ?? defaults.order
        selectsOnlyAppsWithWindows = container.decodeLeniently(Bool.self, forKey: .selectsOnlyAppsWithWindows)
            ?? defaults.selectsOnlyAppsWithWindows
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(selectsOnlyAppsWithWindows, forKey: .selectsOnlyAppsWithWindows)
    }
}
