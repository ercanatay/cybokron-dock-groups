import Foundation
import Testing
@testable import DockGroupsCore

/// The group window's part of launch actions (slice 4, launch-action-ui-slice.md): the details
/// editor's browser profile, turning on an action that needs review, the rows' captions and the
/// confirmation's summary. Nothing here opens anything; the last tests go through the launcher with
/// a fake workspace to show that what the editor saves is what opens, and only once turned on.
@Suite("Launch actions: the editor, review and captions")
@MainActor
struct LaunchActionEditingTests {
    typealias F = LaunchActionFixtures

    nonisolated static let work = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")
    nonisolated static let personal = LaunchAction.browserProfile(browser: .firefox, profileName: "default-release")
    nonisolated static let allInstalled = Set(BrowserFamily.allCases)

    nonisolated static func imported(_ action: LaunchAction = work) -> GroupItem {
        var item = F.website(nil)
        item.launchActionSetting = .needsReview(.imported(action))
        return item
    }

    nonisolated static func invalid() -> GroupItem {
        var item = F.website(nil)
        item.launchActionSetting = .needsReview(.invalid(.unknownTemplate))
        return item
    }

    private let persistence = MemoryGroupPersistence()
    private let store: GroupStore

    init() {
        store = GroupStore(persistence: persistence, saveDelay: .zero)
    }

    /// A store with a group holding `item`; returns the group's identifier.
    private func group(with item: GroupItem) -> DockGroup.ID {
        let added = store.addGroup(named: "Work")
        store.addItems([item], toGroup: added.id)
        return added.id
    }

    private func stored(_ id: DockGroup.ID) -> GroupItem {
        store.group(withID: id)!.apps[0]
    }

    // MARK: - Setting a browser profile

    @Test func aValidBrowserAndNameIsSavedOnOnceConfirmed() throws {
        let item = F.website(nil)
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: [.chrome, .firefox])
        #expect(draft.offersBrowserProfile && draft.canTurnOnBrowserProfile)
        #expect(draft.browser == nil && draft.chosenLaunchAction == nil)
        #expect(!draft.hasChanges)

        draft.setBrowserProfileOn(true)
        #expect(draft.browser == .chrome, "the first browser on this Mac")
        draft.profileName = "Work"
        #expect(draft.isProfileNameAccepted && draft.canFinish)
        #expect(draft.launchActionAwaitingConfirmation == Self.work, "Done asks first")
        // Not confirmed: closing keeps the item as it was, however it closes.
        for ending in [ItemDetailsDraft.Ending.done, .dismissed, .cancel] {
            #expect(draft.launchActionToSave(endingWith: ending) == nil)
        }
        #expect(!store.saveItemEdits(of: draft, endingWith: .dismissed, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchActionSetting == nil)

        draft.confirmLaunchAction(Self.work)
        #expect(draft.launchActionAwaitingConfirmation == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.work))
        #expect(draft.launchActionToSave(endingWith: .cancel) == nil)
        #expect(draft.hasChanges)
        let saves = persistence.saveCount
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(persistence.saveCount == saves + 1)
        #expect(stored(id).launchActionSetting == .enabled(Self.work))
        #expect(stored(id).launchActionStatus == .enabled(Self.work))
        let written = String(decoding: try JSONEncoder().encode(stored(id)), as: UTF8.self)
        #expect(written.contains(#""launchAction":{"#) && written.contains(#""profile":"Work""#))
    }

    @Test func confirmingAnotherActionThanTheChosenOneDoesNothing() {
        var draft = ItemDetailsDraft(F.website(nil), installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(true)
        draft.profileName = "Work"
        draft.confirmLaunchAction(Self.personal)
        #expect(draft.confirmedLaunchAction == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
        // Changing the name after confirming asks again.
        draft.confirmLaunchAction(Self.work)
        draft.profileName = "Profile 1"
        #expect(draft.launchActionAwaitingConfirmation == .browserProfile(browser: .chrome, profileName: "Profile 1"))
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
    }

    @Test(arguments: [
        "", " Work", "Work ", "-P", "--remote-debugging-port=9222", "--load-extension=/tmp/x", "../Default", "/Users/me/Profile",
        "~/Profile", "file:Default", "Work\nHome", "Work\u{0}", "Wo\u{202E}rk", "Wo\u{200B}rk", "Work; rm -rf ~", "$(id)", "a=b",
        "https:x", String(repeating: "p", count: BrowserProfileName.maximumLength + 1),
    ])
    func anInvalidNameCantBeSaved(name: String) {
        let item = F.website(nil)
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(true)
        draft.profileName = name
        #expect(!draft.isProfileNameAccepted, "the editor shows why under the field")
        #expect(!draft.canFinish, "Done is off")
        #expect(draft.launchActionAwaitingConfirmation == nil && draft.launchActionToTurnOn == nil)
        // Even a confirmation can't set it, and a dismissal keeps the item as it was.
        if let chosen = draft.chosenLaunchAction { draft.confirmLaunchAction(chosen) }
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
        store.saveItemEdits(of: draft, endingWith: .dismissed, ofItem: item.id, inGroup: id)
        #expect(stored(id).launchActionSetting == nil)
    }

    @Test(arguments: ["Default", "Profile 1", "Profile 12", "Work", "default-release", "Ayşe Work", "İş"])
    func validNamesAreAccepted(name: String) {
        var draft = ItemDetailsDraft(F.website(nil), installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(true)
        draft.profileName = name
        #expect(draft.isProfileNameAccepted && draft.canFinish)
        #expect(draft.launchActionAwaitingConfirmation != nil)
    }

    @Test func aBrowserThatIsntOnThisMacCantBeChosen() {
        var draft = ItemDetailsDraft(F.website(nil), installedBrowsers: [.firefox])
        #expect(!draft.canChoose(.chrome) && !draft.canChoose(.edge) && !draft.canChoose(.brave))
        #expect(draft.canChoose(.firefox))
        let chrome = draft.chooseBrowser(.chrome)
        #expect(!chrome)
        #expect(draft.browser == nil)
        draft.setBrowserProfileOn(true)
        #expect(draft.browser == .firefox)
        let edge = draft.chooseBrowser(.edge)
        #expect(!edge)
        #expect(draft.browser == .firefox)
        let off = draft.chooseBrowser(nil)
        #expect(off && draft.browser == nil)

        // No browser on this Mac: the browser profile can't be turned on.
        var none = ItemDetailsDraft(F.website(nil), installedBrowsers: [])
        #expect(!none.canTurnOnBrowserProfile)
        none.setBrowserProfileOn(true)
        #expect(none.browser == nil)
    }

    @Test func anActionWhoseBrowserIsGoneCanBeKeptButNotChanged() {
        let item = F.website(.chrome)
        var draft = ItemDetailsDraft(item, installedBrowsers: [.firefox])
        #expect(draft.browser == .chrome && draft.profileName == "Work")
        #expect(draft.canFinish && draft.launchActionToSave(endingWith: .done) == nil, "unchanged: kept")
        draft.profileName = "Home"
        #expect(!draft.canFinish, "a changed profile needs its browser on this Mac")
        #expect(draft.launchActionAwaitingConfirmation == nil)
    }

    @Test func onlyWebsitesOfferABrowserProfile() {
        for item in [AppReference(bundleIdentifier: "com.apple.mail", name: "Mail"),
                     GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file)] {
            var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
            #expect(!draft.offersBrowserProfile && !draft.canTurnOnBrowserProfile)
            draft.setBrowserProfileOn(true)
            let taken = draft.chooseBrowser(.chrome)
            #expect(!taken)
            #expect(draft.browser == nil && draft.launchActionToSave(endingWith: .done) == nil)
        }
        let detailsOnly = ItemDetailsDraft(ItemDetails(alias: "Q3"))
        #expect(!detailsOnly.offersBrowserProfile && detailsOnly.installedBrowsers.isEmpty)
    }

    @Test func anEnabledActionIsKeptChangedOrRemoved() {
        let item = F.website(.chrome)
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        #expect(draft.originalLaunchAction == .enabled(Self.work))
        #expect(!draft.launchActionNeedsReview && draft.launchActionToTurnOn == nil)
        #expect(draft.launchActionAwaitingConfirmation == nil && !draft.hasChanges)
        #expect(draft.launchActionToSave(endingWith: .done) == nil)

        // Another browser: asks, then saves it.
        let firefox = draft.chooseBrowser(.firefox)
        #expect(firefox)
        draft.profileName = "default-release"
        #expect(draft.launchActionAwaitingConfirmation == Self.personal)
        draft.confirmLaunchAction(Self.personal)
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchAction == Self.personal)

        // Turned off: removed, without asking.
        var off = ItemDetailsDraft(stored(id), installedBrowsers: Self.allInstalled)
        off.setBrowserProfileOn(false)
        #expect(off.launchActionAwaitingConfirmation == nil)
        #expect(off.launchActionToSave(endingWith: .done) == .remove)
        #expect(off.launchActionToSave(endingWith: .cancel) == nil)
        #expect(store.saveItemEdits(of: off, endingWith: .dismissed, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchActionSetting == nil)

        // Off and on again: the action as it was, nothing to save.
        var again = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        again.setBrowserProfileOn(false)
        again.setBrowserProfileOn(true)
        #expect(again.chosenLaunchAction == Self.work)
        #expect(again.launchActionToSave(endingWith: .done) == nil)
    }

    @Test func turningOnAnActionDropsTheOpenWithApp() {
        let item = F.website(nil).launching(after: 2, with: ItemOpener(bundleIdentifier: "com.apple.Safari", name: "Safari"))
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(true)
        draft.profileName = "Work"
        draft.confirmLaunchAction(Self.work)
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(stored(id).launch == ItemLaunchOptions(delay: 2), "the profile's browser opens it, not Safari")
        #expect(stored(id).launchActionBrowserBundleIdentifier == "com.google.Chrome")
    }

    @Test func theStoreKeepsAnInvalidActionItIsGivenAsNeedingReview() {
        let item = F.website(nil)
        let id = group(with: item)
        let forged = LaunchAction.browserProfile(browser: .chrome, profileName: "--remote-debugging-port=9222")
        #expect(store.updateItem(item.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(forged)))
        #expect(stored(id).launchAction == nil)
        #expect(stored(id).launchActionStatus == .invalid)
    }

    // MARK: - Review

    @Test func anImportedActionIsShownAndTurnedOnOnlyExplicitly() {
        let item = Self.imported()
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        #expect(draft.originalLaunchAction == .imported(Self.work))
        #expect(draft.launchActionNeedsReview)
        #expect(draft.browser == .chrome && draft.profileName == "Work", "the editor shows what came in")
        // Done without Turn On: still under review.
        #expect(draft.launchActionAwaitingConfirmation == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
        #expect(!store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchActionStatus == .imported(Self.work))

        // Turn On asks; Cancel there changes nothing.
        #expect(draft.launchActionToTurnOn == Self.work)
        #expect(draft.launchActionToSave(endingWith: .dismissed) == nil)
        draft.confirmLaunchAction(Self.work)
        #expect(draft.launchActionToTurnOn == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.work))
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchActionSetting == .enabled(Self.work))
    }

    @Test func anImportedActionCanBeRemovedOrChanged() {
        var removed = ItemDetailsDraft(Self.imported(), installedBrowsers: Self.allInstalled)
        removed.setBrowserProfileOn(false)
        #expect(removed.launchActionToSave(endingWith: .done) == .remove)

        var changed = ItemDetailsDraft(Self.imported(), installedBrowsers: Self.allInstalled)
        changed.profileName = "Profile 1"
        let action = LaunchAction.browserProfile(browser: .chrome, profileName: "Profile 1")
        #expect(changed.launchActionAwaitingConfirmation == action)
        #expect(changed.launchActionToTurnOn == action)

        // Its browser isn't on this Mac: it can't be turned on.
        let gone = ItemDetailsDraft(Self.imported(), installedBrowsers: [.firefox])
        #expect(gone.launchActionToTurnOn == nil && gone.launchActionAwaitingConfirmation == nil)
    }

    @Test func anInvalidActionNeedsANewOne() {
        let item = Self.invalid()
        let id = group(with: item)
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        #expect(draft.originalLaunchAction == .invalid && draft.launchActionNeedsReview)
        #expect(draft.browser == nil && draft.profileName.isEmpty, "nothing of it is shown")
        #expect(draft.launchActionToTurnOn == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "left as it is: still not opened")
        draft.setBrowserProfileOn(true)
        draft.profileName = "Work"
        #expect(draft.launchActionToTurnOn == Self.work)
        #expect(draft.launchActionAwaitingConfirmation == Self.work)
        draft.confirmLaunchAction(Self.work)
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(stored(id).launchActionSetting == .enabled(Self.work))
    }

    @Test func statusesFollowTheSetting() {
        #expect(F.website(nil).launchActionStatus == nil)
        #expect(F.website(.brave, profile: "Profile 2").launchActionStatus == .enabled(.browserProfile(browser: .brave, profileName: "Profile 2")))
        #expect(Self.imported().launchActionStatus == .imported(Self.work))
        #expect(Self.invalid().launchActionStatus == .invalid)
        var forged = F.website(nil)
        forged.launchActionSetting = .enabled(.browserProfile(browser: .chrome, profileName: "-P"))
        #expect(forged.launchActionStatus == .invalid)
        #expect(LaunchActionStatus.imported(Self.work).needsReview && LaunchActionStatus.invalid.needsReview)
        #expect(!LaunchActionStatus.enabled(Self.work).needsReview)
    }

    // MARK: - Rows

    @Test func theRowShowsTheBrowserAndProfile() throws {
        var asked: [String] = []
        let caption = try #require(LaunchActionCaption(item: F.website(.chrome)) { asked.append($0); return false })
        #expect(caption.text == "Chrome · Work")
        #expect(caption.note == nil && !caption.needsReview)
        #expect(asked == ["com.google.Chrome"])

        let firefox = try #require(LaunchActionCaption(item: F.website(.firefox, profile: "default-release")) { _ in false })
        #expect(firefox.text == "Firefox · default-release")
    }

    @Test func theRowSaysWhenTheBrowserIsRunning() throws {
        let caption = try #require(LaunchActionCaption(item: F.website(.edge, profile: "Default")) { $0 == "com.microsoft.edgemac" })
        #expect(caption.text == "Edge · Default")
        #expect(caption.note == "Edge is running: the item opens only after you quit it.")
        #expect(!caption.needsReview)
    }

    @Test func theRowWarnsWhileTheActionNeedsReview() throws {
        for item in [Self.imported(), Self.invalid()] {
            var asked = false
            let caption = try #require(LaunchActionCaption(item: item) { _ in asked = true; return true })
            #expect(caption.needsReview)
            #expect(caption.text == "Browser profile needs review: the item won't open until you turn it on.")
            #expect(caption.note == nil && !asked, "no running note for an action that isn't on")
        }
    }

    @Test func itemsWithoutAnActionHaveNoCaption() {
        let items: [GroupItem] = [
            F.website(nil),
            F.website(nil).launching(after: 3),
            AppReference(bundleIdentifier: "com.google.Chrome", name: "Chrome"),
            GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file),
        ]
        for item in items {
            #expect(LaunchActionCaption(item: item) { _ in true } == nil)
        }
    }

    // MARK: - Confirmation

    @Test func theConfirmationSummarizesBrowserProfileAndFullAddress() throws {
        let url = try #require(URL(string: "https://github.com/cybokron/dock-groups/pulls?q=is%3Aopen#top"))
        var item = F.website(nil, url: url)
        item.details = ItemDetails(alias: "PRs")
        let summary = try #require(LaunchActionSummary(Self.work, for: item))
        #expect(summary.itemName == "PRs")
        #expect(summary.browser == .chrome && summary.profileName == "Work")
        #expect(summary.address == "https://github.com/cybokron/dock-groups/pulls?q=is%3Aopen#top")
        #expect(summary.title == "Open “PRs” in Chrome with the profile “Work”?")
        #expect(summary.details == "https://github.com/cybokron/dock-groups/pulls?q=is%3Aopen#top\nGoogle Chrome (com.google.Chrome)")

        let firefox = try #require(LaunchActionSummary(Self.personal, for: F.website(nil)))
        #expect(firefox.details == "https://github.com/cybokron\nFirefox (org.mozilla.firefox)")
        #expect(LaunchActionSummary(Self.work, for: AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")) == nil)
    }

    @Test func browserNamesAndIdentifiers() {
        #expect(BrowserFamily.allCases.map(\.name) == ["Chrome", "Edge", "Brave", "Firefox"])
        #expect(BrowserFamily.allCases.map(\.applicationName) == ["Google Chrome", "Microsoft Edge", "Brave Browser", "Firefox"])
        #expect(BrowserFamily.allCases.map(\.bundleIdentifier) == BrowserFamily.allCases.map { $0.bundleIdentifiers[0] })
        #expect(BrowserFamily.allCases.map(\.profileNameExample) == ["Profile 1", "Profile 1", "Profile 1", "default-release"])
        for family in BrowserFamily.allCases {
            #expect(LaunchAction.isAcceptedProfileName(family.profileNameExample))
        }
    }

    // MARK: - What opens

    /// Turning it on records its approval (launch-action-approvals.md), which the launcher reads: the
    /// store and the launcher share this Mac's approvals, here in memory.
    @Test func anImportedItemOpensOnlyOnceTurnedOn() async {
        let approvals = LaunchActionApprovalStore.inMemory()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero, approvals: approvals)
        let item = Self.imported()
        let id = store.addGroup(named: "Work").id
        store.addItems([item], toGroup: id)
        func stored(_ id: DockGroup.ID) -> GroupItem { store.group(withID: id)!.apps[0] }
        let workspace = LaunchActionFakeWorkspace()

        let before = await GroupLauncher(workspace: workspace, approvals: approvals).open(stored(id), inGroup: store.group(withID: id)!, source: .userAction)
        #expect(before.entries.first?.launchActionRefusal == .plan(.actionDisabled))
        #expect(workspace.starts.isEmpty && workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
        #expect(approvals.load().isEmpty)

        var draft = ItemDetailsDraft(stored(id), installedBrowsers: Self.allInstalled)
        let action = draft.launchActionToTurnOn!
        draft.confirmLaunchAction(action)
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id)
        #expect(approvals.check(stored(id)) == .approved)

        let after = await GroupLauncher(workspace: workspace, approvals: approvals).open(stored(id), inGroup: store.group(withID: id)!, source: .userAction)
        #expect(after.entries == [LaunchReport.Entry(app: stored(id), outcome: .launched)])
        #expect(workspace.starts.map(\.arguments) == [["--profile-directory=Work"]])
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
    }
}
