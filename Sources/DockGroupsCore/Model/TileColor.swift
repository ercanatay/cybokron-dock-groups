import Foundation

/// An opaque sRGB color with 8-bit components, stored as a `#RRGGBB` string.
///
/// Components are quantized on creation so a color survives a save/load round trip unchanged.
public struct TileColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public static let defaultTileBackground = TileColor(red: 0x2F, green: 0x6F, blue: 0xEB)

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from 0...1 components; out-of-range values are clamped.
    public init(normalizedRed red: Double, green: Double, blue: Double) {
        func quantize(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: quantize(red), green: quantize(green), blue: quantize(blue))
    }

    /// Parses `#RRGGBB` or `RRGGBB` (case-insensitive).
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var redComponent: Double { Double(red) / 255 }
    public var greenComponent: Double { Double(green) / 255 }
    public var blueComponent: Double { Double(blue) / 255 }
}

extension TileColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = TileColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB, got \(hex)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
