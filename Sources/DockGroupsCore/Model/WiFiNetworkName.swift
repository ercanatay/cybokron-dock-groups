import Foundation

/// The name of a Wi-Fi network (its SSID) that a trigger waits for (triggers spec §1.5): matched
/// exactly as macOS reports it, case included. A valid name has 1 to 32 bytes in UTF-8 and no
/// control characters; a stored name that isn't valid is kept but its trigger doesn't run.
///
/// Only a name is kept: never a hardware address, a router or anything else that would stand in
/// for the network's location (spec §4.2 T-S9).
public struct WiFiNetworkName: Hashable, Sendable {
    /// The longest name Wi-Fi allows, in bytes.
    public static let maximumByteCount = 32

    public let name: String

    /// A name typed by the user or read from macOS; `nil` when it can't be a network name.
    public init?(_ name: String) {
        guard Self.isValid(name) else { return nil }
        self.name = name
    }

    /// A name as stored, valid or not (see `isValid`).
    init(stored name: String) {
        self.name = name
    }

    public var isValid: Bool { Self.isValid(name) }

    public static func isValid(_ name: String) -> Bool {
        (1...maximumByteCount).contains(name.utf8.count)
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
