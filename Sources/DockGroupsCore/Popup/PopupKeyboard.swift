import Foundation

/// Type-to-filter in the popup: which apps match what the user typed, best matches first.
///
/// Matching ignores case and diacritics ("ç" matches "c", "É" matches "e"), plus a few letters that
/// have no decomposition of their own ("ı", "ø", "ł", "đ", "ß").
public enum PopupFilter {
    /// Letters folded by hand: the diacritic-insensitive comparison leaves them as they are.
    private static let extraFolding: [Character: String] = [
        "ı": "i", "ø": "o", "ł": "l", "đ": "d", "ß": "ss", "æ": "ae", "œ": "oe",
    ]

    /// `text` lowercased, without diacritics and with surrounding whitespace trimmed.
    public static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var result = ""
        result.reserveCapacity(folded.count)
        for character in folded {
            if let replacement = extraFolding[character] {
                result += replacement
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How well a name matches the query; lower is better.
    public enum Rank: Int, Comparable, Sendable {
        /// The name starts with the query.
        case prefix
        /// A later word of the name starts with the query.
        case wordPrefix
        /// The query appears somewhere inside the name.
        case contains

        public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How `name` matches `query`, or `nil` when it doesn't. An empty query matches nothing here;
    /// `filter` treats it as "no filter".
    public static func rank(of name: String, query: String) -> Rank? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }
        let haystack = normalize(name)
        guard let range = haystack.range(of: needle) else { return nil }
        if range.lowerBound == haystack.startIndex {
            return .prefix
        }
        // Any occurrence that starts a word (after a space, dash, dot, …) counts as a word prefix.
        var searchStart = haystack.startIndex
        while let match = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before = haystack[haystack.index(before: match.lowerBound)]
            if !before.isLetter && !before.isNumber {
                return .wordPrefix
            }
            searchStart = haystack.index(after: match.lowerBound)
        }
        return .contains
    }

    /// The indices of `names` that match `query`, best rank first and in their original order within
    /// a rank. An empty (or all-whitespace) query keeps every name, in order.
    public static func filter(_ names: [String], query: String) -> [Int] {
        guard !normalize(query).isEmpty else { return Array(names.indices) }
        var matches: [(index: Int, rank: Rank)] = []
        for (index, name) in names.enumerated() {
            if let rank = rank(of: name, query: query) {
                matches.append((index, rank))
            }
        }
        matches.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
        }
        return matches.map(\.index)
    }

    /// Whether a typed character extends the filter: letters, digits, and the punctuation app names
    /// commonly contain. Spaces count only after something was typed.
    public static func acceptsCharacter(_ character: Character, currentQuery: String) -> Bool {
        if character == " " { return !currentQuery.isEmpty }
        if character.isLetter || character.isNumber { return true }
        return "-_.&+'’".contains(character)
    }
}

/// Moving the popup's keyboard selection with the arrow keys.
public enum PopupKeyboardNavigation {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// The item to select after pressing an arrow key.
    ///
    /// `slots` are the grid cells of the selectable items (cells run row by row, `columns` to a row),
    /// in the order the items are listed; cells may be left empty, as in Free Layout. `current` is
    /// the selected item's index in `slots`, `nil` when nothing is selected yet: then any arrow
    /// selects the first item in reading order.
    ///
    /// Left and right go to the previous and next item in reading order (skipping empty cells), up
    /// and down to the nearest item of the closest row above or below that has any. At the edges the
    /// selection stays where it is. Returns `nil` only when there are no items.
    public static func target(from current: Int?, direction: Direction, slots: [Int], columns: Int) -> Int? {
        guard !slots.isEmpty else { return nil }
        let columns = max(columns, 1)
        // Items in reading order.
        let ordered = slots.indices.sorted { slots[$0] == slots[$1] ? $0 < $1 : slots[$0] < slots[$1] }
        guard let current, slots.indices.contains(current) else { return ordered.first }
        let position = ordered.firstIndex(of: current) ?? 0

        switch direction {
        case .left:
            return ordered[max(position - 1, 0)]
        case .right:
            return ordered[min(position + 1, ordered.count - 1)]
        case .up, .down:
            let row = slots[current] / columns
            let column = slots[current] % columns
            let rows = Set(slots.map { $0 / columns })
            let candidates = direction == .up
                ? rows.filter { $0 < row }.max()
                : rows.filter { $0 > row }.min()
            guard let targetRow = candidates else { return current }
            let inRow = slots.indices.filter { slots[$0] / columns == targetRow }
            // The nearest column; on a tie, the one further left.
            return inRow.min { lhs, rhs in
                let left = abs(slots[lhs] % columns - column)
                let right = abs(slots[rhs] % columns - column)
                return left == right ? slots[lhs] < slots[rhs] : left < right
            }
        }
    }

    /// The group to show after pressing Tab (or ⇧Tab, `backward`) in the popup: the next one in
    /// `order`, wrapping around. `nil` when there's no other group to go to.
    public static func nextGroup<ID: Equatable>(after current: ID, in order: [ID], backward: Bool = false) -> ID? {
        guard order.count > 1 else { return nil }
        guard let index = order.firstIndex(of: current) else { return order.first }
        let step = backward ? order.count - 1 : 1
        return order[(index + step) % order.count]
    }
}

/// Quick Look in the popup: Space previews the selected app, as in Finder.
public enum PopupQuickLook {
    /// What the keyboard selection is, for Quick Look.
    public enum Selection: Sendable {
        /// Nothing is selected.
        case none
        /// An app found on this Mac: Quick Look shows its card (name, version, size).
        case previewable
        /// Something Quick Look has nothing to show for: a website, or an app that isn't on this Mac.
        case notPreviewable
    }

    /// What pressing Space does.
    public enum SpaceAction: Equatable, Sendable {
        /// Types a space into the filter.
        case typeSpace
        /// Shows the selected app in Quick Look.
        case showPreview
        /// Closes Quick Look again.
        case closePreview
        /// Nothing; the key is used up, so it doesn't beep.
        case ignore
        /// The popup doesn't use the key.
        case pass
    }

    /// What pressing Escape does: close Quick Look first, then clear the filter, then close the popup.
    public enum EscapeAction: Equatable, Sendable {
        case closePreview, clearFilter, closePopup
    }

    /// Space while something was typed extends the filter (spaces count only after something was
    /// typed, `PopupFilter.acceptsCharacter`). Without a filter it toggles Quick Look for the
    /// selected app; a selected website (or a missing app) has no preview, so Space does nothing,
    /// and with nothing selected the popup leaves the key alone.
    public static func spaceAction(query: String, isPreviewShown: Bool, selection: Selection) -> SpaceAction {
        if !query.isEmpty { return .typeSpace }
        if isPreviewShown { return .closePreview }
        switch selection {
        case .previewable: return .showPreview
        case .notPreviewable: return .ignore
        case .none: return .pass
        }
    }

    public static func escapeAction(query: String, isPreviewShown: Bool) -> EscapeAction {
        if isPreviewShown { return .closePreview }
        return query.isEmpty ? .closePopup : .clearFilter
    }
}
