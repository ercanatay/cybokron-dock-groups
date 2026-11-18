import Foundation
import Testing
@testable import DockGroupsCore

// The "Run a Shortcut" template, slice 2 (docs/design/launch-action-shortcut.md §5): the details
// editor's field on the Shortcuts app's item, the confirmation's summary, the approval it writes,
// the row's caption, backups and agents. Running it (slice 3) is covered by
// `ShortcutLaunchRunnerTests`. Every workspace is a fake.

@Suite("Launch actions: the shortcut template (editor and approval)")
@MainActor
struct LaunchActionShortcutEditingTests {
    typealias F = LaunchActionFixtures

    nonisolated static let workSetup = LaunchAction.shortcut(name: "Work Setup")
    nonisolated static let shortcuts = AppReference(bundleIdentifier: "com.apple.shortcuts", name: "Shortcuts")
    nonisolated static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")

    nonisolated static func shortcutsItem(_ action: LaunchAction? = workSetup) -> GroupItem {
        var item = shortcuts
        item.setLaunchAction(action)
        return item
    }

    /// A store with a group holding `item`, on approvals kept in memory.
    private func fixture(_ item: GroupItem = shortcuts) -> (GroupStore, LaunchActionApprovalStore, DockGroup.ID) {
        let approvals = LaunchActionApprovalStore.inMemory()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero, approvals: approvals)
        let id = store.addGroup(named: "Work").id
        store.addItems([item], toGroup: id)
        return (store, approvals, id)
    }

    private func stored(_ store: GroupStore, _ id: DockGroup.ID) throws -> GroupItem {
        try #require(store.group(withID: id)?.apps.first)
    }

    // MARK: - The field

    @Test func onlyTheShortcutsItemOffersIt() {
        let draft = ItemDetailsDraft(Self.shortcuts)
        #expect(draft.offersShortcut && !draft.offersBrowserProfile && !draft.isShortcutOn)
        #expect(Self.shortcuts.isShortcutsApplication)
        #expect(AppReference(bundleIdentifier: "COM.APPLE.SHORTCUTS", name: "Shortcuts").isShortcutsApplication)

        for item in [Self.mail, F.website(nil), AppReference(bundleIdentifier: "com.example.fake-shortcuts", name: "Shortcuts")] {
            var other = ItemDetailsDraft(item, installedBrowsers: [.chrome])
            #expect(!other.offersShortcut)
            #expect(!item.isShortcutsApplication)
            other.setShortcutOn(true)
            other.shortcutName = "Work Setup"
            #expect(!other.isShortcutOn)
            #expect(other.chosenLaunchAction == nil)
            #expect(other.launchActionAwaitingConfirmation == nil)
            #expect(other.launchActionToSave(endingWith: .done) == nil)
        }
        // A draft of details alone has no item: nothing offered.
        #expect(!ItemDetailsDraft(ItemDetails()).offersShortcut)
    }

    @Test func turningItOnAndOff() {
        var draft = ItemDetailsDraft(Self.shortcuts)
        #expect(draft.chosenLaunchAction == nil && draft.canFinish)

        draft.setShortcutOn(true)
        #expect(draft.isShortcutOn)
        // An empty name can't be saved.
        #expect(!draft.isShortcutNameAccepted && !draft.canFinish)
        #expect(draft.launchActionAwaitingConfirmation == nil)

        draft.shortcutName = "Work Setup"
        #expect(draft.isShortcutNameAccepted && draft.canFinish)
        #expect(draft.chosenLaunchAction == Self.workSetup)
        #expect(draft.launchActionAwaitingConfirmation == Self.workSetup)
        // Not confirmed: Done saves nothing of it.
        #expect(draft.launchActionToSave(endingWith: .done) == nil)

        draft.setShortcutOn(false)
        #expect(!draft.isShortcutOn && draft.canFinish)
        #expect(draft.chosenLaunchAction == nil && draft.launchActionAwaitingConfirmation == nil)
        #expect(draft.shortcutName == "Work Setup", "the name typed is kept")
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "nothing to remove")
        #expect(!draft.hasChanges)
    }

    @Test(arguments: ["", " Work", "Work ", "-x", "a/b", "a\\b", "Work\nSetup", "Work\u{200B}Setup", "Caf\u{0065}\u{0301}", String(repeating: "a", count: 129)])
    func aRefusedNameKeepsDoneOff(_ name: String) {
        var draft = ItemDetailsDraft(Self.shortcuts)
        draft.setShortcutOn(true)
        draft.shortcutName = name
        #expect(!draft.isShortcutNameAccepted)
        #expect(!draft.canFinish)
        #expect(draft.launchActionAwaitingConfirmation == nil)
        draft.confirmLaunchAction(.shortcut(name: name))
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "a refused name is never saved")
        // Turned off, the name isn't used: Done is back.
        draft.setShortcutOn(false)
        #expect(draft.canFinish)
    }

    @Test(arguments: ["Work Setup", "A&B", "a+b", "x#y", "50%", "Work: start", "İş Başı", "عمل", "仕事", "🚀", String(repeating: "a", count: 128)])
    func anAcceptedNameCanBeConfirmed(_ name: String) {
        var draft = ItemDetailsDraft(Self.shortcuts)
        draft.setShortcutOn(true)
        draft.shortcutName = name
        #expect(draft.isShortcutNameAccepted && draft.canFinish)
        #expect(draft.launchActionAwaitingConfirmation == .shortcut(name: name))
        #expect(LaunchAction.isAcceptedShortcutName(name))
    }

    // MARK: - Confirmation

    @Test func theSummaryNamesTheShortcutAndWarns() throws {
        let summary = try #require(LaunchActionSummary(Self.workSetup, for: Self.shortcuts))
        #expect(summary.action == Self.workSetup)
        #expect(summary.shortcutName == "Work Setup")
        #expect(summary.browser == nil && summary.profileName == nil && summary.address == nil)
        #expect(summary.title == "Run the shortcut “Work Setup” when you open this item?")
        let lines = summary.details.components(separatedBy: "\n")
        #expect(lines.first == "Work Setup", "the name as stored comes first")
        #expect(summary.details.contains("It does whatever this shortcut does"))
        #expect(summary.details.contains("The app passes it nothing"))

        // Never for another item, and a browser template never on the Shortcuts item.
        #expect(LaunchActionSummary(Self.workSetup, for: Self.mail) == nil)
        #expect(LaunchActionSummary(Self.workSetup, for: F.website(nil)) == nil)
        #expect(LaunchActionSummary(.browserPrivate(browser: .chrome), for: Self.shortcuts) == nil)
        // The browser summaries are as before.
        let browser = try #require(LaunchActionSummary(.browserProfile(browser: .chrome, profileName: "Work"), for: F.website(nil)))
        #expect(browser.shortcutName == nil && browser.browser == .chrome)
        #expect(browser.title == "Open “GitHub” in Chrome with the profile “Work”?")
    }

    @Test func cancelWritesNothing() throws {
        let (store, approvals, id) = fixture()
        var draft = ItemDetailsDraft(try stored(store, id))
        draft.setShortcutOn(true)
        draft.shortcutName = "Work Setup"
        #expect(draft.launchActionAwaitingConfirmation == Self.workSetup)
        // The confirmation's Cancel: nothing is confirmed, Done or a dismissal saves nothing of it.
        for ending in [ItemDetailsDraft.Ending.done, .dismissed, .cancel] {
            #expect(draft.launchActionToSave(endingWith: ending) == nil)
        }
        #expect(!store.saveItemEdits(of: draft, endingWith: .done, ofItem: Self.shortcuts.id, inGroup: id))
        #expect(try stored(store, id).launchActionSetting == nil)
        #expect(approvals.load().isEmpty)
    }

    @Test func turnOnSetsAndApprovesIt() async throws {
        let (store, approvals, id) = fixture()
        var draft = ItemDetailsDraft(try stored(store, id))
        draft.setShortcutOn(true)
        draft.shortcutName = "Work Setup"
        let action = try #require(draft.launchActionAwaitingConfirmation)
        draft.confirmLaunchAction(action)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.workSetup))
        #expect(draft.launchActionAwaitingConfirmation == nil, "asked once")
        // Cancel after confirming still saves nothing.
        #expect(draft.launchActionToSave(endingWith: .cancel) == nil)

        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: Self.shortcuts.id, inGroup: id))
        let item = try stored(store, id)
        #expect(item.launchActionSetting == .enabled(Self.workSetup))
        #expect(approvals.check(item) == .approved)
        #expect(!store.isApprovalMissing(for: item))

        // Opening it again shows it on, with nothing to confirm.
        let reopened = ItemDetailsDraft(item, isApprovalMissing: store.isApprovalMissing(for: item))
        #expect(reopened.isShortcutOn && reopened.shortcutName == "Work Setup")
        #expect(reopened.launchActionAwaitingConfirmation == nil && reopened.launchActionToTurnOn == nil)
        #expect(reopened.launchActionToSave(endingWith: .done) == nil)
    }

    @Test func renamingAsksAgainAndChangesTheDigest() throws {
        let (store, approvals, id) = fixture(Self.shortcutsItem())
        let before = try stored(store, id)
        var draft = ItemDetailsDraft(before)
        draft.shortcutName = "Work Setup 2"
        #expect(draft.launchActionAwaitingConfirmation == .shortcut(name: "Work Setup 2"))
        // Unconfirmed: the stored action is kept as it was.
        #expect(draft.launchActionToSave(endingWith: .done) == nil)

        // The old approval doesn't cover the new name.
        var renamed = before
        renamed.setLaunchAction(.shortcut(name: "Work Setup 2"))
        store.updateItem(before.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.workSetup))
        #expect(approvals.check(try stored(store, id)) == .approved)
        #expect(approvals.check(renamed) == .mismatch)
        #expect(LaunchActionApprovalDigest.digest(for: renamed) != LaunchActionApprovalDigest.digest(for: before))

        draft.confirmLaunchAction(.shortcut(name: "Work Setup 2"))
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: before.id, inGroup: id)
        let after = try stored(store, id)
        #expect(after.launchActionSetting == .enabled(.shortcut(name: "Work Setup 2")))
        #expect(approvals.check(after) == .approved)
    }

    @Test func turningOffRemovesIt() throws {
        let (store, approvals, id) = fixture()
        store.updateItem(Self.shortcuts.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.workSetup))
        var draft = ItemDetailsDraft(try stored(store, id))
        #expect(draft.isShortcutOn)
        draft.setShortcutOn(false)
        #expect(draft.launchActionToSave(endingWith: .done) == .remove)
        #expect(draft.launchActionToSave(endingWith: .cancel) == nil)
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: Self.shortcuts.id, inGroup: id)
        #expect(try stored(store, id).launchActionSetting == nil)
        #expect(approvals.load().isEmpty, "its approval is dropped with it")
    }

    // MARK: - Review and approval missing

    @Test func anImportedOneIsTurnedOnThroughTheConfirmation() throws {
        var item = Self.shortcutsItem()
        item.launchActionSetting = item.launchActionSetting?.disabledForImport
        let (store, approvals, id) = fixture(item)
        let current = try stored(store, id)
        #expect(current.launchActionStatus == .imported(Self.workSetup))

        let caption = try #require(LaunchActionCaption(item: current) { _ in false })
        #expect(caption.needsReview)
        #expect(caption.text == "Shortcut needs review: the item won't open until you turn it on.")

        var draft = ItemDetailsDraft(current)
        #expect(draft.isShortcutOn && draft.shortcutName == "Work Setup")
        #expect(draft.launchActionNeedsReview && !draft.isApprovalMissing)
        let action = try #require(draft.launchActionToTurnOn)
        #expect(action == Self.workSetup)
        #expect(LaunchActionSummary(action, for: current)?.title.contains("Work Setup") == true)
        draft.confirmLaunchAction(action)
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: current.id, inGroup: id)
        let turnedOn = try stored(store, id)
        #expect(turnedOn.launchActionSetting == .enabled(Self.workSetup))
        #expect(approvals.check(turnedOn) == .approved)
    }

    @Test func anEnabledOneWithoutApprovalIsMissingAndTurnsOnAgain() throws {
        let (store, approvals, id) = fixture()
        store.updateItem(Self.shortcuts.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.workSetup))
        try approvals.save(LaunchActionApprovals())
        let item = try stored(store, id)
        #expect(approvals.check(item) == .missing)
        #expect(store.isApprovalMissing(for: item))

        let caption = try #require(LaunchActionCaption(item: item, isApprovalMissing: true) { _ in false })
        #expect(caption.needsReview && caption.text.contains("Approval missing"))

        var draft = ItemDetailsDraft(item, isApprovalMissing: true)
        #expect(draft.launchActionNeedsReview && draft.isApprovalMissing)
        let action = try #require(draft.launchActionToTurnOn)
        draft.confirmLaunchAction(action)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.workSetup))
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id)
        #expect(approvals.check(try stored(store, id)) == .approved)
    }

    @Test func anInvalidOneOnTheShortcutsItemSaysShortcut() throws {
        var item = Self.shortcuts
        item.setLaunchAction(.shortcut(name: "a/b"))
        #expect(item.launchActionStatus == .invalid)
        let caption = try #require(LaunchActionCaption(item: item) { _ in false })
        #expect(caption.text == "Shortcut needs review: the item won't open until you turn it on.")
        // Its toggle starts off; turning it on and off again removes it.
        var draft = ItemDetailsDraft(item)
        #expect(!draft.isShortcutOn && draft.launchActionNeedsReview)
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
        draft.setShortcutOn(true)
        draft.setShortcutOn(false)
        #expect(draft.launchActionToSave(endingWith: .done) == .remove)

        // A website's invalid action keeps the browser profile's text.
        var website = F.website(nil)
        website.setLaunchAction(.browserProfile(browser: .chrome, profileName: "a/b"))
        #expect(LaunchActionCaption(item: website) { _ in false }?.text == "Browser profile needs review: the item won't open until you turn it on.")
    }

    @Test func anotherItemNeverHasItOn() {
        var mail = Self.mail
        mail.setLaunchAction(Self.workSetup)
        #expect(mail.launchAction == nil)
        #expect(mail.launchActionStatus == .invalid)
        #expect(LaunchActionApprovalDigest.digest(for: mail) == nil)
        let draft = ItemDetailsDraft(mail)
        #expect(!draft.offersShortcut && draft.chosenLaunchAction == nil)
    }

    // MARK: - Row caption

    @Test func theRowNamesTheShortcut() throws {
        let caption = try #require(LaunchActionCaption(item: Self.shortcutsItem()) { _ in true })
        #expect(caption.text == "Run a Shortcut: Work Setup")
        #expect(!caption.needsReview)
        #expect(caption.note == nil, "no browser to wait for")
        #expect(LaunchActionCaption(item: Self.shortcuts) { _ in false } == nil)
    }

    // MARK: - Backups and agents

    @Test func aBackupBringsItInTurnedOff() throws {
        let backup = SettingsBackup(appVersion: "0.19.0", groups: [DockGroup(name: "Work", apps: [Self.shortcutsItem()])], preferences: PopupPreferences())
        let exported = String(decoding: try backup.encoded(), as: UTF8.self)
        #expect(exported.contains(#""template" : "shortcut""#) && exported.contains(#""name" : "Work Setup""#))

        let read = try SettingsBackup.decode(from: backup.encoded())
        #expect(read.disabledLaunchActionCount == 1)
        let item = try #require(read.groups.first?.apps.first)
        #expect(item.launchActionSetting == .needsReview(.imported(Self.workSetup)))
        #expect(item.launchAction == nil)
        #expect(LaunchActionApprovalDigest.digest(for: item) == nil)
        let again = String(decoding: try read.encoded(), as: UTF8.self)
        #expect(again.contains(#""reason" : "imported""#) && !again.contains(#""status" : "enabled""#))
    }

    @Test func anAgentCopiesItTurnedOff() throws {
        let website = F.website()
        let group = DockGroup(name: "Work", apps: [Self.shortcutsItem(), website, Self.mail])
        let configuration = AgentConfiguration(group: group, preferences: PopupPreferences())
        #expect(configuration.group.apps.map(\.launchActionSetting) == [.needsReview(.imported(Self.workSetup)), website.launchActionSetting, nil])
        let read = try AgentConfiguration.decode(from: configuration.encoded())
        #expect(read == configuration)
        #expect(read.group.apps.first?.launchAction == nil)
        #expect(read.group.apps[1].launchAction == website.launchAction, "a browser action is carried as it is")
        // A group without one is copied unchanged.
        let plain = DockGroup(name: "Plain", apps: [website, Self.mail])
        #expect(AgentConfiguration(group: plain, preferences: PopupPreferences()).group.apps == plain.apps)
    }

    // MARK: - Turned on in the editor, it runs

    @Test func anApprovedOneRunsAndAnUnapprovedOneDoesnt() async throws {
        let (store, approvals, id) = fixture()
        store.updateItem(Self.shortcuts.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.workSetup))
        let item = try stored(store, id)
        #expect(approvals.check(item) == .approved)
        let workspace = ShortcutFakeWorkspace()
        let report = await GroupLauncher(workspace: workspace, approvals: approvals, screenLock: { false })
            .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction)
        #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .launched)])
        #expect(workspace.opens.map(\.url.absoluteString) == ["shortcuts://run-shortcut?name=Work%20Setup"])

        let elsewhere = ShortcutFakeWorkspace()
        let refused = await GroupLauncher(workspace: elsewhere, approvals: .inMemory(), screenLock: { false })
            .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction)
        #expect(refused.entries.map(\.launchActionRefusal) == [.approval(.missing)])
        #expect(!elsewhere.openedAnything)
    }

    /// The files this slice changed run nothing: no URL of Shortcuts, no process, no workspace.
    @Test func theEditorPathRunsNothing() throws {
        let root = LocalizationTests.root.appending(path: "Sources", directoryHint: .isDirectory)
        let files = [
            "DockGroupsCore/Model/ItemDetailsDraft.swift",
            "DockGroupsCore/Model/LaunchActionEditing.swift",
            "DockGroupsCore/Standalone/AgentConfiguration.swift",
            "CybokronDockGroups/MainWindow/ItemDetailsEditor.swift",
        ]
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for needle in ["shortcuts://", "x-callback-url", "/usr/bin/shortcuts", "Process(", "NSWorkspace", "NSAppleScript"] {
                #expect(!text.contains(needle), "\(file) contains \(needle)")
            }
        }
    }
}
