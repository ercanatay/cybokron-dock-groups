import Foundation
import Testing
@testable import DockGroupsCore

/// The details editor's state (`ItemDetailsDraft`) and how closing it saves: once on Done or a
/// dismissal, never on Cancel or when nothing changed — so a standalone group's app is rebuilt at
/// most once per edit.
@Suite("Group items: details editor")
@MainActor
struct ItemDetailsEditorTests {
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf"), kind: .file)
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let details = ItemDetails(alias: "Quarterly report", tags: ["finance", "q3"], notes: "Send the totals\nto Ayşe")

    @Test func aDraftStartsFromTheDetailsAsText() {
        let draft = ItemDetailsDraft(Self.details)
        #expect(draft.alias == "Quarterly report")
        #expect(draft.tagsText == "finance, q3")
        #expect(draft.notes == "Send the totals\nto Ayşe")
        #expect(draft.tags == ["finance", "q3"])
        #expect(draft.details == Self.details)
        #expect(!draft.hasChanges)

        let empty = ItemDetailsDraft(ItemDetails())
        #expect(empty.alias.isEmpty && empty.tagsText.isEmpty && empty.notes.isEmpty)
        #expect(empty.details.isEmpty)
    }

    @Test func closingSavesOnlyChangesAndNeverAfterCancel() {
        var draft = ItemDetailsDraft(Self.details)
        // Nothing changed: nothing to save, however it closes.
        for ending in [ItemDetailsDraft.Ending.done, .dismissed, .cancel] {
            #expect(draft.detailsToSave(endingWith: ending) == nil)
        }
        // Typed differently but the same once cleaned up: still nothing.
        draft.alias = "  Quarterly report "
        draft.tagsText = "#finance ,q3,"
        draft.notes = "Send the totals\r\nto Ayşe\n"
        #expect(!draft.hasChanges)
        #expect(draft.detailsToSave(endingWith: .done) == nil)

        draft.tagsText = "finance, q3, budget"
        let expected = ItemDetails(alias: "Quarterly report", tags: ["finance", "q3", "budget"], notes: "Send the totals\nto Ayşe")
        #expect(draft.detailsToSave(endingWith: .done) == expected)
        #expect(draft.detailsToSave(endingWith: .dismissed) == expected)
        #expect(draft.detailsToSave(endingWith: .cancel) == nil)

        // Clearing everything is a change too: the item then has no details.
        var cleared = ItemDetailsDraft(Self.details)
        cleared.alias = ""
        cleared.tagsText = " , "
        cleared.notes = "\n"
        #expect(cleared.detailsToSave(endingWith: .done) == ItemDetails())
    }

    @Test func theFieldsStopAtTheirLimits() {
        var draft = ItemDetailsDraft(ItemDetails())
        draft.alias = String(repeating: "a", count: ItemDetails.maximumAliasLength + 20)
        #expect(draft.alias.count == ItemDetails.maximumAliasLength)
        draft.notes = String(repeating: "n", count: ItemDetails.maximumNotesLength + 1)
        #expect(draft.notes.count == ItemDetails.maximumNotesLength)
        #expect(draft.notesLength == ItemDetails.maximumNotesLength)
        // Emoji count as one character each, as the user sees them.
        draft.notes = "👩‍💻🇹🇷"
        #expect(draft.notesLength == 2)
    }

    /// The tags are shown as they'll be kept while they're typed, with how many won't be.
    @Test func typedTagsPreviewWhatsKept() {
        var draft = ItemDetailsDraft(ItemDetails())
        draft.tagsText = "fatura، ödeme，q3、 #finance, Fatura"
        #expect(draft.tags == ["fatura", "ödeme", "q3", "finance"])
        #expect(draft.leftOutTagCount == 0)

        draft.tagsText = (1...15).map { "tag\($0)" }.joined(separator: ",")
        #expect(draft.tags.count == ItemDetails.maximumTagCount)
        #expect(draft.tags.last == "tag12")
        #expect(draft.leftOutTagCount == 3)
        // Repeats don't count as left out.
        draft.tagsText = (1...12).map { "tag\($0)" }.joined(separator: ",") + ", TAG1, tag2"
        #expect(draft.leftOutTagCount == 0)
    }

    @Test func doneSavesOnceAndCancelLeavesTheItemAsItWas() throws {
        let persistence = CountingGroupPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addItems([Self.mail, Self.report], toGroup: group.id)
        let saves = persistence.saveCount

        // Many edits in the editor, then Cancel: nothing reaches the store.
        var draft = ItemDetailsDraft(ItemDetails())
        draft.alias = "Q"
        draft.alias = "Quarterly"
        draft.tagsText = "finance"
        #expect(!store.saveDetails(of: draft, endingWith: .cancel, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(store.group(withID: group.id)?.apps.last?.details.isEmpty == true)
        #expect(persistence.saveCount == saves)

        // The same edits, then Done: one save.
        #expect(store.saveDetails(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(persistence.saveCount == saves + 1)
        let saved = try #require(store.group(withID: group.id)?.apps.last)
        #expect(saved.details == ItemDetails(alias: "Quarterly", tags: ["finance"]))
        #expect(saved.displayName == "Quarterly")

        // Opened again and closed without a change: no save, so no rebuild.
        let again = ItemDetailsDraft(saved.details)
        #expect(!store.saveDetails(of: again, endingWith: .dismissed, ofItem: saved.bundleIdentifier, inGroup: group.id))
        #expect(!store.saveDetails(of: again, endingWith: .done, ofItem: saved.bundleIdentifier, inGroup: group.id))
        #expect(persistence.saveCount == saves + 1)

        // A click elsewhere keeps what was typed, like Done.
        var dismissed = again
        dismissed.notes = "Fridays"
        #expect(store.saveDetails(of: dismissed, endingWith: .dismissed, ofItem: saved.bundleIdentifier.uppercased(), inGroup: group.id))
        #expect(store.group(withID: group.id)?.apps.last?.details.notes == "Fridays")
        #expect(persistence.saveCount == saves + 2)
    }

    /// The item went away (removed from the popup) while its editor was open: closing it changes nothing.
    @Test func closingTheEditorOfARemovedItemChangesNothing() {
        let persistence = CountingGroupPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addItems([Self.report], toGroup: group.id)
        var draft = ItemDetailsDraft(ItemDetails())
        draft.alias = "Report"
        store.removeApp(bundleIdentifier: Self.report.bundleIdentifier, fromGroup: group.id)
        let saves = persistence.saveCount

        #expect(!store.saveDetails(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(!store.saveDetails(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: UUID()))
        #expect(persistence.saveCount == saves)
        #expect(store.group(withID: group.id)?.apps.isEmpty == true)
    }

    /// Details saved through the editor round-trip through the groups file, so a standalone group's
    /// app gets them in its configuration too.
    @Test func savedDetailsAreInTheGroupsFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        let store = GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        store.addItems([Self.report], toGroup: group.id)
        var draft = ItemDetailsDraft(ItemDetails())
        draft.alias = "Quarterly report"
        draft.tagsText = "finance, q3"
        draft.notes = "Send the totals\nto Ayşe"
        store.saveDetails(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id)

        let reloaded = GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .zero)
        #expect(reloaded.group(withID: group.id)?.apps.first?.details == Self.details)
        let configuration = AgentConfiguration(group: try #require(reloaded.group(withID: group.id)), preferences: PopupPreferences())
        #expect(try AgentConfiguration.decode(from: configuration.encoded()).group.apps.first?.details == Self.details)
    }
}

/// Aliases where items are listed: sorted by, shown by, also when the item can't be found.
@Suite("Group items: aliases")
@MainActor
struct ItemAliasTests {
    private static func item(_ name: String, alias: String? = nil) -> GroupItem {
        var item = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/\(name)"), kind: .file)
        item.details = ItemDetails(alias: alias)
        return item
    }

    /// Sort A→Z goes by the shown name, and follows a new alias.
    @Test func sortingFollowsTheAlias() {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let group = store.addGroup(named: "Work")
        let report = Self.item("Q3 Report.pdf", alias: "Budget")
        let zebra = Self.item("Zebra.txt")
        let apple = Self.item("Apple.txt", alias: "Yearly plan")
        store.addItems([zebra, apple, report], toGroup: group.id)

        store.sortAppsByName(inGroup: group.id)
        #expect(store.group(withID: group.id)?.apps.map(\.displayName) == ["Budget", "Yearly plan", "Zebra.txt"])

        store.updateDetails(ItemDetails(), ofItem: apple.bundleIdentifier, inGroup: group.id)
        store.updateDetails(ItemDetails(alias: "Annual"), ofItem: zebra.bundleIdentifier, inGroup: group.id)
        store.sortAppsByName(inGroup: group.id)
        #expect(store.group(withID: group.id)?.apps.map(\.displayName) == ["Annual", "Apple.txt", "Budget"])
        #expect(store.group(withID: group.id)?.apps.map(\.name) == ["Zebra.txt", "Apple.txt", "Q3 Report.pdf"])
    }

    /// The popup's cell names the item by its alias, found or not, and says its own name in the
    /// tooltip's details line.
    @Test func theAliasIsShownEvenWhenTheItemIsMissing() {
        var report = Self.item("Q3 Report.pdf", alias: "Quarterly report")
        report.details = ItemDetails(alias: "Quarterly report", tags: ["finance", "q3"], notes: "Send the totals to Ayşe on Fridays\nand to Can")
        let found = PopupCellText(item: report, presence: .available(URL(fileURLWithPath: "/Users/me/Q3 Report.pdf")), isRunning: false, isEditable: true, isFreeLayout: false)
        #expect(found.help == .openFile(name: "Quarterly report"))
        #expect(found.label == .file(name: "Quarterly report"))
        #expect(found.details == PopupCellText.Details(name: "Q3 Report.pdf", tags: ["finance", "q3"], notes: "Send the totals to Ayşe on Fridays…"))

        for presence in [ItemPresence.missing, .unverified, .volumeUnavailable(name: "Backup")] {
            let text = PopupCellText(item: report, presence: presence, isRunning: false, isEditable: false, isFreeLayout: false)
            #expect(text.label == .file(name: "Quarterly report"), "\(presence)")
            #expect(text.details?.name == "Q3 Report.pdf", "\(presence)")
        }
        #expect(PopupCellText(item: report, presence: .missing, isRunning: false, isEditable: true, isFreeLayout: false).help == .itemMissing(name: "Quarterly report"))

        var app = AppReference(bundleIdentifier: "com.apple.iWork.Numbers", name: "Numbers")
        app.details = ItemDetails(alias: "Budget")
        #expect(PopupCellText(item: app, presence: .missing, isRunning: false, isEditable: true, isFreeLayout: false).help == .appMissing(name: "Budget"))
        #expect(PopupCellText(item: app, presence: .unverified, isRunning: true, isEditable: true, isFreeLayout: false).help == .bringToFront(name: "Budget"))
        var website = AppReference(websiteURL: URL(string: "https://github.com")!, name: "GitHub")
        website.details = ItemDetails(alias: "Code")
        let websiteText = PopupCellText(item: website, presence: .online, isRunning: false, isEditable: true, isFreeLayout: false)
        #expect(websiteText.label == .website(name: "Code"))
        #expect(websiteText.help == .openWebsite(address: "https://github.com"))
    }

    @Test func theDetailsLineSaysOnlyWhatsThere() {
        #expect(PopupCellText.Details(item: Self.item("Plain.txt")) == nil)
        var tagged = Self.item("Plan.key")
        tagged.details = ItemDetails(tags: ["work"])
        #expect(PopupCellText.Details(item: tagged) == PopupCellText.Details(tags: ["work"]))
        // An alias that is the name itself needn't repeat it.
        #expect(PopupCellText.Details(item: Self.item("Plan.key", alias: "Plan.key")) == PopupCellText.Details())
        var noted = Self.item("Plan.key")
        noted.details = ItemDetails(notes: "  \n  Call Ayşe  \n")
        #expect(PopupCellText.Details(item: noted)?.notes == "Call Ayşe")
    }

    @Test func notesOnOneLine() {
        #expect(ItemDetails().notesSummary == nil)
        #expect(ItemDetails(notes: "Fridays").notesSummary == "Fridays")
        #expect(ItemDetails(notes: "First\n\nSecond").notesSummary == "First…")
        let long = ItemDetails(notes: String(repeating: "word ", count: 40)).notesSummary
        #expect(long?.count ?? 0 <= ItemDetails.maximumSummaryLength)
        #expect(long?.hasSuffix("…") == true)
    }
}

/// Records how often the groups are saved.
final class CountingGroupPersistence: GroupPersisting {
    private(set) var saveCount = 0
    private var saved: [DockGroup] = []

    func loadGroups() throws -> [DockGroup] { saved }

    func saveGroups(_ groups: [DockGroup]) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}
