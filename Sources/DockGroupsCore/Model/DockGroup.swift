import Foundation

/// A user-defined, named collection of apps that the Dock presents as a single tile.
///
/// The order of groups is the order of the list kept by `GroupStore`, and it is persisted as-is;
/// the order of `apps` is the display order inside the group.
public struct DockGroup: Identifiable, Hashable, Sendable {
    /// The name of a new group, in the user's language.
    public static var defaultName: String { Localization.string("core.group.defaultName", "New Group") }
    public static let defaultEmoji = "🗂️"

    public let id: UUID
    public var name: String
    public var emoji: String
    /// Member apps in display order. Bundle identifiers are unique within a group.
    public var apps: [AppReference]
    public var tile: TileAppearance
    /// Whether the group's tile stays in the Dock while the group isn't open.
    public var isPinned: Bool
    /// Whether the group has its own app (a standalone agent) with its own icon in the Dock.
    public var isStandalone: Bool
    /// Per-group popup settings; fields left `nil` fall back to the app-wide defaults.
    public var popup: PopupOverrides
    /// The popup grid cell (row by row) of each app while Free Layout is on, keyed by normalized
    /// bundle identifier; see `FreeLayout`. Empty until apps are arranged in Free Layout. Each
    /// cell holds at most one app, and only the group's apps have cells.
    public var freeLayoutSlots: [String: Int]

    public init(
        id: UUID = UUID(),
        name: String,
        emoji: String = DockGroup.defaultEmoji,
        apps: [AppReference] = [],
        tile: TileAppearance = TileAppearance(),
        isPinned: Bool = false,
        isStandalone: Bool = false,
        popup: PopupOverrides = PopupOverrides(),
        freeLayoutSlots: [String: Int] = [:]
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.apps = apps
        self.tile = tile
        self.isPinned = isPinned
        self.isStandalone = isStandalone
        self.popup = popup
        self.freeLayoutSlots = Self.sanitizedFreeLayoutSlots(freeLayoutSlots, apps: apps)
    }
}

// MARK: - Input sanitizing

extension DockGroup {
    /// Returns `raw` without surrounding whitespace, or `nil` when nothing is left.
    public static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reduces `raw` to a single character, keeping the most recently typed one, or `nil` when empty.
    public static func sanitizedEmoji(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).last.map(String.init)
    }

    /// `slots` limited to the cells of `apps` (keys are matched case-insensitively), without
    /// negative cells and with each cell used once: an app earlier in `apps` keeps a contested cell.
    public static func sanitizedFreeLayoutSlots(_ slots: [String: Int], apps: [AppReference]) -> [String: Int] {
        guard !slots.isEmpty else { return [:] }
        var normalized: [String: Int] = [:]
        for (key, slot) in slots where slot >= 0 {
            normalized[key.lowercased()] = min(slot, normalized[key.lowercased()] ?? slot)
        }
        var sanitized: [String: Int] = [:]
        var taken = Set<Int>()
        for app in apps {
            let id = app.normalizedBundleIdentifier
            guard sanitized[id] == nil, let slot = normalized[id], taken.insert(slot).inserted else { continue }
            sanitized[id] = slot
        }
        return sanitized
    }

    /// `apps` sorted by name, A to Z, the way Finder sorts names; apps with the same name keep
    /// their order.
    public static func sortedByName(_ apps: [AppReference]) -> [AppReference] {
        apps.enumerated()
            .sorted { lhs, rhs in
                switch lhs.element.name.localizedStandardCompare(rhs.element.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

// MARK: - Codable

extension DockGroup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, apps, tile, isPinned, isStandalone, popup, freeLayoutSlots
    }

    /// Identity, name and app list are required; display preferences are decoded leniently so a value
    /// written by a newer version of the app never makes the whole group list unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        apps = try container.decodeIfPresent([AppReference].self, forKey: .apps) ?? []
        emoji = container.decodeLeniently(String.self, forKey: .emoji) ?? DockGroup.defaultEmoji
        tile = container.decodeLeniently(TileAppearance.self, forKey: .tile) ?? TileAppearance()
        isPinned = container.decodeLeniently(Bool.self, forKey: .isPinned) ?? false
        isStandalone = container.decodeLeniently(Bool.self, forKey: .isStandalone) ?? false
        popup = container.decodeLeniently(PopupOverrides.self, forKey: .popup) ?? PopupOverrides()
        freeLayoutSlots = Self.sanitizedFreeLayoutSlots(
            container.decodeLeniently([String: Int].self, forKey: .freeLayoutSlots) ?? [:],
            apps: apps
        )
    }

    /// Free Layout cells are written only once there are any, so groups that never used Free
    /// Layout are saved as before.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(apps, forKey: .apps)
        try container.encode(tile, forKey: .tile)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isStandalone, forKey: .isStandalone)
        try container.encode(popup, forKey: .popup)
        if !freeLayoutSlots.isEmpty {
            try container.encode(freeLayoutSlots, forKey: .freeLayoutSlots)
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional preference, treating a missing *or unreadable* value as absent.
    func decodeLeniently<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}
