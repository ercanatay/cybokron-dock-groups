import Foundation
import Testing
@testable import DockGroupsCore

/// What the window shows of this Mac's approval record: an action that's on without its approval
/// (the file was removed after the groups were read) says so in the editor, with Turn On, and on
/// the row; and a restore says how many actions arrived turned off.
@Suite("Launch actions: approval visibility")
@MainActor
struct LaunchActionApprovalVisibilityTests {
    typealias F = LaunchActionFixtures

    nonisolated static let work = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")

    /// A store whose item has its action on, and the approvals it was recorded in.
    private func fixture(approved: Bool) throws -> (GroupStore, LaunchActionApprovalStore, DockGroup.ID, GroupItem) {
        let approvals = LaunchActionApprovalStore.inMemory()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero, approvals: approvals)
        let id = store.addGroup(named: "Work").id
        store.addItems([F.website(nil)], toGroup: id)
        let identity = F.website(nil).id
        store.updateItem(identity, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work))
        let item = try #require(store.group(withID: id)?.apps.first)
        #expect(item.launchActionSetting == .enabled(Self.work))
        if !approved { try approvals.save(LaunchActionApprovals()) }
        return (store, approvals, id, item)
    }

    @Test func anEnabledActionWithoutApprovalShowsAndTurnsOnAgain() async throws {
        let (store, approvals, id, item) = try fixture(approved: false)
        #expect(store.isApprovalMissing(for: item))
        #expect(approvals.check(item) == .missing)

        let caption = try #require(LaunchActionCaption(item: item, isApprovalMissing: true) { _ in false })
        #expect(caption.needsReview)
        #expect(caption.text.contains("Approval missing"))

        var draft = ItemDetailsDraft(item, installedBrowsers: [.chrome], isApprovalMissing: true)
        #expect(draft.launchActionNeedsReview && draft.isApprovalMissing)
        let action = try #require(draft.launchActionToTurnOn)
        draft.confirmLaunchAction(action)
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id)

        #expect(approvals.check(item) == .approved)
        #expect(!store.isApprovalMissing(for: item))
        let workspace = LaunchActionFakeWorkspace()
        let report = await GroupLauncher(workspace: workspace, approvals: approvals)
            .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction)
        #expect(report.entries.first?.outcome == .launched)
    }

    @Test func anApprovedActionShowsNothingExtra() throws {
        let (store, _, _, item) = try fixture(approved: true)
        #expect(!store.isApprovalMissing(for: item))
        let caption = try #require(LaunchActionCaption(item: item, isApprovalMissing: store.isApprovalMissing(for: item)) { _ in false })
        #expect(!caption.needsReview)
        #expect(caption.text == "Chrome · Work")
        let draft = ItemDetailsDraft(item, installedBrowsers: [.chrome], isApprovalMissing: store.isApprovalMissing(for: item))
        #expect(!draft.launchActionNeedsReview && !draft.isApprovalMissing)
        #expect(draft.launchActionToTurnOn == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == nil)
    }

    @Test func rowsWithoutAnActionOrApprovalsShowNothing() throws {
        let plain = F.website(nil)
        #expect(LaunchActionCaption(item: plain, isApprovalMissing: true) { _ in false } == nil)
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
        var enabled = F.website(nil)
        enabled.setLaunchAction(Self.work)
        #expect(!store.isApprovalMissing(for: plain))
        #expect(!store.isApprovalMissing(for: enabled), "no approval record kept: nothing to say")
        #expect(!ItemDetailsDraft(plain, isApprovalMissing: true).isApprovalMissing)
    }

    @Test func theRestoreSummaryCountsTheActionsThatArrivedOff() throws {
        var group = DockGroup(name: "Work", apps: [F.website(), F.website(url: URL(string: "https://example.com/")!, name: "Example"), F.website(nil, url: URL(string: "https://swift.org/")!)])
        group.apps = group.apps.map { $0 }
        let backup = SettingsBackup(appVersion: "0.18.1", groups: [group], preferences: PopupPreferences())
        let read = try SettingsBackup.decode(from: backup.encoded())
        let summary = SettingsRestoreSummary(backup: read, currentGroups: [])
        #expect(summary.disabledLaunchActionCount == 2)
        #expect(summary.profileApprovalNote?.contains("2 browser profile action(s) arrived turned off and need approval") == true)

        let plain = SettingsBackup(appVersion: "0.18.1", groups: [DockGroup(name: "Work", apps: [F.website(nil)])], preferences: PopupPreferences())
        let none = SettingsRestoreSummary(backup: try SettingsBackup.decode(from: plain.encoded()), currentGroups: [])
        #expect(none.disabledLaunchActionCount == 0)
        #expect(none.profileApprovalNote == nil)
    }
}
