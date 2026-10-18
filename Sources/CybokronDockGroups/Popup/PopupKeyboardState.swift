import Combine
import DockGroupsCore
import Foundation

/// The popup's keyboard state: what the user typed to filter the apps, and the app the arrow keys
/// selected. Owned by `PopupPanelController`, which handles the keys; `PopupContentView` draws it.
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

/// The apps the keyboard can reach in a popup and the grid cells they're in.
struct PopupNavigationItems {
    let cells: [PopupCell]
    /// Grid cell of each of `cells`, same order.
    let slots: [Int]
}

extension PopupContent {
    /// The apps shown for `query`: with a filter, the matches, best first, packed from the first
    /// cell; without one, every app in its cell (in Free Layout, the cell it was put in).
    func navigationItems(query: String) -> PopupNavigationItems {
        if !PopupFilter.normalize(query).isEmpty {
            let matches = PopupFilter.filter(cells.map(\.app.name), query: query).map { cells[$0] }
            return PopupNavigationItems(cells: matches, slots: Array(matches.indices))
        }
        if let freeLayout {
            let placed = cells.compactMap { cell in freeLayout.slot(of: cell.app).map { (cell, $0) } }
            return PopupNavigationItems(cells: placed.map(\.0), slots: placed.map(\.1))
        }
        return PopupNavigationItems(cells: cells, slots: Array(cells.indices))
    }
}
