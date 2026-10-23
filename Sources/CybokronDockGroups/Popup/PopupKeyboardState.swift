import Combine
import DockGroupsCore
import Foundation

/// The popup's keyboard state: what the user typed to filter the items, and the item the arrow
/// keys selected. Owned by `PopupPanelController`, which handles the keys; `PopupContentView` draws it.
@MainActor
final class PopupKeyboardState: ObservableObject {
    /// The filter as typed; empty shows every app.
    @Published var query = ""
    /// The selected app; `nil` until an arrow key is pressed or something is typed.
    @Published var selectedID: PopupCell.ID?

    var isFiltering: Bool { !PopupFilter.normalize(query).isEmpty }

    func reset() {
        if !query.isEmpty { query = "" }
        if selectedID != nil { selectedID = nil }
    }
}

/// The items the keyboard can reach in a popup and the grid cells they're in.
struct PopupNavigationItems {
    let cells: [PopupCell]
    /// Grid cell of each of `cells`, same order.
    let slots: [Int]
    /// With a filter, why each of `cells` matched, same order (indices into the content's cells);
    /// empty without one.
    var matches: [ItemSearchMatch] = []
}

@MainActor
extension PopupContent {
    /// The items shown for `query`: with a filter, the matches (by name and alias first, then by
    /// tags and task notes: `PopupSearch`), best first, packed from the first cell; without one,
    /// every item in its cell (in Free Layout, the cell it was put in).
    func navigationItems(query: String) -> PopupNavigationItems {
        if !PopupFilter.normalize(query).isEmpty {
            let matches = search.matches(for: query).filter { cells.indices.contains($0.index) }
            let found = matches.map { cells[$0.index] }
            return PopupNavigationItems(cells: found, slots: Array(found.indices), matches: matches)
        }
        if let freeLayout {
            let placed = cells.compactMap { cell in freeLayout.slot(of: cell.app).map { (cell, $0) } }
            return PopupNavigationItems(cells: placed.map(\.0), slots: placed.map(\.1))
        }
        return PopupNavigationItems(cells: cells, slots: Array(cells.indices))
    }

    /// What the footer says about the filter's matches, for the item the keyboard selected (the
    /// best match by default).
    func searchFooter(query: String, selectedID: PopupCell.ID?) -> PopupSearchFooter {
        let items = navigationItems(query: query)
        let selectedIndex = selectedID.flatMap { id in cells.firstIndex { $0.id == id } }
        return PopupSearchFooter(matches: items.matches, items: cells.map(\.app), selectedIndex: selectedIndex)
    }
}
