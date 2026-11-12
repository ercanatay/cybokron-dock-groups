import Foundation
import Testing
@testable import DockGroupsCore

// The approval record (threat model D9, docs/design/launch-action-approvals.md): an action that's on
// runs only when this Mac's approval file has the digest of exactly that action for that item.
// Turning it on in the group window writes the digest; turning it off, removing the item or group,
// and restoring a backup drop it; nothing from a groups file, backup, template or standalone
// group's configuration brings one. Every workspace is a fake; every file is in a temporary folder.

@Suite("Launch actions: approval record")
@MainActor
struct LaunchActionApprovalTests {
    typealias F = LaunchActionFixtures

    nonisolated static let work = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")
    nonisolated static let allInstalled = Set(BrowserFamily.allCases)

    private let directory: TemporaryDirectory
    private let groupsURL: URL
    private let approvalsURL: URL
    private let approvals: LaunchActionApprovalStore

    init() throws {
        directory = try TemporaryDirectory()
        groupsURL = directory.url.appending(components: "DockGroups", "groups.json")
        approvalsURL = directory.url.appending(components: "DockGroups", LaunchActionApprovalStore.fileName)
        approvals = LaunchActionApprovalStore(fileURL: approvalsURL)
    }

    /// A store on the groups file with the approval file next to it, as the app has after a (re)start.
    private func store() -> GroupStore {
        GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero, approvals: approvals)
    }

    private func launcher(_ workspace: LaunchActionFakeWorkspace) -> GroupLauncher {
        GroupLauncher(workspace: workspace, approvals: approvals)
    }

    /// Opens `item` as the user's click does; the report entry and the workspace.
    private func open(_ item: GroupItem, source: LaunchSource = .userAction) async -> (LaunchReport.Entry?, LaunchActionFakeWorkspace) {
        let workspace = LaunchActionFakeWorkspace()
        let report = await launcher(workspace).open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: source)
        return (report.entries.first, workspace)
    }

    private func approvalFile() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: approvalsURL.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: approvalsURL)) as? [String: Any]
    }

    private func records() throws -> [[String: String]] {
        (try approvalFile()?["approvals"] as? [[String: String]]) ?? []
    }

    // MARK: - Digest

    @Test func theCanonicalTextNamesEveryFieldWithItsLength() throws {
        let item = F.website()
        let text = try #require(LaunchActionApprovalDigest.canonical(for: item))
        #expect(text == """
        cybokron-dock-groups/launch-action-approval/1
        item=27:https://github.com/cybokron
        kind=7:website
        url=27:https://github.com/cybokron
        template=14:browserProfile
        browser=6:chrome
        profile=4:Work
        opener=0:

        """)
        let digest = try #require(LaunchActionApprovalDigest.digest(for: item))
        #expect(LaunchActionApprovalDigest.isWellFormed(digest))
        #expect(digest == LaunchActionApprovalDigest.digest(for: F.website()), "the same action, the same digest")
    }

    @Test func everyFieldChangesTheDigest() throws {
        let base = try #require(LaunchActionApprovalDigest.digest(for: F.website()))
        let changed: [GroupItem] = [
            F.website(profile: "Personal"),
            F.website(.edge),
            F.website(.firefox),
            F.website(url: URL(string: "https://github.com/cybokron/other")!),
            F.website(url: URL(string: "https://evil.example/cybokron")!),
            F.website().launching(with: ItemOpener(bundleIdentifier: "com.google.Chrome", name: "Chrome")),
        ]
        let digests = try changed.map { try #require(LaunchActionApprovalDigest.digest(for: $0)) }
        #expect(!digests.contains(base))
        #expect(Set(digests).count == digests.count)
        // Not covered: what doesn't change what opens (its name, details, delay).
        #expect(LaunchActionApprovalDigest.digest(for: F.website(name: "Hub").launching(after: 5)) == base)
    }

    @Test func onlyAnActionThatsOnAndValidHasADigest() {
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        var forged = F.website(nil)
        forged.launchActionSetting = .enabled(.browserProfile(browser: .chrome, profileName: "--remote-debugging-port=9222"))
        for item in [F.website(nil), imported, forged, F.website(profile: "../Default")] {
            #expect(LaunchActionApprovalDigest.digest(for: item) == nil)
        }
    }

    // MARK: - The launcher

    @Test func anApprovedActionRuns() async throws {
        try approvals.approve(F.website())
        let (entry, workspace) = await open(F.website())
        #expect(entry?.outcome == .launched)
        #expect(workspace.starts.map(\.arguments) == [["--profile-directory=Work"]])
    }

    @Test func withoutTheApprovalFileNothingRuns() async {
        #expect(!FileManager.default.fileExists(atPath: approvalsURL.path))
        let (entry, workspace) = await open(F.website())
        #expect(entry?.launchActionRefusal == .approval(.missing))
        #expect(entry?.outcome == .failed(reason: F.notOpened))
        #expect(!workspace.openedAnything, "neither with the action nor plainly")
        // A launcher without approvals at all runs none either.
        let none = LaunchActionFakeWorkspace()
        let report = await GroupLauncher(workspace: none).open(F.website(), inGroup: DockGroup(name: "Work", apps: [F.website()]), source: .userAction)
        #expect(report.entries.first?.launchActionRefusal == .approval(.missing))
        #expect(!none.openedAnything)
    }

    @Test(arguments: [
        LaunchActionFixtures.website(profile: "Personal"),
        LaunchActionFixtures.website(.firefox),
        LaunchActionFixtures.website(profile: "Default"),
        LaunchActionFixtures.website(url: URL(string: "https://github.com/cybokron/secret")!),
    ])
    func aChangedActionDoesntRunOnTheOldApproval(changed: GroupItem) async throws {
        try approvals.approve(F.website())
        let (entry, workspace) = await open(changed)
        let refusal: LaunchActionItemRefusal = changed.normalizedBundleIdentifier == F.website().normalizedBundleIdentifier
            ? .approval(.mismatch) : .approval(.missing)
        #expect(entry?.launchActionRefusal == refusal)
        #expect(!workspace.openedAnything)
    }

    @Test func theApprovalIsReadAtEveryLaunch() async throws {
        try approvals.approve(F.website())
        #expect(await open(F.website()).0?.outcome == .launched)
        try FileManager.default.removeItem(at: approvalsURL)
        #expect(await open(F.website()).0?.launchActionRefusal == .approval(.missing))
    }

    @Test(arguments: [
        "not json",
        #"{"formatVersion": 2, "approvals": []}"#,
        #"{"approvals": []}"#,
        #"{"formatVersion": 1}"#,
        #"{"formatVersion": 1, "approvals": {}}"#,
    ])
    func anUnreadableApprovalFileApprovesNothing(contents: String) async throws {
        try approvals.approve(F.website())
        try Data(contents.utf8).write(to: approvalsURL)
        #expect(approvals.load().isEmpty)
        let (entry, workspace) = await open(F.website())
        #expect(entry?.launchActionRefusal == .approval(.missing))
        #expect(!workspace.openedAnything)
    }

    @Test func malformedRecordsAreSkipped() async throws {
        let digest = try #require(LaunchActionApprovalDigest.digest(for: F.website()))
        let bad: [Any] = [
            ["item": "https://github.com/cybokron", "digest": digest.uppercased()],
            ["item": "https://github.com/cybokron", "digest": String(digest.dropLast())],
            ["item": "https://github.com/cybokron", "digest": digest, "enabled": true],
            ["item": "HTTPS://GITHUB.COM/CYBOKRON", "digest": digest],
            ["item": 1, "digest": digest],
            ["digest": digest],
            "https://github.com/cybokron",
        ]
        try FileManager.default.createDirectory(at: approvalsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "approvals": bad]).write(to: approvalsURL)
        #expect(approvals.load().isEmpty)
        #expect(await open(F.website()).0?.launchActionRefusal == .approval(.missing))

        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "approvals": bad + [["item": "https://github.com/cybokron", "digest": digest]]]).write(to: approvalsURL)
        #expect(await open(F.website()).0?.outcome == .launched)
    }

    @Test func itemsWithoutAnActionNeedNoApproval() async {
        let workspace = LaunchActionFakeWorkspace()
        let plain = F.website(nil)
        let report = await launcher(workspace).open(plain, inGroup: DockGroup(name: "Work", apps: [plain]), source: .userAction)
        #expect(report.entries.map(\.outcome) == [.launched])
        #expect(workspace.websiteRequests == [[F.url]])
        #expect(!FileManager.default.fileExists(atPath: approvalsURL.path))
    }

    @Test func refusalCodesAreFixed() {
        #expect(LaunchActionItemRefusal.approval(.missing).code == "approval.missing")
        #expect(LaunchActionItemRefusal.approval(.mismatch).code == "approval.mismatch")
        #expect(LaunchActionItemRefusal.approval(.missing).outcome == .failed(reason: F.notOpened))
    }

    // MARK: - The store

    /// Turn On in the editor: the digest is written, the item runs, also after a restart; turning
    /// it off drops the digest (and the file with the last one).
    @Test func turnOnWritesTheDigestAndTurningOffRemovesIt() async throws {
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        let editing = store()
        let id = editing.addGroup(named: "Work").id
        editing.addItems([imported], toGroup: id)
        #expect(try approvalFile() == nil)

        var draft = ItemDetailsDraft(try #require(editing.group(withID: id)?.apps.first), installedBrowsers: Self.allInstalled)
        let action = try #require(draft.launchActionToTurnOn)
        draft.confirmLaunchAction(action)
        #expect(editing.saveItemEdits(of: draft, endingWith: .done, ofItem: imported.id, inGroup: id))
        let digest = try #require(LaunchActionApprovalDigest.digest(for: F.website()))
        #expect(try approvalFile()?["formatVersion"] as? Int == 1)
        #expect(try records() == [["item": "https://github.com/cybokron", "digest": digest]])

        let restarted = store()
        let item = try #require(restarted.groups.first?.apps.first)
        #expect(item.launchActionSetting == .enabled(Self.work))
        #expect(await open(item).0?.outcome == .launched)

        var off = ItemDetailsDraft(item, installedBrowsers: Self.allInstalled)
        off.setBrowserProfileOn(false)
        #expect(restarted.saveItemEdits(of: off, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(try approvalFile() == nil, "the last approval went with the action")
    }

    @Test func changingTheProfileReplacesTheDigest() throws {
        let editing = store()
        let id = editing.addGroup(named: "Work").id
        editing.addItems([F.website(nil)], toGroup: id)
        #expect(editing.updateItem(F.website(nil).id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work)))
        #expect(editing.updateItem(F.website(nil).id, inGroup: id, details: nil, launch: nil, launchAction: .enable(.browserProfile(browser: .chrome, profileName: "Personal"))))
        let personal = try #require(LaunchActionApprovalDigest.digest(for: F.website(profile: "Personal")))
        #expect(try records() == [["item": "https://github.com/cybokron", "digest": personal]])
        #expect(approvals.check(F.website()) == .mismatch)
    }

    @Test func removingTheItemOrItsGroupRemovesTheDigest() throws {
        let editing = store()
        let first = editing.addGroup(named: "First").id
        let second = editing.addGroup(named: "Second").id
        let plainOther = F.website(nil, url: URL(string: "https://example.com/")!, name: "Example")
        editing.addItems([F.website(nil)], toGroup: first)
        editing.addItems([plainOther], toGroup: second)
        editing.updateItem(F.website(nil).id, inGroup: first, details: nil, launch: nil, launchAction: .enable(Self.work))
        editing.updateItem(plainOther.id, inGroup: second, details: nil, launch: nil, launchAction: .enable(Self.work))
        #expect(try records().count == 2)

        editing.removeApp(bundleIdentifier: F.website().bundleIdentifier, fromGroup: first)
        #expect(try records().map { $0["item"] } == ["https://example.com/"])
        editing.deleteGroup(second)
        #expect(try approvalFile() == nil)
    }

    /// The digest names the item, not the group: a copy of the group, or the item moved, keeps the
    /// approval of exactly the same action; an archived group keeps it until it's deleted.
    @Test func theSameActionElsewhereKeepsItsApproval() async throws {
        let editing = store()
        let id = editing.addGroup(named: "Work").id
        editing.addItems([F.website(nil)], toGroup: id)
        editing.updateItem(F.website(nil).id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work))
        let copy = try #require(editing.duplicateGroup(id))
        editing.deleteGroup(id)
        #expect(try records().count == 1, "still used by the copy")
        let copied = try #require(editing.group(withID: copy.id)?.apps.first)
        #expect(copied.launchActionSetting == .enabled(Self.work))
        #expect(await open(copied).0?.outcome == .launched)

        editing.archiveGroup(copy.id)
        #expect(try records().count == 1)
        #expect(store().archivedGroups.first?.group.apps.first?.launchActionSetting == .enabled(Self.work))
        editing.deleteArchivedGroup(copy.id)
        #expect(try approvalFile() == nil)
    }

    /// A groups file written elsewhere (another Mac, a recipe, by hand) has no approval here: the
    /// action that's on is read as under review, shown for review, and the item isn't opened.
    @Test func aGroupsFileFromElsewhereHasNoApproval() async throws {
        let elsewhere = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .zero)
        let id = elsewhere.addGroup(named: "Work").id
        elsewhere.addItems([F.website()], toGroup: id)
        #expect(try String(contentsOf: groupsURL, encoding: .utf8).contains(#""status" : "enabled""#))

        let here = store()
        let item = try #require(here.groups.first?.apps.first)
        #expect(item.launchActionSetting == .needsReview(.imported(Self.work)))
        #expect(item.launchActionStatus == .imported(Self.work))
        #expect(LaunchActionCaption(item: item) { _ in false }?.needsReview == true)
        #expect(await open(item).0?.launchActionRefusal == .plan(.actionDisabled))
        // Written under review with the next change; Turn On approves it.
        here.updateDetails(ItemDetails(alias: "Hub"), ofItem: item.id, inGroup: id)
        #expect(try String(contentsOf: groupsURL, encoding: .utf8).contains(#""reason" : "imported""#))
        var draft = ItemDetailsDraft(try #require(here.groups.first?.apps.first), installedBrowsers: Self.allInstalled)
        let action = try #require(draft.launchActionToTurnOn)
        draft.confirmLaunchAction(action)
        #expect(here.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        #expect(await open(try #require(store().groups.first?.apps.first)).0?.outcome == .launched)
    }

    @Test func anActionTurnedOnInCodeWithoutTheWindowIsUnderReviewOnTheNextSave() throws {
        let editing = store()
        let id = editing.addGroup(named: "Work").id
        // Not through `updateItem(… .enable)`: no approval is written.
        editing.updateGroup(id) { $0.apps = [F.website()] }
        #expect(editing.group(withID: id)?.apps.first?.launchActionSetting == .needsReview(.imported(Self.work)))
        #expect(try approvalFile() == nil)
    }

    @Test func aFailedApprovalKeepsTheActionUnderReview() throws {
        // The approval file's place is taken by a folder, so it can't be written.
        try FileManager.default.createDirectory(at: approvalsURL.appending(path: "blocked"), withIntermediateDirectories: true)
        let editing = store()
        let id = editing.addGroup(named: "Work").id
        editing.addItems([F.website(nil)], toGroup: id)
        editing.updateItem(F.website(nil).id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work))
        #expect(editing.group(withID: id)?.apps.first?.launchActionSetting == .needsReview(.imported(Self.work)))
        #expect(editing.issue != nil)
    }

    // MARK: - Import, restore, merge

    private static func backup() -> SettingsBackup {
        SettingsBackup(
            appVersion: "0.18.0",
            groups: [DockGroup(name: "Work", apps: [F.website()])],
            archivedGroups: [ArchivedGroup(group: DockGroup(name: "Old", apps: [F.website(profile: "Old")]), archivedAt: Date(timeIntervalSince1970: 1_791_000_000))],
            templates: [GroupTemplate(saving: DockGroup(name: "Blueprint", apps: [F.website(profile: "Blueprint")]), named: "Blueprint")],
            preferences: PopupPreferences()
        )
    }

    private func preferences() -> PreferencesStore {
        PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero)
    }

    /// Restoring a backup on the Mac that approved the very same action: it still comes in under
    /// review (D4), isn't opened, and the old approval is dropped with the groups it replaced.
    @Test func aRestoredActionHasNoApprovalEvenIfTheSameOneWasApprovedHere() async throws {
        let editing = store()
        let id = editing.addGroup(named: "Local").id
        editing.addItems([F.website(nil)], toGroup: id)
        editing.updateItem(F.website(nil).id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work))
        #expect(try records().count == 1)

        let read = try SettingsBackup.decode(from: Self.backup().encoded())
        let templates = TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero)
        try read.restore(to: editing, preferences: preferences(), templates: templates)

        let restored = (editing.groups + editing.archivedGroups.map(\.group) + templates.templates.map(\.group)).flatMap(\.apps)
        #expect(restored.count == 3 && restored.allSatisfy { $0.launchActionNeedsReview })
        #expect(try approvalFile() == nil, "Replace All dropped the approval of the replaced group")
        let item = try #require(store().groups.first?.apps.first)
        #expect(await open(item).0?.launchActionRefusal == .plan(.actionDisabled))
        // Even with the approval written back by hand, the status keeps it off: only Turn On does.
        try approvals.approve(F.website())
        #expect(await open(try #require(store().groups.first?.apps.first)).0?.launchActionRefusal == .plan(.actionDisabled))
    }

    @Test func mergingKeepsLocalApprovalsAndBringsNone() async throws {
        let editing = store()
        let id = editing.addGroup(named: "Local").id
        let local = F.website(url: URL(string: "https://news.ycombinator.com/")!, name: "HN")
        var plainLocal = local
        plainLocal.setLaunchAction(nil)
        editing.addItems([plainLocal], toGroup: id)
        editing.updateItem(plainLocal.id, inGroup: id, details: nil, launch: nil, launchAction: .enable(Self.work))
        let before = try records()
        #expect(before.count == 1)

        let read = try SettingsBackup.decode(from: Self.backup().encoded())
        let result = try read.merge(into: editing, templates: TemplateStore(persistence: MemoryTemplatePersistence(), saveDelay: .zero))

        #expect(result.groups.addedGroups.map(\.name) == ["Work"])
        #expect(try records() == before, "only the local one")
        let added = try #require(editing.groups.first { $0.name == "Work" }?.apps.first)
        #expect(added.launchActionSetting == .needsReview(.imported(Self.work)))
        #expect(await open(added).0?.launchActionRefusal == .plan(.actionDisabled))
        let kept = try #require(editing.group(withID: id)?.apps.first)
        #expect(await open(kept).0?.outcome == .launched)
    }

    @Test func aGroupFromAnImportedTemplateHasNoApproval() async throws {
        let read = try SettingsBackup.decode(from: Self.backup().encoded())
        let template = try #require(read.templates.first)
        let editing = store()
        let group = editing.addGroup(from: template)
        let item = try #require(editing.group(withID: group.id)?.apps.first)
        #expect(item.launchActionNeedsReview)
        #expect(await open(item).0?.launchActionRefusal == .plan(.actionDisabled))
        #expect(try approvalFile() == nil)
    }

    // MARK: - Standalone groups (D11)

    /// A group's own app, from its configuration file: an approved action runs for its click, with
    /// the same checks as the app's; one without its approval, or changed in the file by hand,
    /// doesn't open at all.
    @Test func theAgentRunsOnlyAnApprovedAction() async throws {
        let configuration = AgentConfiguration(group: DockGroup(name: "Work", apps: [F.website(), AppReference(bundleIdentifier: "com.example.app", name: "App")]), preferences: PopupPreferences())
        let read = try AgentConfiguration.decode(from: configuration.encoded())
        let group = read.group
        #expect(group.apps.first?.launchActionSetting == .enabled(Self.work))

        // Not approved on this Mac: nothing opens for it; the group's other item opens as before.
        let unapproved = LaunchActionFakeWorkspace(installed: ["com.google.Chrome", "com.example.app"])
        let first = await launcher(unapproved).openAll(group, source: .standaloneAgent)
        #expect(first.entries.map(\.launchActionRefusal) == [.approval(.missing), nil])
        #expect(first.entries.map(\.outcome) == [.failed(reason: F.notOpened), .launched])
        #expect(unapproved.starts.isEmpty && unapproved.websiteRequests.isEmpty && unapproved.openedWith.isEmpty)

        // Approved in the main app: the agent's click runs it.
        try approvals.approve(F.website())
        let approved = LaunchActionFakeWorkspace()
        let report = await launcher(approved).open(try #require(group.apps.first), inGroup: group, source: .standaloneAgent)
        #expect(report.entries.map(\.outcome) == [.launched])
        #expect(approved.starts.map(\.arguments) == [["--profile-directory=Work"]])
        #expect(approved.starts.map(\.environment) == [[:]])

        // The configuration edited by hand to another profile: the approval doesn't cover it.
        var object = try #require(JSONSerialization.jsonObject(with: configuration.encoded()) as? [String: Any])
        var json = try #require(object["group"] as? [String: Any])
        var apps = try #require(json["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = ["status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Personal"]
        json["apps"] = apps
        object["group"] = json
        let edited = try AgentConfiguration.decode(from: JSONSerialization.data(withJSONObject: object)).group
        let forged = LaunchActionFakeWorkspace()
        let refused = await launcher(forged).open(try #require(edited.apps.first), inGroup: edited, source: .standaloneAgent)
        #expect(refused.entries.map(\.launchActionRefusal) == [.approval(.mismatch)])
        #expect(!forged.openedAnything)
    }

    @Test func theAgentChecksTheSameRulesAsTheApp() async throws {
        try approvals.approve(F.website())
        // Running browser, missing browser, imported action: refused in the agent as in the app.
        let running = LaunchActionFakeWorkspace(running: ["com.google.Chrome"])
        let group = DockGroup(name: "Work", apps: [F.website()])
        #expect(await launcher(running).open(F.website(), inGroup: group, source: .standaloneAgent).entries.first?.launchActionRefusal == .run(.browserAlreadyRunning))
        let missing = LaunchActionFakeWorkspace(installed: [])
        #expect(await launcher(missing).open(F.website(), inGroup: group, source: .standaloneAgent).entries.first?.launchActionRefusal == .plan(.browserNotInstalled))
        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.work))
        #expect(await open(imported, source: .standaloneAgent).0?.launchActionRefusal == .plan(.actionDisabled))
    }

    @Test func theAgentReadsTheAppsApprovalFile() {
        #expect(LaunchActionApprovalStore.fileName == "launch-action-approvals.json")
        #expect(LaunchActionApprovalStore.defaultFileURL.deletingLastPathComponent() == JSONFileGroupPersistence.defaultFileURL.deletingLastPathComponent())
        #expect(LaunchActionApprovalStore.onThisMac.fileURL == LaunchActionApprovalStore.defaultFileURL)
    }
}
