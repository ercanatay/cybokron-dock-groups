import Foundation
import Testing
@testable import DockGroupsCore

/// An action's status is saved (docs/design/launch-action-review-persistence.md): one under review
/// — imported with a backup or refused — is written as such and stays off after a restart, so the
/// item still isn't opened (threat model D5). Only `"status": "enabled"` (or, for files written
/// before statuses, no status at all) can run; every other status is refused. Each test writes a
/// real groups file, reads it into a new store, as a restart does, and opens the item through the
/// launcher with a fake workspace.
@Suite("Launch actions: the review status survives a restart")
@MainActor
struct LaunchActionReviewPersistenceTests {
    typealias F = LaunchActionFixtures

    nonisolated static let work = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")
    nonisolated static let allInstalled = Set(BrowserFamily.allCases)

    private let directory: TemporaryDirectory
    private let fileURL: URL

    init() throws {
        directory = try TemporaryDirectory()
        fileURL = directory.url.appending(components: "DockGroups", "groups.json")
    }

    /// A store on the groups file, as the app has after a (re)start.
    private func store() -> GroupStore {
        GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .zero)
    }

    /// A groups file with one group holding `item`; returns the group's identifier.
    @discardableResult
    private func save(_ item: GroupItem) -> DockGroup.ID {
        let store = store()
        let group = store.addGroup(named: "Work")
        store.addItems([item], toGroup: group.id)
        return group.id
    }

    /// A groups file whose one website item has `launchAction` set to `value`, written by hand.
    private func write(launchAction value: Any) throws {
        save(F.website(nil))
        try rewrite(launchAction: value)
    }

    /// Sets the first item's `launchAction` in the groups file to `value`, by hand.
    private func rewrite(launchAction value: Any) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var groups = try #require(object["groups"] as? [[String: Any]])
        var apps = try #require(groups[0]["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = value
        groups[0]["apps"] = apps
        object["groups"] = groups
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
    }

    /// The `launchAction` object of the first item in the groups file.
    private func writtenAction() throws -> [String: Any]? {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let groups = try #require(object["groups"] as? [[String: Any]])
        let apps = try #require(groups.first?["apps"] as? [[String: Any]])
        return apps.first?["launchAction"] as? [String: Any]
    }

    /// The first item of a freshly started store.
    private func reloadedItem() throws -> (item: GroupItem, group: DockGroup) {
        let group = try #require(store().groups.first)
        return (try #require(group.apps.first), group)
    }

    /// Opens `item` as the user's own click does; returns the report entry and the workspace.
    private func open(_ item: GroupItem, in group: DockGroup) async -> (LaunchReport.Entry?, LaunchActionFakeWorkspace) {
        let workspace = LaunchActionFakeWorkspace()
        let report = await GroupLauncher(workspace: workspace).open(item, inGroup: group, source: .userAction)
        return (report.entries.first, workspace)
    }

    /// Checks that `item` isn't opened at all, for `refusal`.
    private func expectNotOpened(_ item: GroupItem, in group: DockGroup, _ refusal: LaunchActionItemRefusal, sourceLocation: SourceLocation = #_sourceLocation) async {
        let (entry, workspace) = await open(item, in: group)
        #expect(entry?.launchActionRefusal == refusal, sourceLocation: sourceLocation)
        #expect(!workspace.openedAnything, "neither with the action nor plainly", sourceLocation: sourceLocation)
        // Open All too.
        let all = LaunchActionFakeWorkspace()
        let report = await GroupLauncher(workspace: all).openAll(group, source: .userAction)
        #expect(report.entries.first?.launchActionRefusal == refusal, sourceLocation: sourceLocation)
        #expect(!all.openedAnything, sourceLocation: sourceLocation)
    }

    private func expectOpenedWithTheProfile(_ item: GroupItem, in group: DockGroup, sourceLocation: SourceLocation = #_sourceLocation) async {
        let (entry, workspace) = await open(item, in: group)
        #expect(entry?.outcome == .launched, sourceLocation: sourceLocation)
        #expect(workspace.starts.map(\.arguments) == [["--profile-directory=Work"]], sourceLocation: sourceLocation)
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: - Enabled

    @Test func anEnabledActionIsWrittenWithItsStatusAndRunsAfterARestart() async throws {
        save(F.website(.chrome))
        #expect(try writtenAction() as? [String: String] == ["status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Work"])

        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .enabled(Self.work))
        #expect(item.launchActionStatus == .enabled(Self.work))
        await expectOpenedWithTheProfile(item, in: group)
    }

    // MARK: - Under review

    @Test func anImportedActionStaysUnderReviewAfterARestart() async throws {
        var imported = F.website(nil)
        imported.launchActionSetting = LaunchActionSetting.enabled(Self.work).disabledForImport
        save(imported)
        #expect(try writtenAction() as? [String: String] == [
            "status": "review", "reason": "imported", "template": "browserProfile", "browser": "chrome", "profile": "Work",
        ])

        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.imported(Self.work)))
        #expect(item.launchActionStatus == .imported(Self.work), "the window still shows it for review")
        #expect(LaunchActionCaption(item: item) { _ in false }?.needsReview == true)
        #expect(item.launchAction == nil)
        await expectNotOpened(item, in: group, .plan(.actionDisabled))
        // And it's written the same again.
        let again = store()
        again.updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: group.id)
        #expect(try writtenAction()?["reason"] as? String == "imported")
        #expect(try reloadedItem().item.launchActionSetting == .needsReview(.imported(Self.work)))
    }

    @Test func anInvalidActionStaysUnderReviewAfterARestart() async throws {
        try write(launchAction: ["template": "browserProfile", "browser": "chrome", "profile": "--remote-debugging-port=9222"])

        let (first, firstGroup) = try reloadedItem()
        #expect(first.launchActionSetting == .needsReview(.invalid(.profileName(.leadingHyphen))))
        await expectNotOpened(first, in: firstGroup, .plan(.actionNeedsReview))
        // Any save writes it under review; the refused name stays inert in the object.
        store().updateDetails(ItemDetails(alias: "Hub"), ofItem: first.id, inGroup: firstGroup.id)
        let written = try #require(try writtenAction())
        #expect(written["status"] as? String == "review" && written["reason"] as? String == "invalid")

        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
        #expect(item.launchActionStatus == .invalid)
        #expect(LaunchActionCaption(item: item) { _ in false }?.needsReview == true)
        await expectNotOpened(item, in: group, .plan(.actionNeedsReview))
    }

    @Test func anInvalidActionSetInCodeIsWrittenUnderReview() async throws {
        var item = F.website(nil)
        item.setLaunchAction(.browserProfile(browser: .chrome, profileName: "../Default"))
        save(item)
        #expect(try writtenAction() as? [String: String] == ["status": "review", "reason": "invalid"])
        let (reloaded, group) = try reloadedItem()
        #expect(reloaded.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
        await expectNotOpened(reloaded, in: group, .plan(.actionNeedsReview))
    }

    @Test func anImportedActionWhoseFieldsAreBrokenIsInvalid() async throws {
        try write(launchAction: ["status": "review", "reason": "imported", "template": "browserProfile", "browser": "safari", "profile": "Work"])
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.invalid(.unknownBrowser)))
        await expectNotOpened(item, in: group, .plan(.actionNeedsReview))
    }

    @Test func anImportedActionOnAnAppIsInvalid() throws {
        let app = AppReference(bundleIdentifier: "com.example.app", name: "App")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        object["launchAction"] = ["status": "review", "reason": "imported", "template": "browserProfile", "browser": "chrome", "profile": "Work"]
        let read = try JSONDecoder().decode(GroupItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.launchActionSetting == .needsReview(.invalid(.unsupportedItemKind)))
    }

    // MARK: - Files without a status

    @Test func aValidActionWithoutAStatusStillRuns() async throws {
        try write(launchAction: ["template": "browserProfile", "browser": "chrome", "profile": "Work"])
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .enabled(Self.work), "as before statuses")
        await expectOpenedWithTheProfile(item, in: group)
        // The next save writes the status.
        store().updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: group.id)
        #expect(try writtenAction()?["status"] as? String == "enabled")
    }

    @Test func anInvalidActionWithoutAStatusIsUnderReview() async throws {
        try write(launchAction: ["template": "browserProfile", "browser": "chrome"])
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.invalid(.missingProfile)))
        await expectNotOpened(item, in: group, .plan(.actionNeedsReview))
        store().updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: group.id)
        #expect(try writtenAction() as? [String: String] == ["status": "review", "reason": "invalid", "template": "browserProfile", "browser": "chrome"])
        let (reloaded, reloadedGroup) = try reloadedItem()
        #expect(reloaded.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
        await expectNotOpened(reloaded, in: reloadedGroup, .plan(.actionNeedsReview))
    }

    // MARK: - Statuses this version doesn't know

    /// The `status` (and `reason`) keys added to a valid action, as JSON, and why it's refused.
    nonisolated static let refusedStatuses: [(status: String, rejection: LaunchActionRejection)] = [
        (#"{"status": "approved"}"#, .unknownStatus),
        (#"{"status": "Enabled"}"#, .unknownStatus),
        (#"{"status": "ENABLED"}"#, .unknownStatus),
        (#"{"status": "on"}"#, .unknownStatus),
        (#"{"status": ""}"#, .unknownStatus),
        (#"{"status": " enabled"}"#, .unknownStatus),
        (#"{"status": "review"}"#, .unknownStatus),
        (#"{"status": "review", "reason": "approved"}"#, .unknownStatus),
        (#"{"status": "review", "reason": ""}"#, .unknownStatus),
        (#"{"status": "review", "reason": "invalid"}"#, .markedInvalid),
        (#"{"status": "review", "reason": 1}"#, .wrongValueType),
        (#"{"status": "review", "reason": null}"#, .wrongValueType),
        (#"{"status": 1}"#, .wrongValueType),
        (#"{"status": true}"#, .wrongValueType),
        (#"{"status": null}"#, .wrongValueType),
        (#"{"status": ["enabled"]}"#, .wrongValueType),
        (#"{"status": {"value": "enabled"}}"#, .wrongValueType),
        // A reason belongs to a review only.
        (#"{"status": "enabled", "reason": "imported"}"#, .unknownKey),
        (#"{"reason": "imported"}"#, .unknownKey),
    ]

    @Test(arguments: refusedStatuses)
    func aStatusOtherThanEnabledOrAKnownReviewNeverRuns(_ status: String, _ rejection: LaunchActionRejection) async throws {
        var value: [String: Any] = ["template": "browserProfile", "browser": "chrome", "profile": "Work"]
        let keys = try #require(JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        value.merge(keys) { $1 }
        try write(launchAction: value)
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.invalid(rejection)))
        #expect(item.launchAction == nil && item.launchActionStatus == .invalid)
        #expect(LaunchActionArgumentPlan.make(for: item, browserBundleIdentifier: "com.google.Chrome", isInstalled: { _ in true }) == .failure(.actionNeedsReview))
        await expectNotOpened(item, in: group, .plan(.actionNeedsReview))
        // Written back under review as invalid, and still refused after another restart.
        store().updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: group.id)
        let written = try #require(try writtenAction())
        #expect(written["status"] as? String == "review" && written["reason"] as? String == "invalid")
        let (reloaded, reloadedGroup) = try reloadedItem()
        #expect(reloaded.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
        await expectNotOpened(reloaded, in: reloadedGroup, .plan(.actionNeedsReview))
    }

    // MARK: - Turning it on and off

    @Test func turnOnWritesEnabledAndTheItemRunsAfterARestart() async throws {
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        let id = save(imported)

        let editing = store()
        var draft = ItemDetailsDraft(try #require(editing.group(withID: id)?.apps.first), installedBrowsers: Self.allInstalled)
        let action = try #require(draft.launchActionToTurnOn)
        draft.confirmLaunchAction(action)
        #expect(editing.saveItemEdits(of: draft, endingWith: .done, ofItem: imported.id, inGroup: id))
        #expect(try writtenAction() as? [String: String] == ["status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Work"])

        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .enabled(Self.work))
        await expectOpenedWithTheProfile(item, in: group)
    }

    @Test func turningAnImportedActionOffRemovesTheKey() async throws {
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        let id = save(imported)

        let editing = store()
        var draft = ItemDetailsDraft(try #require(editing.group(withID: id)?.apps.first), installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(false)
        #expect(editing.saveItemEdits(of: draft, endingWith: .done, ofItem: imported.id, inGroup: id))
        #expect(try writtenAction() == nil)
        #expect(try reloadedItem().item.launchActionSetting == nil)
    }

    @Test func anInvalidActionIsRemovedByTurningTheToggleOnAndOff() async throws {
        try write(launchAction: ["template": "shellCommand", "browser": "chrome", "profile": "Work"])
        let editing = store()
        let group = try #require(editing.groups.first)
        let item = try #require(group.apps.first)
        #expect(item.launchActionStatus == .invalid)

        // Opening and closing the editor keeps it: still not opened.
        let untouched = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        for ending in [ItemDetailsDraft.Ending.done, .dismissed, .cancel] {
            #expect(untouched.launchActionToSave(endingWith: ending) == nil)
        }
        // On and off again: removed, without asking.
        var draft = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        draft.setBrowserProfileOn(true)
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "on, without a confirmed action: kept")
        draft.setBrowserProfileOn(false)
        #expect(draft.launchActionAwaitingConfirmation == nil)
        #expect(draft.launchActionToSave(endingWith: .cancel) == nil)
        #expect(draft.launchActionToSave(endingWith: .done) == .remove)
        #expect(draft.hasChanges)
        #expect(editing.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: group.id))
        #expect(try writtenAction() == nil)
        #expect(try reloadedItem().item.launchActionSetting == nil)
        // The same with the browser menu set to none.
        var menu = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        menu.setBrowserProfileOn(true)
        let chosen = menu.chooseBrowser(nil)
        #expect(chosen)
        #expect(menu.launchActionToSave(endingWith: .done) == .remove)
    }

    // MARK: - Fields kept as they were

    @Test func unknownFieldsOfARefusedActionAreWrittenBackAsTheyWere() async throws {
        let newer: [String: Any] = [
            "status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Work",
            "container": ["name": "Banking", "colour": "#ff0000", "id": 7, "pinned": true, "tabs": [1, 2.5, "x", NSNull()]],
            "since": "2027-01-01", "Status": "x", "COMMAND": "/bin/sh -c id",
        ]
        try write(launchAction: newer)
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .needsReview(.invalid(.forbiddenKey)))
        await expectNotOpened(item, in: group, .plan(.actionNeedsReview))

        store().updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: group.id)
        let written = try #require(try writtenAction())
        var expected = newer
        expected["status"] = "review"
        expected["reason"] = "invalid"
        expected["COMMAND"] = nil
        #expect(NSDictionary(dictionary: written) == NSDictionary(dictionary: expected))
        #expect(!(try String(contentsOf: fileURL, encoding: .utf8)).contains("/bin/sh"))

        // Saved again after a restart: the same object.
        let (again, againGroup) = try reloadedItem()
        #expect(again.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
        store().updateDetails(ItemDetails(alias: "Hub 2"), ofItem: again.id, inGroup: againGroup.id)
        #expect(NSDictionary(dictionary: try #require(try writtenAction())) == NSDictionary(dictionary: written))
        await expectNotOpened(again, in: againGroup, .plan(.actionNeedsReview))
    }

    @Test func keptFieldsStayWhileRefusedAndGoWithANewAction() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(F.website(nil))) as? [String: Any])
        object["launchAction"] = ["template": "browserProfile.v2", "browser": "chrome", "profile": "Work", "container": "Banking"]
        var item = try JSONDecoder().decode(GroupItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(item.storedLaunchAction?.keptFields["container"] == .string("Banking"))

        // Still refused (as an import turns it off): kept.
        item.launchActionSetting = item.launchActionSetting?.disabledForImport
        #expect(item.storedLaunchAction?.keptFields["container"] == .string("Banking"))
        item.launchActionSetting = .needsReview(.invalid(.unknownTemplate))
        #expect(item.storedLaunchAction?.keptFields.count == 4)

        // A new action, turned on: nothing of the old one.
        item.setLaunchAction(Self.work)
        #expect(item.storedLaunchAction?.keptFields.isEmpty == true)
        #expect(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("Banking") == false)

        // Removed: nothing at all.
        item.setLaunchAction(nil)
        #expect(item.storedLaunchAction == nil)
        #expect(item == F.website(nil))
    }

    @Test func aBackupKeepsTheFieldsOfARefusedAction() throws {
        let refused = ["template": "browserProfile.v2", "browser": "chrome", "profile": "Work", "container": "Banking"]
        let backup = SettingsBackup(appVersion: "0.18.0", groups: [DockGroup(name: "Work", apps: [F.website(nil)])], preferences: PopupPreferences())
        var object = try #require(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        var groups = try #require(object["groups"] as? [[String: Any]])
        var apps = try #require(groups[0]["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = refused
        groups[0]["apps"] = apps
        object["groups"] = groups

        let read = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: object))
        let store = store()
        try read.restore(to: store, preferences: PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero), templates: TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero))
        let written = try #require(try writtenAction())
        #expect(written["reason"] as? String == "invalid" && written["container"] as? String == "Banking")
        #expect(try reloadedItem().item.launchActionSetting == .needsReview(.invalid(.markedInvalid)))
    }

    // MARK: - Accepted risk

    /// A same-user writer of the groups file can turn an action on by hand, as it could always write
    /// an enabled one (threat model D9): the status is no signature. Recorded here, not prevented.
    @Test func aStatusEditedByHandIsTaken() async throws {
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        save(imported)
        var action = try #require(try writtenAction())
        action["status"] = "enabled"
        action["reason"] = nil
        try rewrite(launchAction: action)
        let (item, group) = try reloadedItem()
        #expect(item.launchActionSetting == .enabled(Self.work))
        await expectOpenedWithTheProfile(item, in: group)
    }
}
