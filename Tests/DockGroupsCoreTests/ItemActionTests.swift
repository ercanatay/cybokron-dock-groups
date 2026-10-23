import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: actions")
struct ItemActionTests {
    private static let app = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let website = AppReference(websiteURL: URL(string: "https://github.com")!)
    private static let file = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file)
    private static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
    private static let found = ItemPresence.available(URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"))
    private static let foundApp = ItemPresence.available(URL(fileURLWithPath: "/System/Applications/Mail.app"))

    private static let mainPopup = ItemActionContext.popup(isEditable: true)
    private static let agentPopup = ItemActionContext.popup(isEditable: false)

    private func actions(_ item: GroupItem, _ presence: ItemPresence, _ context: ItemActionContext) -> [ItemAction] {
        ItemAction.available(for: item, presence: presence, in: context)
    }

    @Test func popupMenus() {
        // A found file or folder: open, preview, reveal; editing only in the main app.
        #expect(actions(Self.file, Self.found, Self.mainPopup) == [.open, .quickLook, .showInFinder, .moveTo, .remove])
        #expect(actions(Self.folder, Self.found, Self.agentPopup) == [.open, .quickLook, .showInFinder])
        // A missing one: Open (which reports it), and Locate… where the group can be edited.
        #expect(actions(Self.file, .missing, Self.agentPopup) == [.open])
        #expect(actions(Self.file, .missing, Self.mainPopup) == [.open, .locate, .moveTo, .remove])
        #expect(actions(Self.folder, .volumeUnavailable(name: "Backup"), Self.mainPopup) == [.open, .moveTo, .remove])
        // Not checked: Quick Look and Finder can still show it.
        #expect(actions(Self.file, .unverified, Self.agentPopup) == [.open, .quickLook, .showInFinder])
    }

    @Test func popupMenusOfAppsAndWebsitesAreAsBefore() {
        #expect(actions(Self.app, Self.foundApp, Self.mainPopup) == [.open, .quickLook, .showInFinder, .moveTo, .remove])
        #expect(actions(Self.app, .missing, Self.mainPopup) == [.open, .moveTo, .remove])
        #expect(actions(Self.app, .missing, Self.agentPopup) == [.open])
        #expect(actions(Self.website, .online, Self.mainPopup) == [.open, .copyURL, .moveTo, .remove])
        #expect(actions(Self.website, .online, Self.agentPopup) == [.open, .copyURL])
    }

    @Test func groupWindowRowMenus() {
        #expect(actions(Self.folder, Self.found, .groupWindow) == [.showInFinder, .quickLook, .editDetails, .moveTo])
        #expect(actions(Self.file, .missing, .groupWindow) == [.editDetails, .locate, .moveTo])
        #expect(actions(Self.app, .missing, .groupWindow) == [.editDetails, .moveTo])
        #expect(actions(Self.website, .online, .groupWindow) == [.editDetails, .moveTo])
    }

    @Test func dockMenusOnlyOpenWhatsWorthTrying() {
        #expect(actions(Self.website, .online, .dockMenu) == [.open])
        #expect(actions(Self.app, Self.foundApp, .dockMenu) == [.open])
        #expect(actions(Self.file, .unverified, .dockMenu) == [.open])
        #expect(actions(Self.file, .missing, .dockMenu).isEmpty)
        #expect(actions(Self.folder, .volumeUnavailable(name: "Backup"), .dockMenu).isEmpty)
    }

    /// No context ever offers Locate… for an app or a website, Copy URL for anything but a
    /// website, or editing in a standalone group's own app.
    @Test func neverOfferedWhereTheyCantWork() {
        let presences: [ItemPresence] = [Self.found, .online, .missing, .volumeUnavailable(name: "V"), .unverified]
        let contexts: [ItemActionContext] = [Self.mainPopup, Self.agentPopup, .groupWindow, .dockMenu]
        for item in [Self.app, Self.website, Self.file, Self.folder] {
            for presence in presences {
                for context in contexts {
                    let offered = actions(item, presence, context)
                    #expect(Set(offered).count == offered.count)
                    if !item.kind.isFileSystemItem { #expect(!offered.contains(.locate)) }
                    if !item.isWebsite { #expect(!offered.contains(.copyURL)) }
                    if item.isWebsite { #expect(!offered.contains(.quickLook) && !offered.contains(.showInFinder)) }
                    if context == Self.agentPopup || context == .dockMenu {
                        #expect(offered.allSatisfy { ![.locate, .editDetails, .moveTo, .remove].contains($0) })
                    }
                }
            }
        }
    }
}

@Suite("Group items: Quick Look")
struct ItemQuickLookTests {
    private static let app = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let file = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file)
    private static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)

    @Test func targets() {
        let appURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let fileURL = URL(fileURLWithPath: "/Users/me/Archive/Q3 Report.pdf")
        #expect(PopupQuickLook.target(for: Self.app, presence: .available(appURL)) == appURL)
        #expect(PopupQuickLook.target(for: Self.app, presence: .missing) == nil)
        #expect(PopupQuickLook.target(for: Self.app, presence: .unverified) == nil)
        #expect(PopupQuickLook.target(for: Self.file, presence: .available(fileURL)) == fileURL)
        #expect(PopupQuickLook.target(for: Self.file, presence: .unverified) == Self.file.fileURL)
        #expect(PopupQuickLook.target(for: Self.folder, presence: .unverified)?.hasDirectoryPath == true)
        #expect(PopupQuickLook.target(for: Self.file, presence: .missing) == nil)
        #expect(PopupQuickLook.target(for: Self.folder, presence: .volumeUnavailable(name: "Backup")) == nil)
        let website = AppReference(websiteURL: URL(string: "https://github.com")!)
        #expect(PopupQuickLook.target(for: website, presence: .online) == nil)
        #expect(PopupQuickLook.target(for: website, presence: .available(appURL)) == nil)
    }

    @Test func spaceStillWorksAsBeforeForApps() {
        let found = PopupQuickLook.selection(of: Self.app, presence: .available(URL(fileURLWithPath: "/System/Applications/Mail.app")))
        #expect(found == .previewable)
        #expect(PopupQuickLook.spaceAction(query: "", isPreviewShown: false, selection: found) == .showPreview)
        #expect(PopupQuickLook.selection(of: Self.app, presence: .missing) == .notPreviewable)
        #expect(PopupQuickLook.selection(of: nil, presence: .missing) == .none)
        #expect(PopupQuickLook.selection(of: Self.file, presence: .unverified) == .previewable)
        #expect(PopupQuickLook.selection(of: Self.folder, presence: .missing) == .notPreviewable)
    }
}
