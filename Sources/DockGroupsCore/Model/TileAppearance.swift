import Foundation

/// What a group's Dock tile shows.
public enum TileKind: String, Codable, CaseIterable, Sendable {
    /// The group's emoji on a colored background.
    case emoji
    /// A grid of the member apps' icons.
    case grid
}

/// How the tile background is painted.
public enum TileBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case solid
    case gradient
    case glass
}

/// Appearance preferences for a group's Dock tile.
public struct TileAppearance: Hashable, Sendable {
    public var kind: TileKind
    public var backgroundStyle: TileBackgroundStyle
    public var backgroundColor: TileColor

    public init(
        kind: TileKind = .emoji,
        backgroundStyle: TileBackgroundStyle = .solid,
        backgroundColor: TileColor = .defaultTileBackground
    ) {
        self.kind = kind
        self.backgroundStyle = backgroundStyle
        self.backgroundColor = backgroundColor
    }
}

extension TileAppearance: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, backgroundStyle, backgroundColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TileAppearance()
        kind = container.decodeLeniently(TileKind.self, forKey: .kind) ?? defaults.kind
        backgroundStyle = container.decodeLeniently(TileBackgroundStyle.self, forKey: .backgroundStyle)
            ?? defaults.backgroundStyle
        backgroundColor = container.decodeLeniently(TileColor.self, forKey: .backgroundColor)
            ?? defaults.backgroundColor
    }
}
