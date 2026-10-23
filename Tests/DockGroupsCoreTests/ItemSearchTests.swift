import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: search")
struct ItemSearchTests {
    private static func app(_ name: String, alias: String? = nil, tags: [String] = [], notes: String? = nil) -> GroupItem {
        var item = AppReference(bundleIdentifier: "com.example.\(name.filter(\.isLetter))", name: name)
        item.details = ItemDetails(alias: alias, tags: tags, notes: notes)
        return item
    }

    private static func indices(_ items: [GroupItem], _ query: String) -> [Int] {
        ItemSearchIndex(items: items).matches(for: query).map(\.index)
    }

    /// Without details, the results are exactly `PopupFilter.filter`'s: the same items in the same
    /// order (one word at a time; more words can only add matches after them).
    @Test func withoutDetailsTheResultsAreThoseOfThePopupFilter() {
        let names = ["Xcode", "Calendar", "Visual Studio Code", "Codex", "Code Editor", "Mail", "Çiçek Sepeti", "Ekşi Sözlük", "Final-Cut Pro", "Notes Note"]
        let items = names.map { Self.app($0) }
        let index = ItemSearchIndex(items: items)
        let queries = ["code", "CAL", "nothing", "", "   ", "a", "cicek", "sozluk", "cut", "ote", "note", "vis", "e", "zz", "x", "final-cut"]
        for query in queries {
            #expect(index.matches(for: query).map(\.index) == PopupFilter.filter(names, query: query), "query “\(query)”")
        }
        for query in ["code visual", "studio code", "pro final"] {
            let filtered = PopupFilter.filter(names, query: query)
            #expect(Array(index.matches(for: query).map(\.index).prefix(filtered.count)) == filtered, "query “\(query)”")
        }
        #expect(ItemSearchIndex(items: []).matches(for: "a").isEmpty)
    }

    @Test func emptyQueryKeepsEveryItemInOrder() {
        let items = ["B", "A", "C"].map { Self.app($0) }
        #expect(Self.indices(items, "") == [0, 1, 2])
        #expect(Self.indices(items, "  ") == [0, 1, 2])
    }

    @Test func anAliasMatchesLikeAName() {
        let items = [
            Self.app("Budgeting Tool"),
            Self.app("Numbers", alias: "Budget"),
        ]
        let matches = ItemSearchIndex(items: items).matches(for: "budget")
        // Both start with the query: list order.
        #expect(matches.map(\.index) == [0, 1])
        #expect(matches.allSatisfy { $0.rank == .titlePrefix && $0.reason == nil })
        // The alias doesn't hide the name from search.
        #expect(Self.indices(items, "numb") == [1])
        // An alias prefix beats a name that only contains the query.
        let ranked = [Self.app("Xbudget"), Self.app("Numbers", alias: "Budget")]
        #expect(Self.indices(ranked, "budget") == [1, 0])
    }

    @Test func tagsAndNotesMatchByWordAfterTitles() throws {
        let items = [
            Self.app("Numbers", tags: ["finance", "q3"]),
            Self.app("Mail", notes: "Reply to invoices\nSend the totals to Ayşe on Fridays"),
            Self.app("Invoice Maker"),
            Self.app("Finder"),
        ]
        let index = ItemSearchIndex(items: items)

        let invoice = index.matches(for: "invoice")
        #expect(invoice.map(\.index) == [2, 1])
        #expect(invoice.map(\.rank) == [.titlePrefix, .notes])
        #expect(invoice.last?.reason == .notes("Reply to invoices"))

        let finance = index.matches(for: "fin")
        // "Finder" by its name first, then the tag.
        #expect(finance.map(\.index) == [3, 0])
        #expect(finance.last?.rank == .tags)
        #expect(finance.last?.reason == .tag("finance"))

        #expect(index.matches(for: "friday").first?.reason == .notes("Send the totals to Ayşe on Fridays"))
        #expect(index.matches(for: "AYSE").map(\.index) == [1])
    }

    @Test func everyWordMustMatchInAnyOrder() {
        let items = [
            Self.app("Numbers", tags: ["finance", "q3"], notes: "Monthly budget"),
            Self.app("Pages", tags: ["finance"]),
        ]
        #expect(Self.indices(items, "q3 finance") == [0])
        #expect(Self.indices(items, "finance  pages") == [1])
        #expect(Self.indices(items, "monthly numbers").first == 0)
        #expect(ItemSearchIndex(items: items).matches(for: "monthly numbers").first?.rank == .notes)
        #expect(Self.indices(items, "finance nothing").isEmpty)
        // Words count only where a word starts: not anything containing an "a" and a "b".
        #expect(Self.indices([Self.app("Xcode", tags: ["dab"])], "a b").isEmpty)
    }

    @Test func diacriticsAndTurkishSuffixes() {
        let items = [Self.app("Mail", tags: ["Faturayı"], notes: "Öde: ÇAĞRI merkezi")]
        #expect(Self.indices(items, "fatura") == [0])
        #expect(Self.indices(items, "faturayi") == [0])
        #expect(Self.indices(items, "cagri") == [0])
        #expect(Self.indices(items, "ode") == [0])
    }

    @Test func ranksKeepListOrderWithinARank() {
        let items = [
            Self.app("Alpha", tags: ["work"]),
            Self.app("Work Desk"),
            Self.app("Beta", notes: "work notes"),
            Self.app("Gamma", tags: ["workflow"]),
            Self.app("Homework"),
        ]
        let matches = ItemSearchIndex(items: items).matches(for: "work")
        #expect(matches.map(\.index) == [1, 4, 0, 3, 2])
        #expect(matches.map(\.rank) == [.titlePrefix, .titleContains, .tags, .tags, .notes])
    }

    @Test func longNotesShowAnExcerpt() throws {
        let line = "Remember " + String(repeating: "very ", count: 30) + "important"
        let match = try #require(ItemSearchIndex(items: [Self.app("Mail", notes: line)]).matches(for: "remember").first)
        guard case .notes(let excerpt) = match.reason else {
            Issue.record("expected a notes excerpt")
            return
        }
        #expect(excerpt.count <= ItemSearchIndex.maximumExcerptLength)
        #expect(excerpt.count > ItemSearchIndex.maximumExcerptLength - 5)
        #expect(excerpt.hasPrefix("Remember very") && excerpt.hasSuffix("…"))
    }

    @Test func typingIsFastWithManyItems() {
        let items = (0..<200).map { number in
            Self.app("App \(number)", alias: number.isMultiple(of: 3) ? "Alias \(number)" : nil,
                     tags: ["tag\(number % 7)", "project \(number % 11)"],
                     notes: number.isMultiple(of: 2) ? "Notes for item \(number)\nsecond line with words" : nil)
        }
        let index = ItemSearchIndex(items: items)
        let queries = (0..<50).map { ["app", "tag3", "project 4", "words", "alias 9", "zzz", "item 1", "second"][$0 % 8] }
        let start = Date()
        for query in queries {
            _ = index.matches(for: query)
        }
        // Far below a frame per keystroke on a developer Mac; generous for slow CI runners.
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
