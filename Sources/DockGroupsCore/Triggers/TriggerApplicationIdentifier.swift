import Foundation

/// Internal in-memory validator for future app-presence triggers.
/// Not integrated with app, storage, or runtime.
/// See Apple developer documentation for bundle identifier conventions:
/// https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier
/// Allowed characters per CFBundleIdentifier convention: ASCII A-Z, a-z, 0-9, hyphen (-), period (.).
/// This validator uses a provisional 255 UTF-8 byte upper bound (project-specific, not an Apple claim).
internal struct TriggerApplicationIdentifier: Hashable, Sendable {
    let rawValue: String
    let matchKey: String

    init?(_ rawValue: String) {
        let bytes = rawValue.utf8.count
        guard bytes > 0, bytes <= 255 else { return nil }

        var hasAlphanumeric = false
        for scalar in rawValue.unicodeScalars {
            guard scalar.value < 128 else { return nil }
            let v = scalar.value
            let isAlphanumeric = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
            if isAlphanumeric {
                hasAlphanumeric = true
            } else if v == 0x2D || v == 0x2E {
                // hyphen or period: permitted
            } else {
                return nil
            }
        }
        guard hasAlphanumeric else { return nil }

        // Case-insensitive equality does NOT guarantee macOS targeted lookup accepts a changed case.
        // The original rawValue is retained for that reason.
        self.rawValue = rawValue
        self.matchKey = rawValue.lowercased()
    }

    // Case-insensitive equality only for grouping/hash; macOS targeted lookup may still require exact case.
    static func == (lhs: TriggerApplicationIdentifier, rhs: TriggerApplicationIdentifier) -> Bool {
        lhs.matchKey == rhs.matchKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(matchKey)
    }
}
