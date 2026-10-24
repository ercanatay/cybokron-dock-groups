import Foundation

/// How an item opens besides being opened: a delay, applied by Open All and Start (clicking the
/// item opens it right away), and — for files, folders and websites — the app that opens it
/// instead of its default app.
///
/// There are exactly these two options: no arguments, commands or scripts. The chosen app is kept
/// by bundle identifier only and checked every time before it's used (`ItemOpenerPolicy`), so a
/// groups file or backup can't make an item run code it couldn't run on its own.
public struct ItemLaunchOptions: Hashable, Sendable {
    /// The delays offered (seconds).
    public static let allowedDelays = [0, 1, 2, 3, 5, 10, 15, 30, 60]
    public static let maximumDelay = 60

    /// Seconds Open All and Start wait before opening the item; 0 opens it right away. Always
    /// within 0…`maximumDelay`.
    public private(set) var delay: Int
    /// The app that opens the item instead of its default app; `nil` for the default app.
    public private(set) var opener: ItemOpener?

    /// `delay` is clamped to 0…`maximumDelay`.
    public init(delay: Int = 0, opener: ItemOpener? = nil) {
        self.delay = min(max(delay, 0), Self.maximumDelay)
        self.opener = opener
    }

    /// Whether these are the defaults: no delay, the default app. Then nothing is written.
    public var isEmpty: Bool { delay == 0 && opener == nil }

    /// The options an item of `kind` can have: apps open themselves, so they have no opener.
    public func allowed(for kind: AppReference.Kind) -> ItemLaunchOptions {
        kind == .application ? ItemLaunchOptions(delay: delay) : self
    }

    /// The same options without the opener.
    public var withoutOpener: ItemLaunchOptions { ItemLaunchOptions(delay: delay) }
}

/// The app chosen to open an item. Identified by its bundle identifier only — never by a location,
/// so a groups file or backup can't point it at a program somewhere on disk; LaunchServices finds
/// the app when the item is opened.
public struct ItemOpener: Hashable, Sendable {
    /// The longest name kept.
    public static let maximumNameLength = 80

    public let bundleIdentifier: String
    /// The app's name when it was chosen, shown when the app isn't on this Mac.
    public let name: String

    /// `nil` unless `bundleIdentifier` is a bundle identifier: 1…255 letters, digits, "." and "-".
    /// A blank `name` is the bundle identifier; a long one is cut.
    public init?(bundleIdentifier: String, name: String) {
        guard Self.isBundleIdentifier(bundleIdentifier) else { return nil }
        self.bundleIdentifier = bundleIdentifier
        let words = name.unicodeScalars
            .map { $0.properties.generalCategory == .control ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        self.name = words.isEmpty ? bundleIdentifier : String(words.prefix(Self.maximumNameLength))
    }

    /// The bundle identifier as LaunchServices compares them, ignoring case.
    public var normalizedBundleIdentifier: String { bundleIdentifier.lowercased() }

    /// Whether `text` can be a bundle identifier: 1…255 ASCII letters, digits, "." and "-".
    public static func isBundleIdentifier(_ text: String) -> Bool {
        guard (1...255).contains(text.utf8.count) else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }
}

extension ItemOpener: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name
    }

    /// An opener that isn't a bundle identifier fails to decode; the item then opens with its
    /// default app (`AppReference` reads it leniently).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        guard let opener = ItemOpener(bundleIdentifier: bundleIdentifier, name: name ?? "") else {
            throw DecodingError.dataCorruptedError(forKey: .bundleIdentifier, in: container, debugDescription: "Not a bundle identifier")
        }
        self = opener
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
    }
}
