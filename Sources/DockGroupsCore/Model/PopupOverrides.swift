import Foundation

/// Where a group's popup opens.
public enum PopupAnchor: String, Codable, CaseIterable, Sendable {
    /// Centered over the Dock.
    case dockCenter
    /// Above the group's Dock tile (needs Accessibility access to locate the tile).
    case dockIcon
}

/// Column count of the popup grid.
public enum PopupColumns: Hashable, Sendable {
    /// Keeps the standard panel size.
    case auto
    /// A fixed number of columns; the popup shrinks to fit the group.
    case fixed(Int)
}

extension PopupColumns: Codable {
    private static let autoToken = "auto"

    /// Stored as the string `"auto"` or a column count.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let token = try? container.decode(String.self), token == Self.autoToken {
            self = .auto
            return
        }
        let count = try container.decode(Int.self)
        guard PopupOverrides.allowedCountRange.contains(count) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Column count \(count) out of range")
        }
        self = .fixed(count)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode(Self.autoToken)
        case .fixed(let count): try container.encode(count)
        }
    }
}

/// A group's own popup settings. Every field is optional: `nil` means "use the app-wide default".
public struct PopupOverrides: Hashable, Sendable {
    /// Valid range for fixed column and row counts.
    public static let allowedCountRange = 1...10

    public var columns: PopupColumns?
    /// Caps the popup's height; extra rows scroll.
    public var maxRows: Int?
    /// Shows app names under the icons.
    public var showsTitles: Bool?
    public var anchor: PopupAnchor?

    public init(
        columns: PopupColumns? = nil,
        maxRows: Int? = nil,
        showsTitles: Bool? = nil,
        anchor: PopupAnchor? = nil
    ) {
        self.columns = columns
        self.maxRows = maxRows
        self.showsTitles = showsTitles
        self.anchor = anchor
    }

    /// `true` when the group follows the app-wide defaults for everything.
    public var isEmpty: Bool { self == PopupOverrides() }
}

extension PopupOverrides: Codable {
    private enum CodingKeys: String, CodingKey {
        case columns, maxRows, showsTitles, anchor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = container.decodeLeniently(PopupColumns.self, forKey: .columns)
        maxRows = container.decodeLeniently(Int.self, forKey: .maxRows)
            .flatMap { Self.allowedCountRange.contains($0) ? $0 : nil }
        showsTitles = container.decodeLeniently(Bool.self, forKey: .showsTitles)
        anchor = container.decodeLeniently(PopupAnchor.self, forKey: .anchor)
    }
}
