import Foundation

/// Names the store gives new groups — default names, duplicates and groups made from a template —
/// unique among the active and archived groups. Names are compared as merging a backup compares
/// them: trimmed, ignoring case. Names the user types (renaming) and names of restored groups are
/// kept as they are.
public enum GroupNaming {
    /// The form two names are compared in: trimmed, a blank one as the default name, lowercased.
    public static func comparisonKey(_ name: String) -> String {
        (DockGroup.sanitizedName(name) ?? DockGroup.defaultName).lowercased()
    }

    /// `name` when no group has it, else "name 2", "name 3" … — the first that's free.
    public static func uniqueName(_ name: String, taken: some Sequence<String>) -> String {
        let base = DockGroup.sanitizedName(name) ?? DockGroup.defaultName
        let keys = Set(taken.map(comparisonKey))
        guard keys.contains(comparisonKey(base)) else { return base }
        var number = 2
        while keys.contains(comparisonKey("\(base) \(number)")) {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// The name of a duplicate of a group named `name`: "Coding copy", or "Coding copy 2",
    /// "Coding copy 3" … when that's taken. A duplicate of a duplicate counts on from the
    /// original's name: duplicating "Coding copy" gives "Coding copy 2", not "Coding copy copy".
    public static func copyName(of name: String, taken: some Sequence<String>) -> String {
        let keys = Set(taken.map(comparisonKey))
        let base = original(ofCopyNamed: DockGroup.sanitizedName(name) ?? DockGroup.defaultName)
        let first = copy(of: base)
        guard keys.contains(comparisonKey(first)) else { return first }
        var number = 2
        while keys.contains(comparisonKey(copy(of: base, number: number))) {
            number += 1
        }
        return copy(of: base, number: number)
    }

    // MARK: - Copy names

    private static func copy(of name: String) -> String {
        Localization.format("core.group.copyName", "%@ copy", name)
    }

    private static func copy(of name: String, number: Int) -> String {
        Localization.format("core.group.copyName.numbered", "%1$@ copy %2$ld", name, number)
    }

    /// `name` without a copy suffix in the user's language ("Coding copy 2" → "Coding"); `name`
    /// itself when it has none.
    static func original(ofCopyNamed name: String) -> String {
        for pattern in [copyPattern(numbered: true), copyPattern(numbered: false)].compactMap({ $0 }) {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: range),
                  let baseRange = Range(match.range(withName: "base"), in: name)
            else { continue }
            let base = String(name[baseRange])
            if let trimmed = DockGroup.sanitizedName(base) { return trimmed }
        }
        return name
    }

    /// The localized copy name as a pattern matching a whole name: its text literally, the name as
    /// the group `base`, the number as digits — whatever order a translation puts them in.
    private static func copyPattern(numbered: Bool) -> NSRegularExpression? {
        let marker = "\u{1}"
        let sample = numbered ? copy(of: marker, number: 7) : copy(of: marker)
        var pattern = NSRegularExpression.escapedPattern(for: sample)
        guard pattern.contains(marker) else { return nil }
        pattern = pattern.replacingOccurrences(of: marker, with: "(?<base>.+)")
        if numbered {
            guard pattern.contains("7") else { return nil }
            pattern = pattern.replacingOccurrences(of: "7", with: "[0-9]+")
        }
        return try? NSRegularExpression(pattern: "^\(pattern)$", options: [.caseInsensitive])
    }
}
