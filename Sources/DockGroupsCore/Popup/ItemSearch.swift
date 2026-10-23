import Foundation

/// How well a group item matches what was typed into the popup filter; lower is better.
public enum ItemSearchRank: Int, Comparable, Sendable {
    /// The name or alias starts with the query (`PopupFilter.Rank.prefix`).
    case titlePrefix
    /// A later word of the name or alias starts with the query (`PopupFilter.Rank.wordPrefix`).
    case titleWordPrefix
    /// The query appears inside the name or alias (`PopupFilter.Rank.contains`).
    case titleContains
    /// Every word typed starts a word of the name, the alias or a tag.
    case tags
    /// Every word typed starts a word of the name, the alias, a tag or the task notes, and at
    /// least one is found in the notes only.
    case notes

    init(_ rank: PopupFilter.Rank) {
        switch rank {
        case .prefix: self = .titlePrefix
        case .wordPrefix: self = .titleWordPrefix
        case .contains: self = .titleContains
        }
    }

    public static func < (lhs: ItemSearchRank, rhs: ItemSearchRank) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An item found by the popup filter.
public struct ItemSearchMatch: Equatable, Sendable {
    /// What, besides the name and alias, made the item match: shown so the user sees why.
    public enum Reason: Equatable, Sendable {
        /// A tag that a word typed starts a word of.
        case tag(String)
        /// The line of the task notes that a word typed was found in, cut to
        /// `ItemSearchIndex.maximumExcerptLength` characters.
        case notes(String)
    }

    /// The item's index in the list the index was built from.
    public let index: Int
    public let rank: ItemSearchRank
    /// `nil` when the name or alias matched.
    public let reason: Reason?
}

/// The popup filter over a group's items: by name and alias as `PopupFilter` filters names, then by
/// tags and task notes. Built once for a list of items, so typing doesn't normalize them again.
///
/// Matching happens in two stages:
/// 1. The whole query against the name and the alias, with `PopupFilter.rank`. For items without
///    an alias that's exactly what `PopupFilter.filter` does with their names.
/// 2. For items stage 1 didn't find: the query's words (separated by spaces), each of which must
///    start a word of the name, the alias, a tag or the task notes ("fatura" finds "faturayı";
///    "a b" doesn't find everything containing an "a" and a "b"). These rank after every stage 1
///    match: `.tags` when the words were all found in the name, alias or tags, `.notes` otherwise.
///
/// Within a rank, items keep their list order. Case, diacritics and width are ignored
/// (`PopupFilter.normalize`).
public struct ItemSearchIndex: Sendable {
    /// Characters of task notes `ItemSearchMatch.Reason.notes` shows at most.
    public static let maximumExcerptLength = 80

    private struct Text: Sendable {
        let original: String
        let normalized: String

        init(_ original: String) {
            self.original = original
            normalized = PopupFilter.normalize(original)
        }
    }

    private struct Entry: Sendable {
        /// The normalized alias (when there is one) and name.
        let titles: [String]
        let tags: [Text]
        let noteLines: [Text]
    }

    private let entries: [Entry]

    public init(items: [GroupItem]) {
        entries = items.map { item in
            Entry(
                titles: ([item.details.alias].compactMap { $0 } + [item.name]).map(PopupFilter.normalize),
                tags: item.details.tags.map(Text.init),
                noteLines: (item.details.notes?.split(separator: "\n") ?? []).map { Text(String($0)) }
            )
        }
    }

    /// The items matching `query`, best first and in list order within a rank. An empty (or
    /// all-whitespace) query matches every item, in order.
    public func matches(for query: String) -> [ItemSearchMatch] {
        let needle = PopupFilter.normalize(query)
        guard !needle.isEmpty else {
            return entries.indices.map { ItemSearchMatch(index: $0, rank: .titlePrefix, reason: nil) }
        }
        var seen = Set<String>()
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }
        var matches: [ItemSearchMatch] = []
        for (index, entry) in entries.enumerated() {
            if let rank = entry.titles.compactMap({ PopupFilter.rank(ofNormalized: $0, normalizedQuery: needle) }).min() {
                matches.append(ItemSearchMatch(index: index, rank: ItemSearchRank(rank), reason: nil))
            } else if let match = Self.wordMatch(of: words, in: entry, index: index) {
                matches.append(match)
            }
        }
        matches.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
        }
        return matches
    }

    /// Stage 2: every word starts a word of a title, a tag or a line of the notes.
    private static func wordMatch(of words: [String], in entry: Entry, index: Int) -> ItemSearchMatch? {
        var tag: String?
        var notesLine: String?
        for word in words {
            if entry.titles.contains(where: { startsAWord(word, in: $0) }) { continue }
            if let found = entry.tags.first(where: { startsAWord(word, in: $0.normalized) }) {
                tag = tag ?? found.original
            } else if let found = entry.noteLines.first(where: { startsAWord(word, in: $0.normalized) }) {
                notesLine = notesLine ?? found.original
            } else {
                return nil
            }
        }
        if let notesLine {
            return ItemSearchMatch(index: index, rank: .notes, reason: .notes(excerpt(of: notesLine)))
        }
        return ItemSearchMatch(index: index, rank: .tags, reason: tag.map(ItemSearchMatch.Reason.tag))
    }

    private static func startsAWord(_ word: String, in text: String) -> Bool {
        guard let rank = PopupFilter.rank(ofNormalized: text, normalizedQuery: word) else { return false }
        return rank != .contains
    }

    private static func excerpt(of line: String) -> String {
        ItemDetails.excerpt(of: line, maximumLength: maximumExcerptLength)
    }
}
