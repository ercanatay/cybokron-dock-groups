import Foundation

/// What the user notes about a group item: another name to show (the alias), tags and task notes.
/// All three are optional, typed by the user and kept on this Mac only, in the groups file and
/// backups. The popup filter finds items by them.
///
/// The values are cleaned up on the way in (`init`), so the limits below always hold, whatever a
/// groups file or backup contains.
public struct ItemDetails: Hashable, Sendable {
    /// Characters (as the user sees them, `Character`) an alias can have.
    public static let maximumAliasLength = 80
    public static let maximumTagCount = 12
    /// Characters a tag can have.
    public static let maximumTagLength = 32
    /// Characters the task notes can have.
    public static let maximumNotesLength = 500

    /// Another name, shown instead of the item's name; `nil` when there's none.
    public private(set) var alias: String?
    /// Distinct tags (ignoring case and diacritics, as the popup filter compares text), in the
    /// order they were entered.
    public private(set) var tags: [String]
    /// Free text that may span several lines; `nil` when there's none.
    public private(set) var notes: String?

    /// - alias: surrounding whitespace trimmed, line breaks turned into spaces, control characters
    ///   removed, and cut to `maximumAliasLength`; blank means none.
    /// - tags: each trimmed, with runs of whitespace turned into one space, a leading "#" dropped,
    ///   control characters removed and cut to `maximumTagLength`; blank tags and repeats are
    ///   dropped, and only the first `maximumTagCount` are kept.
    /// - notes: surrounding whitespace trimmed, line breaks turned into "\n", other control
    ///   characters removed, and cut to `maximumNotesLength`; blank means none.
    public init(alias: String? = nil, tags: [String] = [], notes: String? = nil) {
        self.alias = alias.flatMap { Self.singleLine($0, maximumLength: Self.maximumAliasLength) }
        self.tags = Self.sanitizedTags(tags)
        self.notes = notes.flatMap(Self.sanitizedNotes)
    }

    /// Whether the item has no alias, tags or notes.
    public var isEmpty: Bool { alias == nil && tags.isEmpty && notes == nil }

    /// The tags typed into a text field, separated by commas: "," and the commas of the app's
    /// languages, "،" (Arabic, Persian), "，" and "、" (Chinese, Japanese). Cleaned up as `init`
    /// cleans tags.
    public static func tags(fromCommaSeparated text: String) -> [String] {
        sanitizedTags(splitAtCommas(text))
    }

    /// `tags(fromCommaSeparated:)` without the `maximumTagCount` limit: every distinct tag typed,
    /// so an editor can say how many wouldn't be kept.
    static func allTags(fromCommaSeparated text: String) -> [String] {
        sanitizedTags(splitAtCommas(text), maximumCount: .max)
    }

    private static func splitAtCommas(_ text: String) -> [String] {
        let separators: Set<Character> = [",", "،", "，", "、"]
        return text.split { separators.contains($0) }.map(String.init)
    }

    /// The tags for a text field: "finance, q3".
    public var commaSeparatedTags: String { tags.joined(separator: ", ") }

    /// Characters of the task notes `notesSummary` shows at most.
    public static let maximumSummaryLength = 80

    /// The task notes on one line, for a mention such as the popup's tooltip: their first line, cut
    /// to `maximumSummaryLength` characters, ending in "…" when it was cut or more lines follow.
    /// `nil` without notes.
    public var notesSummary: String? {
        let lines = (notes ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let summary = Self.excerpt(of: first, maximumLength: Self.maximumSummaryLength)
        return lines.count > 1 && !summary.hasSuffix("…") ? summary + "…" : summary
    }

    /// `line` without surrounding spaces and, when it's longer than `maximumLength` characters, cut
    /// to fit with "…" at the end.
    static func excerpt(of line: String, maximumLength: Int) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maximumLength else { return trimmed }
        return String(trimmed.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Sanitizing

    private static func sanitizedTags(_ raw: [String], maximumCount: Int = maximumTagCount) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw where result.count < maximumCount {
            var text = Substring(tag)
            text = text.drop { $0.isWhitespace || $0 == "#" }
            guard let tag = singleLine(String(text), maximumLength: maximumTagLength),
                  seen.insert(PopupFilter.normalize(tag)).inserted
            else { continue }
            result.append(tag)
        }
        return result
    }

    /// `text` on one line: runs of whitespace (line breaks included) become a single space,
    /// control characters go, and it's cut to `maximumLength` characters. `nil` when blank.
    private static func singleLine(_ text: String, maximumLength: Int) -> String? {
        let words = withoutControlCharacters(text, keepingLineFeeds: false, replacingWith: " ")
            .split(whereSeparator: \.isWhitespace)
        return trimmed(words.joined(separator: " "), maximumLength: maximumLength)
    }

    private static func sanitizedNotes(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return trimmed(withoutControlCharacters(unified, keepingLineFeeds: true, replacingWith: nil), maximumLength: maximumNotesLength)
    }

    /// `text` without control characters (Unicode category Cc). Line feeds are kept when asked;
    /// other line breaks and tabs become `replacement` when there is one. Format characters such
    /// as the zero-width joiner of emoji sequences stay.
    private static func withoutControlCharacters(_ text: String, keepingLineFeeds: Bool, replacingWith replacement: Character?) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard scalar.properties.generalCategory == .control else {
                result.append(scalar)
                continue
            }
            if scalar == "\n", keepingLineFeeds {
                result.append(scalar)
            } else if let replacement, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                result.append(contentsOf: replacement.unicodeScalars)
            }
        }
        return String(result)
    }

    /// `text` trimmed and cut to `maximumLength` characters (then trimmed again); `nil` when blank.
    private static func trimmed(_ text: String, maximumLength: Int) -> String? {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }
}
