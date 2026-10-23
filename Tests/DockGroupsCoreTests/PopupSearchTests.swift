import Foundation
import Testing
@testable import DockGroupsCore

/// The popup's filter as the popup uses it (`PopupSearch`): the name and alias first, exactly as
/// before details existed, then tags and task notes; one search per query; and what the footer
/// says about the selected match.
@Suite("Group items: popup search")
@MainActor
struct PopupSearchTests {
    private static func item(_ name: String, alias: String? = nil, tags: [String] = [], notes: String? = nil) -> GroupItem {
        var item = AppReference(bundleIdentifier: "com.example.\(name.filter(\.isLetter))", name: name)
        item.details = ItemDetails(alias: alias, tags: tags, notes: notes)
        return item
    }

    private static let items = [
        item("Numbers", alias: "Budget", tags: ["finance", "q3"], notes: "Monthly totals"),
        item("Mail", tags: ["inbox"], notes: "Reply to invoices\nSend the totals to Ayşe on Fridays"),
        item("Invoice Maker"),
        item("Finder"),
        item("Calendar", alias: "Plan"),
    ]

    @Test func oneSearchPerQuery() {
        let search = PopupSearch(items: Self.items)
        let first = search.matches(for: "inv")
        // The grid, the footer, the selection, the arrow keys, Return: asked again, searched once.
        for _ in 0..<5 {
            #expect(search.matches(for: "inv") == first)
        }
        #expect(search.searchCount == 1)
        #expect(search.matches(for: "invo") != [])
        #expect(search.searchCount == 2)
        // Back to an earlier query: searched again (only the last answer is kept), same result.
        #expect(search.matches(for: "inv") == first)
        #expect(search.searchCount == 3)
        #expect(search.matches(for: "inv") == search.index.matches(for: "inv"))
    }

    /// Names and aliases first, in the ranks `PopupFilter` has always used; then tags, then notes.
    @Test func namesAndAliasesComeFirstThenTagsThenNotes() {
        let search = PopupSearch(items: Self.items)

        let invoice = search.matches(for: "invoice")
        #expect(invoice.map(\.index) == [2, 1])
        #expect(invoice.map(\.rank) == [.titlePrefix, .notes])

        let fin = search.matches(for: "fin")
        #expect(fin.map(\.index) == [3, 0])
        #expect(fin.map(\.rank) == [.titlePrefix, .tags])
        #expect(fin.last?.reason == .tag("finance"))

        let totals = search.matches(for: "totals")
        #expect(totals.map(\.index) == [0, 1])
        #expect(totals.allSatisfy { $0.rank == .notes })

        // The alias finds an item like its name, and the name still does.
        #expect(search.matches(for: "budg").map(\.index) == [0])
        #expect(search.matches(for: "plan").map(\.index) == [4])
        #expect(search.matches(for: "calen").map(\.index) == [4])
        #expect(search.matches(for: "plan").first?.reason == nil)
    }

    /// For each field — name, alias, tag, notes — which kinds of typing find the item, and how it
    /// ranks: a whole-query substring counts only in names and aliases; tags and notes match word
    /// by word, at the start of their words, every word typed somewhere in the item.
    @Test(arguments: [
        // (query, matched indices in order, ranks)
        ("num", [0], [ItemSearchRank.titlePrefix]),                   // name prefix
        ("umber", [0], [.titleContains]),                              // name substring
        ("udget", [0], [.titleContains]),                              // alias substring
        ("maker", [2], [.titleWordPrefix]),                            // a later word of a name
        ("q3", [0], [.tags]),                                          // a tag
        ("nance", [], []),                                             // inside a tag: no
        ("box", [], []),                                               // inside a tag: no
        ("monthly", [0], [.notes]),                                    // a word of the notes
        ("onthly", [], []),                                            // inside a word of the notes: no
        ("fridays ayse", [1], [.notes]),                               // notes words in any order, without diacritics
        ("finance monthly", [0], [.notes]),                            // a tag and a notes word
        ("budget q3", [0], [.tags]),                                   // the alias and a tag
        ("inbox fridays", [1], [.notes]),
        ("finance inbox", [], []),                                     // every word in the same item
        ("NUMBERS", [0], [.titlePrefix]),                              // case
        ("ｎｕｍｂｅｒｓ", [0], [.titlePrefix]),                         // width
        ("FİNANCE", [0], [.tags]),                                     // a dotted capital I folds to "i"
    ] as [(String, [Int], [ItemSearchRank])])
    func matchMatrix(query: String, indices: [Int], ranks: [ItemSearchRank]) {
        let matches = PopupSearch(items: Self.items).matches(for: query)
        #expect(matches.map(\.index) == indices, "“\(query)”")
        #expect(matches.map(\.rank) == ranks, "“\(query)”")
    }

    /// Without details the popup finds what it found before: the same items, in the same order.
    @Test func groupsWithoutDetailsFilterAsBefore() {
        let names = ["Xcode", "Calendar", "Visual Studio Code", "Codex", "Ekşi Sözlük", "Final-Cut Pro", "Notes"]
        let search = PopupSearch(items: names.map { Self.item($0) })
        for query in ["code", "cal", "sozluk", "cut", "ote", "e", "zz", "final-cut", "ＣＯＤＥ"] {
            #expect(search.matches(for: query).map(\.index) == PopupFilter.filter(names, query: query), "“\(query)”")
            #expect(search.matches(for: query).allSatisfy { $0.reason == nil })
        }
    }

    // MARK: - Footer

    private func footer(_ query: String, selected: Int? = nil) -> PopupSearchFooter {
        PopupSearchFooter(matches: PopupSearch(items: Self.items).matches(for: query), items: Self.items, selectedIndex: selected)
    }

    @Test func theFooterSaysWhyTheSelectedItemWasFound() {
        #expect(footer("zzz") == .noMatch)
        // The best match speaks until another is selected.
        #expect(footer("invoice") == .matches)
        #expect(footer("invoice", selected: 1) == .notes(itemName: "Mail"))
        #expect(footer("fin") == .matches)
        // An item is named as it's shown: by its alias.
        #expect(footer("fin", selected: 0) == .tag("finance", itemName: "Budget"))
        #expect(footer("q3") == .tag("q3", itemName: "Budget"))
        #expect(footer("totals") == .notes(itemName: "Budget"))
        #expect(footer("budget") == .matches)
        // A selection that isn't among the matches (left from before typing): the best match.
        #expect(footer("q3", selected: 3) == .tag("q3", itemName: "Budget"))
        #expect(footer("totals", selected: nil) == footer("totals", selected: 4))
    }

    @Test func theFooterOfAnEmptyListOrStaleMatchesIsSafe() {
        #expect(PopupSearchFooter(matches: [], items: [], selectedIndex: nil) == .noMatch)
        let stale = ItemSearchMatch(index: 9, rank: .tags, reason: .tag("x"))
        #expect(PopupSearchFooter(matches: [stale], items: Self.items, selectedIndex: nil) == .matches)
    }
}

/// The purpose strings macOS shows when it asks for access to guarded folders and volumes: the
/// same in the main app's Info.plist and in every standalone group's own app.
@Suite("File access purposes")
struct FileAccessPurposesTests {
    @Test func theyCoverTheGuardedPlacesAndPromiseNoReading() {
        #expect(Set(FileAccessPurposes.infoPlistEntries.keys) == [
            "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
            "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription",
        ])
        for (key, text) in FileAccessPurposes.infoPlistEntries {
            #expect(text.hasSuffix("it never reads their contents."), "\(key)")
            #expect(!text.contains("%"), "\(key)")
        }
    }

    @Test func theMainAppsInfoPlistHasThem() throws {
        let url = LocalizationTests.resources.appending(path: "Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        for (key, text) in FileAccessPurposes.infoPlistEntries {
            #expect(info[key] as? String == text, "Resources/Info.plist \(key)")
        }
        let declared = Set(info.keys.filter { $0.hasSuffix("UsageDescription") })
        #expect(declared == Set(FileAccessPurposes.infoPlistEntries.keys))
    }

    @Test func everyAgentHasThem() throws {
        let host = AgentHost(
            executableURL: URL(fileURLWithPath: "/Applications/Cybokron Dock Groups.app/Contents/MacOS/Cybokron Dock Groups"),
            version: "0.6.8",
            build: "608",
            minimumSystemVersion: "14.0",
            executableDigest: "abc123"
        )
        let id = UUID()
        let data = try AgentInfoPlist.data(groupID: id, groupName: "Work", folderName: "work.app", host: host)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for (key, text) in FileAccessPurposes.infoPlistEntries {
            #expect(info[key] as? String == text, "\(key)")
        }
        #expect(info["CFBundleIdentifier"] as? String == "com.cybokron.dockgroups.agent.\(id.uuidString)")
    }
}
