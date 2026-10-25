import Foundation

/// What a display is, as CoreGraphics and AppKit report it without any permission (triggers spec
/// §1.4, §2.3): vendor, model and serial numbers, its name and whether it's built in. Positions,
/// resolutions and which display is main don't belong to it.
///
/// Many displays report no serial number or a placeholder (this spec's Mac reported 0x01010101):
/// such a serial is dropped, and the display is then known by vendor, model and name — two
/// identical monitors without serials are two of the same kind (`DisplayArrangement`).
public struct DisplayIdentity: Hashable, Sendable {
    /// The longest name kept.
    public static let maximumNameLength = 100
    /// Serial numbers that say nothing about the display.
    public static let placeholderSerials: Set<UInt32> = [0, 0x0101_0101, 0xFFFF_FFFF]

    public let vendor: UInt32
    public let model: UInt32
    /// `nil` when the display reports none, or a placeholder.
    public let serial: UInt32?
    public let name: String
    public let isBuiltIn: Bool

    /// A display as read from the system: a placeholder serial is dropped, and the name loses its
    /// control characters and surrounding spaces and is cut to `maximumNameLength` characters.
    public init(vendor: UInt32, model: UInt32, serial: UInt32?, name: String, isBuiltIn: Bool) {
        self.vendor = vendor
        self.model = model
        self.serial = Self.meaningfulSerial(serial)
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = String(cleaned.prefix(Self.maximumNameLength))
        self.isBuiltIn = isBuiltIn
    }

    /// A display as stored: its name as it is, so one that isn't valid stays so (`isValid`).
    init(stored vendor: UInt32, model: UInt32, serial: UInt32?, name: String, isBuiltIn: Bool) {
        self.vendor = vendor
        self.model = model
        self.serial = Self.meaningfulSerial(serial)
        self.name = name
        self.isBuiltIn = isBuiltIn
    }

    /// Whether a trigger can wait for it: a name of at most `maximumNameLength` characters
    /// without control characters.
    public var isValid: Bool {
        name.count <= Self.maximumNameLength
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Whether `other` is this display: same vendor, model and kind, and the same serial when
    /// both have one, otherwise the same name.
    public func matches(_ other: DisplayIdentity) -> Bool {
        guard vendor == other.vendor, model == other.model, isBuiltIn == other.isBuiltIn else { return false }
        if let serial, let otherSerial = other.serial {
            return serial == otherSerial
        }
        return name == other.name
    }

    static func meaningfulSerial(_ serial: UInt32?) -> UInt32? {
        guard let serial, !placeholderSerials.contains(serial) else { return nil }
        return serial
    }
}

/// Which display a "display connects / disconnects" trigger waits for.
public enum DisplayMatch: Hashable, Sendable {
    /// Any display that isn't built in.
    case anyExternal
    /// This display (never a built-in one: closing the lid isn't an event).
    case display(DisplayIdentity)

    public var isValid: Bool {
        switch self {
        case .anyExternal: return true
        case .display(let identity): return identity.isValid && !identity.isBuiltIn
        }
    }

    /// How many of `displays` it matches.
    public func count(in displays: [DisplayIdentity]) -> Int {
        switch self {
        case .anyExternal: return displays.filter { !$0.isBuiltIn }.count
        case .display(let identity): return displays.filter(identity.matches).count
        }
    }
}

/// A set of displays a trigger waits to be connected together, exactly: no more, no fewer
/// (spec §1.4, "When These Displays Are Connected"). A display may appear twice (two identical
/// monitors).
public struct DisplayArrangement: Hashable, Sendable {
    /// The most displays an arrangement holds.
    public static let maximumCount = 8

    public let displays: [DisplayIdentity]

    public init(displays: [DisplayIdentity]) {
        self.displays = displays
    }

    public var isValid: Bool {
        (1...Self.maximumCount).contains(displays.count) && displays.allSatisfy(\.isValid)
    }

    /// Whether `connected` is exactly this arrangement: each of its displays matches a different
    /// connected one, and none is left over.
    public func matches(_ connected: [DisplayIdentity]) -> Bool {
        guard connected.count == displays.count, connected.count <= Self.maximumCount else { return false }
        var used = Array(repeating: false, count: connected.count)
        func assign(_ index: Int) -> Bool {
            guard index < displays.count else { return true }
            for candidate in connected.indices where !used[candidate] && displays[index].matches(connected[candidate]) {
                used[candidate] = true
                if assign(index + 1) { return true }
                used[candidate] = false
            }
            return false
        }
        return assign(0)
    }
}
