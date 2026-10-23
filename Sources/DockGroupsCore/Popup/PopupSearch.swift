import Foundation

/// The popup's filter over one build of its content (spec §3.3): the `ItemSearchIndex` of its
/// items, built with the cells — when the popup opens or its group, the preferences or the Most
/// Used list change — so typing never normalizes the items again, and never looks at the disk or
/// asks LaunchServices (where the items are was checked at build time).
///
/// One keystroke asks for the same matches several times (the grid, the footer, the selection, the
/// arrow keys, Return, Quick Look), so the last answer is kept.
@MainActor
public final class PopupSearch {
    public let index: ItemSearchIndex
    private var last: (query: String, matches: [ItemSearchMatch])?
    /// How many times the index was actually searched.
    private(set) var searchCount = 0

    public init(items: [GroupItem]) {
        index = ItemSearchIndex(items: items)
    }

    /// `ItemSearchIndex.matches(for:)`, answered from memory when `query` is the last one asked for.
    public func matches(for query: String) -> [ItemSearchMatch] {
        if let last, last.query == query { return last.matches }
        let matches = index.matches(for: query)
        searchCount += 1
        last = (query, matches)
        return matches
    }
}

/// What the popup's footer says while a filter is typed (spec §4.4): why the selected item — the
/// best match until the arrow keys pick another — was found, when it wasn't by its name or alias.
public enum PopupSearchFooter: Equatable, Sendable {
    /// Nothing matches.
    case noMatch
    /// The item matched by its name or alias: "↩ opens the selected item".
    case matches
    /// The item matched by one of its tags: "tag “invoice” of Numbers".
    case tag(String, itemName: String)
    /// The item matched by its task notes: "in the task notes of Quarterly report".
    case notes(itemName: String)

    /// - Parameters:
    ///   - matches: The filter's matches (`ItemSearchIndex.matches(for:)`), best first.
    ///   - items: The items the matches' indices refer to.
    ///   - selectedIndex: The index (in `items`) of the item the keyboard selected; the best match
    ///     speaks when it's `nil` or not among the matches.
    public init(matches: [ItemSearchMatch], items: [GroupItem], selectedIndex: Int?) {
        guard let best = matches.first else {
            self = .noMatch
            return
        }
        let match = selectedIndex.flatMap { selected in matches.first { $0.index == selected } } ?? best
        guard items.indices.contains(match.index) else {
            self = .matches
            return
        }
        let name = items[match.index].displayName
        switch match.reason {
        case nil: self = .matches
        case .tag(let tag)?: self = .tag(tag, itemName: name)
        case .notes?: self = .notes(itemName: name)
        }
    }
}
