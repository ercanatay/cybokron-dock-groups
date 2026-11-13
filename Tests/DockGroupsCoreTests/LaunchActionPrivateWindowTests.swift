import Foundation
import Testing
@testable import DockGroupsCore

// Launch actions: the private-window template (docs/design/launch-action-private-window.md). The
// model and its strict decoder, the plan (a fixed option per browser, the address as its own
// argument), the runner and the launcher (started only while the browser isn't running, only with
// this Mac's approval), the approval digest, and the group window's draft, row and confirmation.
// Nothing here starts a real app: every workspace is a fake.

enum PrivateWindowFixtures {
    static let url = LaunchActionFixtures.url

    /// A website item for `url` with a private-window action in `browser`.
    static func website(_ browser: BrowserFamily = .chrome, url: URL = url, name: String = "GitHub") -> GroupItem {
        var item = AppReference(websiteURL: url, name: name)
        item.setLaunchAction(.browserPrivate(browser: browser))
        return item
    }

    static func plan(_ browser: BrowserFamily = .chrome, url: URL = url) -> Result<LaunchActionArgumentPlan, LaunchActionArgumentRefusal> {
        LaunchActionArgumentPlan.make(
            setting: .enabled(.browserPrivate(browser: browser)),
            itemKind: .website,
            url: url,
            browserBundleIdentifier: browser.bundleIdentifiers[0],
            isInstalled: { _ in true }
        )
    }

    /// The option each browser gets, the address following it.
    static let options: [(BrowserFamily, String, String)] = [
        (.chrome, "com.google.Chrome", "--incognito"),
        (.edge, "com.microsoft.edgemac", "--inprivate"),
        (.brave, "com.brave.Browser", "--incognito"),
        (.firefox, "org.mozilla.firefox", "-private-window"),
    ]
}

// MARK: - Model and decoder

@Suite("Launch actions: private window, model and decoder")
struct LaunchActionPrivateWindowCodingTests {
    typealias T = LaunchActionTests

    static func action(_ browser: Any = "chrome") -> [String: Any] {
        ["template": "browserPrivate", "browser": browser]
    }

    @Test(arguments: BrowserFamily.allCases)
    func aPrivateWindowIsReadForEveryBrowser(browser: BrowserFamily) throws {
        for status: [String: Any] in [[:], ["status": "enabled"]] {
            let item = try T.decode(T.saved(launchAction: Self.action(browser.rawValue).merging(status) { $1 }))
            #expect(item.launchActionSetting == .enabled(.browserPrivate(browser: browser)))
            #expect(item.launchAction == .browserPrivate(browser: browser))
        }
    }

    @Test func itIsWrittenWithItsTemplateAndBrowserOnly() throws {
        var item = T.website
        item.setLaunchAction(.browserPrivate(browser: .firefox))
        let written = try #require(try T.object(item)["launchAction"] as? [String: String])
        #expect(written == ["status": "enabled", "template": "browserPrivate", "browser": "firefox"])
        #expect(try T.decode(JSONEncoder().encode(item)) == item)
    }

    @Test func anImportedOneStaysOff() throws {
        let item = try T.decode(T.saved(launchAction: Self.action().merging(["status": "review", "reason": "imported"]) { $1 }))
        #expect(item.launchActionSetting == .needsReview(.imported(.browserPrivate(browser: .chrome))))
        #expect(item.launchAction == nil)
        let written = try #require(try T.object(item)["launchAction"] as? [String: String])
        #expect(written == ["status": "review", "reason": "imported", "template": "browserPrivate", "browser": "chrome"])
    }

    /// A private window has no profile: a `profile` key, whatever it holds, refuses the action
    /// instead of being ignored.
    @Test(arguments: ["Work", "", "--incognito", "-P"])
    func aProfileKeyIsRefused(profile: String) throws {
        try T.expectRefused(Self.action().merging(["profile": profile]) { $1 }, .unknownKey)
    }

    @Test func aProfileKeyOfAnyTypeIsRefused() throws {
        for profile: Any in [NSNull(), 1, ["Work"], ["name": "Work"]] {
            try T.expectRefused(Self.action().merging(["profile": profile]) { $1 }, .unknownKey)
        }
        try T.expectRefused(Self.action().merging(["status": "enabled", "profile": "Work"]) { $1 }, .unknownKey)
    }

    @Test func otherBadObjectsAreRefused() throws {
        try T.expectRefused(["template": "browserPrivate"], .missingBrowser)
        try T.expectRefused(Self.action("safari"), .unknownBrowser)
        try T.expectRefused(Self.action("Chrome"), .unknownBrowser)
        try T.expectRefused(Self.action(1), .wrongValueType)
        try T.expectRefused(Self.action().merging(["url": "https://evil.example"]) { $1 }, .unknownKey)
        try T.expectRefused(Self.action().merging(["arguments": ["--remote-debugging-port=9222"]]) { $1 }, .forbiddenKey)
        try T.expectRefused(["template": "BrowserPrivate", "browser": "chrome"], .unknownTemplate)
        try T.expectRefused(["template": "browserIncognito", "browser": "chrome"], .unknownTemplate)
    }

    @Test(arguments: [AppReference.Kind.application, .file, .folder])
    func itIsForWebsitesOnly(kind: AppReference.Kind) {
        #expect(!LaunchAction.browserPrivate(browser: .chrome).isAllowed(for: kind))
        #expect(LaunchAction.browserPrivate(browser: .chrome).isAllowed(for: .website))
        #expect(LaunchAction.browserPrivate(browser: .chrome).rejection == nil)
        var app = T.app
        app.setLaunchAction(.browserPrivate(browser: .chrome))
        #expect(app.launchActionSetting == .needsReview(.invalid(.unsupportedItemKind)))
        #expect(app.launchAction == nil)
    }

    @Test func aBrowserProfileStillNeedsItsProfile() throws {
        try T.expectRefused(["template": "browserProfile", "browser": "chrome"], .missingProfile)
        let item = try T.decode(T.saved(launchAction: T.action()))
        #expect(item.launchAction == .browserProfile(browser: .chrome, profileName: "Work"))
    }
}

// MARK: - Plan

@Suite("Launch actions: private window, plan")
struct LaunchActionPrivateWindowPlanTests {
    typealias P = PrivateWindowFixtures
    typealias Plan = LaunchActionArgumentPlan

    @Test(arguments: P.options)
    func eachBrowserGetsItsOptionAndTheAddress(browser: BrowserFamily, bundleIdentifier: String, option: String) throws {
        let plan = try P.plan(browser).get()
        #expect(plan.executableBundleIdentifier == bundleIdentifier)
        #expect(plan.arguments == [option, "https://github.com/cybokron"])
        #expect(Plan.privateWindowOption(for: browser) == option)
        #expect(plan.url == P.url)
        // Handed over as an open event the address would open in a normal window.
        #expect(plan.opensAddressFromArguments)
        #expect(plan.urlsToOpen.isEmpty)
    }

    @Test(arguments: BrowserFamily.allCases)
    func aBrowserProfileStillHandsTheAddressOver(browser: BrowserFamily) throws {
        let plan = try LaunchActionArgumentPlanTests.plan(LaunchActionArgumentPlanTests.enabled(browser), browser: browser.bundleIdentifiers[0]).get()
        #expect(!plan.opensAddressFromArguments)
        #expect(plan.urlsToOpen == [LaunchActionArgumentPlanTests.url])
    }

    @Test(arguments: BrowserFamily.allCases)
    func theArgumentsHaveTheTemplatesShapeOnly(browser: BrowserFamily) throws {
        for address in ["https://github.com/cybokron", "http://example.com:8080/a/b?q=1&r=two#top", "https://xn--gzel-3qa.example/%C3%BC"] {
            let url = try #require(URL(string: address))
            let plan = try P.plan(browser, url: url).get()
            #expect(plan.arguments.count == 2)
            #expect(plan.arguments[0] == Plan.privateWindowOption(for: browser))
            #expect(plan.arguments[1] == url.absoluteString)
            #expect(!plan.arguments[1].hasPrefix("-"))
            #expect(plan.arguments.allSatisfy(Plan.isSingleArgument))
            #expect(!plan.arguments.contains { $0.hasPrefix("--user-data-dir") || $0 == "-profile" || $0.hasPrefix("--profile-directory") || $0 == "-P" })
        }
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "mailto:me@example.com", "https://user:pass@example.com/",
        "ftp://example.com/", "chrome://settings",
    ])
    func otherAddressesAreRefused(address: String) throws {
        let url = try #require(URL(string: address))
        for browser in BrowserFamily.allCases {
            #expect(P.plan(browser, url: url) == .failure(.urlRejected))
        }
    }

    @Test func theBrowserMustBeTheTemplatesAndInstalled() {
        let action = LaunchActionSetting.enabled(.browserPrivate(browser: .firefox))
        for identifier in ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefoxdeveloperedition", "/Applications/Firefox.app"] {
            #expect(Plan.make(setting: action, itemKind: .website, url: P.url, browserBundleIdentifier: identifier, isInstalled: { _ in true }) == .failure(.unsupportedBrowser))
        }
        #expect(Plan.make(setting: action, itemKind: .website, url: P.url, browserBundleIdentifier: "org.mozilla.firefox", isInstalled: { _ in false }) == .failure(.browserNotInstalled))
        #expect(Plan.make(setting: action, itemKind: .application, url: P.url, browserBundleIdentifier: "org.mozilla.firefox", isInstalled: { _ in true }) == .failure(.itemKindMismatch))
        #expect(Plan.make(setting: .needsReview(.imported(.browserPrivate(browser: .firefox))), itemKind: .website, url: P.url,
                          browserBundleIdentifier: "org.mozilla.firefox", isInstalled: { _ in true }) == .failure(.actionDisabled))
    }

    @Test func anItemGetsItsOwnAddress() throws {
        let url = try #require(URL(string: "https://example.com/inbox"))
        let plan = try #require(Plan.make(for: P.website(.edge, url: url), browserBundleIdentifier: "com.microsoft.edgemac") { _ in true }).get()
        #expect(plan.arguments == ["--inprivate", "https://example.com/inbox"])
    }
}

// MARK: - Runner and launcher

@Suite("Launch actions: private window, runner and launcher")
@MainActor
struct LaunchActionPrivateWindowRunnerTests {
    typealias P = PrivateWindowFixtures
    typealias F = LaunchActionFixtures

    @Test(arguments: P.options)
    func aBrowserThatIsntRunningIsStartedWithTheAddressInItsArguments(browser: BrowserFamily, bundleIdentifier: String, option: String) async throws {
        let workspace = LaunchActionFakeWorkspace(installed: [bundleIdentifier])

        let outcome = await LaunchActionRunner(workspace: workspace).run(try P.plan(browser).get())

        #expect(outcome == .launched)
        #expect(workspace.starts == [LaunchActionFakeWorkspace.Start(
            application: LaunchActionFakeWorkspace.location(of: bundleIdentifier),
            urls: [],
            arguments: [option, "https://github.com/cybokron"],
            environment: [:],
            activates: true,
            createsNewApplicationInstance: false
        )])
        #expect(workspace.runningQueries == [bundleIdentifier])
    }

    @Test(arguments: BrowserFamily.allCases)
    func aRunningBrowserIsRefusedAndNothingIsSentToIt(browser: BrowserFamily) async throws {
        let identifier = browser.bundleIdentifiers[0]
        let workspace = LaunchActionFakeWorkspace(installed: [identifier], running: [identifier.uppercased()])

        let outcome = await LaunchActionRunner(workspace: workspace).run(try P.plan(browser).get())

        #expect(outcome == .refused(.browserAlreadyRunning))
        #expect(!workspace.openedAnything, "no page in a normal window of the running browser")
    }

    @Test func clickingAnApprovedItemStartsItsBrowserInAPrivateWindow() async {
        let workspace = LaunchActionFakeWorkspace()
        let item = P.website(.firefox)

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction)

        #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .launched)])
        #expect(workspace.starts.map(\.arguments) == [["-private-window", "https://github.com/cybokron"]])
        #expect(workspace.starts.map(\.urls) == [[]])
        #expect(workspace.starts.map(\.environment) == [[:]])
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
    }

    @Test func aRunningBrowserMeansTheItemIsntOpenedAtAll() async {
        let workspace = LaunchActionFakeWorkspace(running: ["com.google.Chrome"])
        let item = P.website()

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).openAll(DockGroup(name: "Work", apps: [item]), source: .userAction)

        #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .failed(reason: F.notOpened), launchActionRefusal: .run(.browserAlreadyRunning))])
        #expect(!workspace.openedAnything)
    }

    @Test func withoutItsApprovalNothingOpens() async {
        let item = P.website()
        let profileApproved = F.approving(F.website())
        for (approvals, refusal) in [
            (LaunchActionApprovalStore.inMemory(), LaunchActionApprovalRefusal.missing),
            (nil, .missing),
            // An approval of the same website in a browser profile doesn't cover a private window.
            (profileApproved, .mismatch),
        ] as [(LaunchActionApprovalStore?, LaunchActionApprovalRefusal)] {
            let workspace = LaunchActionFakeWorkspace()
            let report = await GroupLauncher(workspace: workspace, approvals: approvals).open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction)
            #expect(report.entries.first?.launchActionRefusal == .approval(refusal))
            #expect(!workspace.openedAnything)
        }
    }

    @Test(arguments: LaunchActionFixtures.unattendedSources)
    func unattendedSourcesDontOpenIt(source: LaunchSource) async {
        let workspace = LaunchActionFakeWorkspace()
        let item = P.website()

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: source)

        #expect(report.entries.first?.launchActionRefusal == .unattendedSource(source))
        #expect(!workspace.openedAnything)
    }

    // MARK: Digest

    @Test func theCanonicalTextHasTheTemplateAndNoProfile() throws {
        let text = try #require(LaunchActionApprovalDigest.canonical(for: P.website()))
        #expect(text == """
        cybokron-dock-groups/launch-action-approval/1
        item=27:https://github.com/cybokron
        kind=7:website
        url=27:https://github.com/cybokron
        template=14:browserPrivate
        browser=6:chrome
        opener=0:

        """)
    }

    @Test func everyFieldChangesTheDigest() throws {
        let base = try #require(LaunchActionApprovalDigest.digest(for: P.website()))
        let changed: [GroupItem] = [
            P.website(.edge),
            P.website(.brave),
            P.website(.firefox),
            P.website(url: URL(string: "https://github.com/cybokron/other")!),
            P.website().launching(with: ItemOpener(bundleIdentifier: "com.google.Chrome", name: "Chrome")),
            F.website(),
            F.website(profile: "Default"),
        ]
        let digests = try changed.map { try #require(LaunchActionApprovalDigest.digest(for: $0)) }
        #expect(!digests.contains(base))
        #expect(Set(digests).count == digests.count)
        #expect(LaunchActionApprovalDigest.digest(for: P.website(name: "Hub").launching(after: 5)) == base)
    }
}

// MARK: - Group window

@Suite("Launch actions: private window in the editor, row and confirmation")
@MainActor
struct LaunchActionPrivateWindowEditingTests {
    typealias P = PrivateWindowFixtures
    typealias F = LaunchActionFixtures

    nonisolated static let privateChrome = LaunchAction.browserPrivate(browser: .chrome)

    @Test func choosingAPrivateWindowIsSavedOnOnceConfirmed() throws {
        let approvals = LaunchActionApprovalStore.inMemory()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero, approvals: approvals)
        let item = F.website(nil)
        let id = store.addGroup(named: "Work").id
        store.addItems([item], toGroup: id)

        var draft = ItemDetailsDraft(item, installedBrowsers: [.chrome, .firefox])
        #expect(!draft.isPrivateWindow)
        draft.setBrowserProfileOn(true)
        draft.isPrivateWindow = true
        #expect(draft.chosenLaunchAction == Self.privateChrome)
        // The profile name isn't used: an empty or refused one doesn't keep Done off.
        draft.profileName = "-P"
        #expect(draft.isProfileNameAccepted && draft.canFinish)
        #expect(draft.chosenLaunchAction == Self.privateChrome)
        #expect(draft.launchActionAwaitingConfirmation == Self.privateChrome)
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "not before it's confirmed")
        #expect(!store.saveItemEdits(of: draft, endingWith: .dismissed, ofItem: item.id, inGroup: id))

        draft.confirmLaunchAction(Self.privateChrome)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.privateChrome))
        #expect(draft.launchActionToSave(endingWith: .cancel) == nil)
        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id))
        let saved = store.group(withID: id)!.apps[0]
        #expect(saved.launchActionSetting == .enabled(Self.privateChrome))
        #expect(approvals.check(saved) == .approved)
    }

    @Test func aConfirmationCountsOnlyForThePrivateWindowChosen() {
        var draft = ItemDetailsDraft(F.website(nil), installedBrowsers: Set(BrowserFamily.allCases))
        draft.setBrowserProfileOn(true)
        draft.profileName = "Work"
        draft.confirmLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
        draft.isPrivateWindow = true
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "the profile was confirmed, not the private window")
        #expect(draft.launchActionAwaitingConfirmation == Self.privateChrome)
        draft.confirmLaunchAction(.browserPrivate(browser: .firefox))
        #expect(draft.confirmedLaunchAction == .browserProfile(browser: .chrome, profileName: "Work"), "another action isn't taken")
    }

    @Test func anItemsPrivateWindowIsShownAndCanBeTurnedBackIntoAProfile() {
        var draft = ItemDetailsDraft(P.website(.firefox), installedBrowsers: [.firefox])
        #expect(draft.browser == .firefox && draft.isPrivateWindow && draft.profileName.isEmpty)
        #expect(draft.chosenLaunchAction == .browserPrivate(browser: .firefox))
        #expect(draft.launchActionAwaitingConfirmation == nil && !draft.hasChanges)

        draft.isPrivateWindow = false
        #expect(!draft.isProfileNameAccepted && !draft.canFinish, "a profile needs its name again")
        draft.profileName = "default-release"
        #expect(draft.launchActionAwaitingConfirmation == .browserProfile(browser: .firefox, profileName: "default-release"))

        var off = ItemDetailsDraft(P.website(.firefox), installedBrowsers: [.firefox])
        off.setBrowserProfileOn(false)
        #expect(off.launchActionToSave(endingWith: .done) == .remove)
    }

    @Test func anImportedPrivateWindowIsTurnedOnOnlyOnceConfirmed() {
        var item = F.website(nil)
        item.launchActionSetting = .needsReview(.imported(Self.privateChrome))
        var draft = ItemDetailsDraft(item, installedBrowsers: [.chrome])
        #expect(draft.launchActionNeedsReview && draft.isPrivateWindow)
        #expect(draft.launchActionToSave(endingWith: .done) == nil, "Done alone keeps it under review")
        #expect(draft.launchActionToTurnOn == Self.privateChrome)
        draft.confirmLaunchAction(Self.privateChrome)
        #expect(draft.launchActionToSave(endingWith: .done) == .enable(Self.privateChrome))
    }

    @Test func theRowShowsTheBrowserAndPrivateWindow() throws {
        var asked: [String] = []
        let caption = try #require(LaunchActionCaption(item: P.website()) { asked.append($0); return false })
        #expect(caption.text == "Chrome · private window")
        #expect(caption.note == nil && !caption.needsReview)
        #expect(asked == ["com.google.Chrome"])

        let running = try #require(LaunchActionCaption(item: P.website(.edge)) { $0 == "com.microsoft.edgemac" })
        #expect(running.text == "Edge · private window")
        #expect(running.note == "Edge is running: the item opens only after you quit it.")

        var imported = F.website(nil)
        imported.launchActionSetting = .needsReview(.imported(Self.privateChrome))
        let review = try #require(LaunchActionCaption(item: imported) { _ in true })
        #expect(review.needsReview && review.note == nil)
    }

    @Test func theConfirmationNamesTheBrowserThePrivateWindowAndTheFullAddress() throws {
        let url = try #require(URL(string: "https://mail.example.com/inbox?folder=work#top"))
        var item = F.website(nil, url: url)
        item.details = ItemDetails(alias: "Mail")
        let summary = try #require(LaunchActionSummary(.browserPrivate(browser: .firefox), for: item))
        #expect(summary.action == .browserPrivate(browser: .firefox))
        #expect(summary.browser == .firefox && summary.profileName == nil)
        #expect(summary.title == "Open “Mail” in a private Firefox window?")
        #expect(summary.details == "https://mail.example.com/inbox?folder=work#top\nFirefox (org.mozilla.firefox)")

        let profile = try #require(LaunchActionSummary(.browserProfile(browser: .chrome, profileName: "Work"), for: F.website(nil)))
        #expect(profile.title == "Open “GitHub” in Chrome with the profile “Work”?")
        #expect(LaunchActionSummary(Self.privateChrome, for: AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")) == nil)
    }

    @Test func theActionSaysWhatItIs() {
        #expect(Self.privateChrome.isPrivateWindow && Self.privateChrome.browser == .chrome && Self.privateChrome.profileName == nil)
        let profile = LaunchAction.browserProfile(browser: .brave, profileName: "Default")
        #expect(!profile.isPrivateWindow && profile.profileName == "Default")
    }

    /// What the editor saves is what opens: after Turn On the launcher starts the browser with the
    /// private-window arguments.
    @Test func whatTheEditorSavesIsWhatOpens() async throws {
        let approvals = LaunchActionApprovalStore.inMemory()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero, approvals: approvals)
        let item = F.website(nil)
        let id = store.addGroup(named: "Work").id
        store.addItems([item], toGroup: id)
        var draft = ItemDetailsDraft(item, installedBrowsers: [.chrome])
        draft.setBrowserProfileOn(true)
        draft.isPrivateWindow = true
        let action = try #require(draft.launchActionAwaitingConfirmation)
        draft.confirmLaunchAction(action)
        store.saveItemEdits(of: draft, endingWith: .done, ofItem: item.id, inGroup: id)
        let saved = store.group(withID: id)!.apps[0]
        let workspace = LaunchActionFakeWorkspace()

        let report = await GroupLauncher(workspace: workspace, approvals: approvals).open(saved, inGroup: store.group(withID: id)!, source: .userAction)

        #expect(report.entries == [LaunchReport.Entry(app: saved, outcome: .launched)])
        #expect(workspace.starts.map(\.arguments) == [["--incognito", "https://github.com/cybokron"]])
        #expect(workspace.starts.map(\.urls) == [[]])
    }
}
