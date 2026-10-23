import Foundation
import Testing
@testable import DockGroupsCore

/// What the popup's cells say — their tooltip and VoiceOver texts — for every kind and presence.
@Suite("Group items: popup cells")
struct PopupCellTextTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!, name: "GitHub")
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
    private static let found = ItemPresence.available(URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"))

    private func text(
        _ item: GroupItem,
        _ presence: ItemPresence,
        running: Bool = false,
        editable: Bool = true,
        free: Bool = false
    ) -> PopupCellText {
        PopupCellText(item: item, presence: presence, isRunning: running, isEditable: editable, isFreeLayout: free)
    }

    /// Apps and websites say what they said before files and folders existed.
    @Test func appsAndWebsitesAreUnchanged() {
        let app = text(Self.mail, Self.found)
        #expect(app.help == .openApp(name: "Mail"))
        #expect(app.drag == .ordered)
        #expect(app.label == .app(name: "Mail"))
        #expect(app.hint == .openApp)

        let running = text(Self.mail, Self.found, running: true, free: true)
        #expect(running.help == .bringToFront(name: "Mail"))
        #expect(running.drag == .freeApp)
        #expect(running.hint == .bringToFront)

        let missing = text(Self.mail, .missing)
        #expect(missing.help == .appMissing(name: "Mail"))
        #expect(missing.drag == .missing)

        let website = text(Self.github, .online, free: true)
        #expect(website.help == .openWebsite(address: "https://github.com"))
        #expect(website.drag == .freeItem)
        #expect(website.label == .website(name: "GitHub"))
        #expect(website.hint == .website)
    }

    @Test func filesAndFoldersOpenWithTheirDefaultApp() {
        let file = text(Self.report, Self.found)
        #expect(file.help == .openFile(name: "Q3 Report.pdf"))
        #expect(file.drag == .ordered)
        #expect(file.label == .file(name: "Q3 Report.pdf"))
        #expect(file.hint == .file)

        let folder = text(Self.projects, .available(URL(fileURLWithPath: "/Users/me/Projects")), free: true)
        #expect(folder.help == .openFolder(name: "Projects"))
        #expect(folder.drag == .freeItem)
        #expect(folder.label == .folder(name: "Projects"))
        #expect(folder.hint == .folder)

        // Never "running", even if asked.
        #expect(text(Self.report, Self.found, running: true).hint == .file)
    }

    /// Not checked (privacy settings): shown as if found, so it isn't judged.
    @Test func anUncheckedItemReadsAsAFoundOne() {
        #expect(text(Self.report, .unverified) == text(Self.report, Self.found))
    }

    @Test func missingItemsSayWhyAndCanOnlyBeDraggedOut() {
        let missing = text(Self.report, .missing, free: true)
        #expect(missing.help == .itemMissing(name: "Q3 Report.pdf"))
        #expect(missing.drag == .missing)
        #expect(missing.label == .file(name: "Q3 Report.pdf"))

        let ejected = text(Self.projects, .volumeUnavailable(name: "Backup SSD"))
        #expect(ejected.help == .volumeUnavailable(name: "Projects", volume: "Backup SSD"))
        #expect(ejected.drag == .missing)
    }

    /// The Most Used list and a standalone group's own app don't offer dragging.
    @Test func readOnlyPopupsHaveNoDragSentence() {
        for (item, presence) in [(Self.mail, Self.found), (Self.github, .online), (Self.report, .missing), (Self.projects, .unverified)] {
            #expect(text(item, presence, editable: false).drag == nil)
        }
    }
}
