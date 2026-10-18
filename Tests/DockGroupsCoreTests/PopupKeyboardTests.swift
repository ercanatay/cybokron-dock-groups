import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Popup type-to-filter")
struct PopupFilterTests {
    @Test func normalizationIgnoresCaseAndDiacritics() {
        #expect(PopupFilter.normalize("Çalışma") == "calisma")
        #expect(PopupFilter.normalize("  ÉCLAIR ") == "eclair")
        #expect(PopupFilter.normalize("Über") == "uber")
        #expect(PopupFilter.normalize("İstanbul") == "istanbul")
        #expect(PopupFilter.normalize("Øresund Łódź") == "oresund lodz")
        #expect(PopupFilter.normalize("Straße") == "strasse")
        #expect(PopupFilter.normalize("ＡＢＣ") == "abc")
    }

    @Test func diacriticsMatchBothWays() {
        #expect(PopupFilter.rank(of: "Çiçek Sepeti", query: "cicek") == .prefix)
        #expect(PopupFilter.rank(of: "Cicek", query: "çiç") == .prefix)
        #expect(PopupFilter.rank(of: "Ekşi Sözlük", query: "sozluk") == .wordPrefix)
        #expect(PopupFilter.rank(of: "Safari", query: "SAF") == .prefix)
    }

    @Test func rankDistinguishesPrefixWordPrefixAndContains() {
        #expect(PopupFilter.rank(of: "Visual Studio Code", query: "vis") == .prefix)
        #expect(PopupFilter.rank(of: "Visual Studio Code", query: "code") == .wordPrefix)
        #expect(PopupFilter.rank(of: "Xcode", query: "code") == .contains)
        #expect(PopupFilter.rank(of: "Final-Cut Pro", query: "cut") == .wordPrefix)
        // A later occurrence at a word start still counts as a word prefix.
        #expect(PopupFilter.rank(of: "Notes Note", query: "ote") == .contains)
        #expect(PopupFilter.rank(of: "Xnote Notes", query: "note") == .wordPrefix)
        #expect(PopupFilter.rank(of: "Mail", query: "zz") == nil)
        #expect(PopupFilter.rank(of: "Mail", query: "  ") == nil)
    }

    @Test func filterSortsByRankAndKeepsOrderWithinARank() {
        let names = ["Xcode", "Calendar", "Visual Studio Code", "Codex", "Code Editor", "Mail"]

        #expect(PopupFilter.filter(names, query: "code") == [3, 4, 2, 0])
        #expect(PopupFilter.filter(names, query: "CAL") == [1])
        #expect(PopupFilter.filter(names, query: "nothing").isEmpty)
    }

    @Test func emptyQueryKeepsEveryApp() {
        let names = ["B", "A", "C"]
        #expect(PopupFilter.filter(names, query: "") == [0, 1, 2])
        #expect(PopupFilter.filter(names, query: "   ") == [0, 1, 2])
        #expect(PopupFilter.filter([], query: "a").isEmpty)
    }

    @Test func acceptedCharacters() {
        #expect(PopupFilter.acceptsCharacter("a", currentQuery: ""))
        #expect(PopupFilter.acceptsCharacter("ç", currentQuery: ""))
        #expect(PopupFilter.acceptsCharacter("7", currentQuery: ""))
        #expect(PopupFilter.acceptsCharacter("-", currentQuery: "a"))
        #expect(!PopupFilter.acceptsCharacter(" ", currentQuery: ""))
        #expect(PopupFilter.acceptsCharacter(" ", currentQuery: "vis"))
        #expect(!PopupFilter.acceptsCharacter("\t", currentQuery: "a"))
        #expect(!PopupFilter.acceptsCharacter("/", currentQuery: "a"))
    }
}

@Suite("Popup keyboard navigation")
struct PopupKeyboardNavigationTests {
    private typealias Navigation = PopupKeyboardNavigation

    /// Seven apps in five columns: two rows, the second holding two apps.
    private let packed = Array(0..<7)

    @Test func firstArrowSelectsTheFirstApp() {
        for direction in [Navigation.Direction.left, .right, .up, .down] {
            #expect(Navigation.target(from: nil, direction: direction, slots: packed, columns: 5) == 0)
        }
        #expect(Navigation.target(from: nil, direction: .down, slots: [], columns: 5) == nil)
        #expect(Navigation.target(from: 3, direction: .down, slots: [], columns: 5) == nil)
        // An index that's gone (the group shrank) starts over.
        #expect(Navigation.target(from: 12, direction: .right, slots: packed, columns: 5) == 0)
    }

    @Test func leftAndRightStopAtTheEnds() {
        #expect(Navigation.target(from: 0, direction: .left, slots: packed, columns: 5) == 0)
        #expect(Navigation.target(from: 0, direction: .right, slots: packed, columns: 5) == 1)
        // Right at the end of a row goes on to the next row, in reading order.
        #expect(Navigation.target(from: 4, direction: .right, slots: packed, columns: 5) == 5)
        #expect(Navigation.target(from: 5, direction: .left, slots: packed, columns: 5) == 4)
        #expect(Navigation.target(from: 6, direction: .right, slots: packed, columns: 5) == 6)
    }

    @Test func upAndDownClampToTheShorterLastRow() {
        #expect(Navigation.target(from: 1, direction: .down, slots: packed, columns: 5) == 6)
        // No app under column 3 in the last row: the nearest one in that row.
        #expect(Navigation.target(from: 3, direction: .down, slots: packed, columns: 5) == 6)
        #expect(Navigation.target(from: 6, direction: .up, slots: packed, columns: 5) == 1)
        #expect(Navigation.target(from: 2, direction: .up, slots: packed, columns: 5) == 2)
        #expect(Navigation.target(from: 5, direction: .down, slots: packed, columns: 5) == 5)
    }

    @Test func singleColumnAndSingleApp() {
        #expect(Navigation.target(from: 0, direction: .down, slots: [0, 1, 2], columns: 1) == 1)
        #expect(Navigation.target(from: 2, direction: .down, slots: [0, 1, 2], columns: 1) == 2)
        #expect(Navigation.target(from: 0, direction: .right, slots: [0], columns: 5) == 0)
        #expect(Navigation.target(from: 0, direction: .up, slots: [0], columns: 0) == 0)
    }

    @Test func freeLayoutSkipsEmptyCellsAndRows() {
        // Three apps in a 4-column grid: cells 1 and 2 in the first row, nothing in the second,
        // cell 11 in the third. The list order differs from the reading order.
        let slots = [11, 2, 1]
        #expect(Navigation.target(from: nil, direction: .right, slots: slots, columns: 4) == 2)
        #expect(Navigation.target(from: 2, direction: .right, slots: slots, columns: 4) == 1)
        #expect(Navigation.target(from: 1, direction: .right, slots: slots, columns: 4) == 0)
        #expect(Navigation.target(from: 1, direction: .down, slots: slots, columns: 4) == 0)
        #expect(Navigation.target(from: 0, direction: .up, slots: slots, columns: 4) == 1)
        #expect(Navigation.target(from: 0, direction: .left, slots: slots, columns: 4) == 1)
    }

    @Test func filteredContentHeightPacksTheMatches() {
        let metrics = PopupGridMetrics(cellWidth: 84, cellHeight: 86, spacing: 4, padding: 12)
        let layout = PopupGridLayout(itemCount: 23, columns: .auto, maxRows: 4)

        let oneRow: CGFloat = 86 + 24
        let twoRows: CGFloat = 2 * 86 + 4 + 24
        #expect(layout.contentHeight(packing: 0, metrics: metrics) == oneRow)
        #expect(layout.contentHeight(packing: 5, metrics: metrics) == oneRow)
        #expect(layout.contentHeight(packing: 6, metrics: metrics) == twoRows)
        #expect(layout.contentHeight(packing: 23, metrics: metrics) == layout.contentHeight(metrics: metrics))
    }

    @Test func tabCyclesThroughTheGroups() {
        let order = ["a", "b", "c"]
        #expect(Navigation.nextGroup(after: "a", in: order) == "b")
        #expect(Navigation.nextGroup(after: "c", in: order) == "a")
        #expect(Navigation.nextGroup(after: "a", in: order, backward: true) == "c")
        #expect(Navigation.nextGroup(after: "b", in: order, backward: true) == "a")
        #expect(Navigation.nextGroup(after: "x", in: order) == "a")
        #expect(Navigation.nextGroup(after: "a", in: ["a"]) == nil)
        #expect(Navigation.nextGroup(after: "a", in: [String]()) == nil)
    }
}
