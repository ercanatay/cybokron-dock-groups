import AppKit
import Foundation
import Testing
@testable import DockGroupsCore

// Launch actions, slice 3, the launcher part (docs/design/launch-action-runner-slice.md): the
// runner starts a plan's browser only when it isn't running, and the launcher opens an item with a
// launch action only through the runner, only for the user's own click. Nothing here starts a real
// app: every workspace is a fake.

/// Records what was asked of it; installs the given browsers at `/Applications/<id>.app`. Starting a
/// browser is recorded with its configuration; nothing runs.
@MainActor
final class LaunchActionFakeWorkspace: ApplicationWorkspace, LaunchActionWorkspace {
    struct Start: Equatable {
        let application: URL
        let urls: [URL]
        let arguments: [String]
        let environment: [String: String]
        let activates: Bool
        let createsNewApplicationInstance: Bool
    }

    struct StartError: Error {}

    /// Bundle identifiers of the installed apps (browsers and plain apps alike).
    var installed: Set<String>
    /// Bundle identifiers of the running apps, compared ignoring case.
    var running: Set<String>
    /// The bundle identifier each installed location reports, when it isn't the one asked for.
    var bundleIdentifiers: [URL: String] = [:]
    /// Where each app is said to be, when it isn't `/Applications/<id>.app`.
    var locations: [String: URL] = [:]
    var failsToStart = false

    private(set) var starts: [Start] = []
    private(set) var runningQueries: [String] = []
    private(set) var websiteRequests: [[URL]] = []
    private(set) var openedWith: [(app: URL, urls: [URL])] = []
    private(set) var launched: [URL] = []
    private(set) var activated: [String] = []
    private(set) var fileRequests: [[URL]] = []

    init(installed: Set<String> = ["com.google.Chrome", "org.mozilla.firefox"], running: Set<String> = []) {
        self.installed = installed
        self.running = running
    }

    /// Whether anything at all was opened, started or brought to the front.
    var openedAnything: Bool {
        !starts.isEmpty || !websiteRequests.isEmpty || !openedWith.isEmpty || !launched.isEmpty || !activated.isEmpty || !fileRequests.isEmpty
    }

    static func location(of identifier: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(identifier).app")
    }

    // LaunchActionWorkspace

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        runningQueries.append(bundleIdentifier)
        return running.contains { $0.lowercased() == bundleIdentifier.lowercased() }
    }

    func applicationLocation(bundleIdentifier: String) -> URL? {
        guard installed.contains(where: { $0.lowercased() == bundleIdentifier.lowercased() }) else { return nil }
        return locations[bundleIdentifier] ?? Self.location(of: bundleIdentifier)
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        bundleIdentifiers[url] ?? url.deletingPathExtension().lastPathComponent
    }

    func startApplication(at applicationURL: URL, opening urls: [URL], configuration: NSWorkspace.OpenConfiguration) async throws {
        starts.append(Start(
            application: applicationURL,
            urls: urls,
            arguments: configuration.arguments,
            environment: configuration.environment,
            activates: configuration.activates,
            createsNewApplicationInstance: configuration.createsNewApplicationInstance
        ))
        if failsToStart { throw StartError() }
    }

    // ApplicationWorkspace

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard running.contains(bundleIdentifier) else { return false }
        activated.append(bundleIdentifier)
        return true
    }

    func locateApplication(_ app: AppReference) -> URL? {
        installed.contains(app.bundleIdentifier) ? Self.location(of: app.bundleIdentifier) : nil
    }

    func launchApplication(at url: URL) async throws {
        launched.append(url)
    }

    func openWebsites(_ urls: [URL]) async throws {
        websiteRequests.append(urls)
    }

    func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        fileRequests.append(urls)
        return [:]
    }

    func revealFileItems(_ urls: [URL]) {}

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        openedWith.append((applicationURL, urls))
    }
}

/// A workspace that can't start anything with a launch action (it doesn't say how).
@MainActor
private final class PlainWorkspace: ApplicationWorkspace {
    private(set) var websiteRequests: [[URL]] = []
    private(set) var openedWith: [URL] = []
    private(set) var launched: [URL] = []

    func activateRunningApplication(bundleIdentifier: String) -> Bool { false }
    func locateApplication(_ app: AppReference) -> URL? { LaunchActionFakeWorkspace.location(of: app.bundleIdentifier) }
    func launchApplication(at url: URL) async throws { launched.append(url) }
    func openWebsites(_ urls: [URL]) async throws { websiteRequests.append(urls) }
    func openFileItems(_ urls: [URL]) async -> [URL: any Error] { [:] }
    func revealFileItems(_ urls: [URL]) {}
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws { openedWith.append(applicationURL) }
}

enum LaunchActionFixtures {
    static let url = URL(string: "https://github.com/cybokron")!
    static let notOpened = Localization.string("core.launch.notOpened", "The app wasn't opened.")

    /// A website item for `url` with a browser-profile action (none when `browser` is `nil`).
    static func website(_ browser: BrowserFamily? = .chrome, profile: String = "Work", url: URL = url, name: String = "GitHub") -> GroupItem {
        var item = AppReference(websiteURL: url, name: name)
        if let browser {
            item.setLaunchAction(.browserProfile(browser: browser, profileName: profile))
        }
        return item
    }

    static func plan(_ browser: BrowserFamily = .chrome, profile: String = "Work") throws -> LaunchActionArgumentPlan {
        try LaunchActionArgumentPlan.make(
            setting: .enabled(.browserProfile(browser: browser, profileName: profile)),
            itemKind: .website,
            url: url,
            browserBundleIdentifier: browser.bundleIdentifiers[0],
            isInstalled: { _ in true }
        ).get()
    }

    /// Every source other than the user's own click (in the app or a standalone group's app).
    static let unattendedSources = LaunchSource.allCases.filter { !$0.isUserPresent }

    /// Approvals in memory of exactly these items' actions, as turning them on in the group window
    /// records them (launch-action-approvals.md). An action runs only with its approval, so every
    /// test that expects one to reach the runner gives the launcher these.
    @MainActor
    static func approving(_ items: GroupItem...) -> LaunchActionApprovalStore {
        let approvals = LaunchActionApprovalStore.inMemory()
        for item in items {
            try? approvals.approve(item)
        }
        return approvals
    }
}

// MARK: - Runner

@Suite("Launch actions: runner")
@MainActor
struct LaunchActionRunnerTests {
    typealias F = LaunchActionFixtures

    @Test(arguments: [
        (BrowserFamily.chrome, ["--profile-directory=Work"]),
        (BrowserFamily.firefox, ["-P", "Work"]),
    ])
    func aBrowserThatIsntRunningIsStartedWithThePlan(browser: BrowserFamily, arguments: [String]) async throws {
        let workspace = LaunchActionFakeWorkspace()
        let plan = try F.plan(browser)

        let outcome = await LaunchActionRunner(workspace: workspace).run(plan)

        #expect(outcome == .launched)
        #expect(workspace.starts == [LaunchActionFakeWorkspace.Start(
            application: LaunchActionFakeWorkspace.location(of: browser.bundleIdentifiers[0]),
            urls: [F.url],
            arguments: arguments,
            environment: [:],
            activates: true,
            createsNewApplicationInstance: false
        )])
        #expect(workspace.runningQueries == [browser.bundleIdentifiers[0]])
    }

    @Test(arguments: ["com.google.Chrome", "com.google.chrome", "COM.GOOGLE.CHROME"])
    func aRunningBrowserIsRefusedAndNothingIsSentToIt(running: String) async throws {
        let workspace = LaunchActionFakeWorkspace(running: [running])

        let outcome = await LaunchActionRunner(workspace: workspace).run(try F.plan())

        #expect(outcome == .refused(.browserAlreadyRunning))
        #expect(workspace.starts.isEmpty)
        #expect(!workspace.openedAnything)
    }

    @Test func aBrowserThatIsntInstalledIsRefused() async throws {
        let workspace = LaunchActionFakeWorkspace(installed: [])

        let outcome = await LaunchActionRunner(workspace: workspace).run(try F.plan())

        #expect(outcome == .refused(.browserNotInstalled))
        #expect(!workspace.openedAnything)
        #expect(workspace.runningQueries.isEmpty)
    }

    @Test func aLocationThatIsntTheBrowsersBundleIsRefused() async throws {
        let notABundle = LaunchActionFakeWorkspace()
        notABundle.locations["com.google.Chrome"] = URL(fileURLWithPath: "/Users/me/chrome.command")
        let otherApp = LaunchActionFakeWorkspace()
        otherApp.bundleIdentifiers[LaunchActionFakeWorkspace.location(of: "com.google.Chrome")] = "com.example.impostor"
        let noIdentifier = LaunchActionFakeWorkspace()
        noIdentifier.locations["com.google.Chrome"] = URL(string: "https://example.com/Chrome.app")!

        for workspace in [notABundle, otherApp, noIdentifier] {
            #expect(await LaunchActionRunner(workspace: workspace).run(try F.plan()) == .refused(.browserNotInstalled))
            #expect(!workspace.openedAnything)
        }
    }

    @Test func aFailedStartIsReported() async throws {
        let workspace = LaunchActionFakeWorkspace()
        workspace.failsToStart = true

        #expect(await LaunchActionRunner(workspace: workspace).run(try F.plan()) == .refused(.launchFailed))
        #expect(workspace.starts.count == 1)
    }

    @Test func theConfigurationHasThePlansArgumentsAndAnEmptyEnvironment() throws {
        let configuration = LaunchActionRunner.configuration(for: try F.plan(.firefox, profile: "Profile 1"))
        #expect(configuration.arguments == ["-P", "Profile 1"])
        #expect(configuration.environment.isEmpty)
        #expect(configuration.activates)
        #expect(!configuration.createsNewApplicationInstance)
    }

    @Test func refusalCodesAreFixed() {
        #expect(LaunchActionRunRefusal.allCases.map(\.rawValue) == ["browserAlreadyRunning", "browserNotInstalled", "launchFailed"])
        #expect(LaunchActionItemRefusal.unattendedSource(.link).code == "source.link")
        #expect(LaunchActionItemRefusal.noRunner.code == "noRunner")
        #expect(LaunchActionItemRefusal.plan(.actionDisabled).code == "plan.actionDisabled")
        #expect(LaunchActionItemRefusal.run(.browserAlreadyRunning).code == "run.browserAlreadyRunning")
    }
}

// MARK: - Launcher

@Suite("Launch actions: launcher")
@MainActor
struct LaunchActionLauncherTests {
    typealias F = LaunchActionFixtures

    private func group(_ items: [GroupItem]) -> DockGroup {
        DockGroup(name: "Work", apps: items)
    }

    @Test func clickingAnItemStartsItsBrowserWithTheAction() async {
        let workspace = LaunchActionFakeWorkspace()
        let item = F.website()

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: group([item]), source: .userAction)

        #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .launched)])
        #expect(workspace.starts.map(\.arguments) == [["--profile-directory=Work"]])
        #expect(workspace.starts.map(\.environment) == [[:]])
        #expect(workspace.starts.map(\.urls) == [[F.url]])
        #expect(workspace.starts.map(\.application) == [LaunchActionFakeWorkspace.location(of: "com.google.Chrome")])
        // Only through the runner: never in the default browser, never with Open With.
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
    }

    @Test func openAllFromTheAppStartsTheBrowserToo() async {
        let workspace = LaunchActionFakeWorkspace(installed: ["org.mozilla.firefox", "com.example.app"])
        let app = AppReference(bundleIdentifier: "com.example.app", name: "App")
        let plain = AppReference(websiteURL: URL(string: "https://example.com")!)
        let item = F.website(.firefox, profile: "default-release")

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).openAll(group([item, app, plain]), source: .userAction)

        #expect(report.entries.map(\.app) == [item, app, plain])
        #expect(report.entries.map(\.outcome) == [.launched, .launched, .launched])
        #expect(workspace.starts.map(\.arguments) == [["-P", "default-release"]])
        #expect(workspace.starts.map(\.application) == [LaunchActionFakeWorkspace.location(of: "org.mozilla.firefox")])
        // The plain website still opens in the default browser, alone.
        #expect(workspace.websiteRequests == [[URL(string: "https://example.com")!]])
    }

    @Test func aRunningBrowserMeansTheItemIsntOpenedAtAll() async {
        let workspace = LaunchActionFakeWorkspace(running: ["com.google.Chrome"])
        let item = F.website()

        for report in [
            await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: group([item]), source: .userAction),
            await GroupLauncher(workspace: workspace, approvals: F.approving(item)).openAll(group([item]), source: .userAction),
        ] {
            #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .failed(reason: F.notOpened), launchActionRefusal: .run(.browserAlreadyRunning))])
        }
        #expect(!workspace.openedAnything, "no new tab in the running browser, no default browser")
    }

    @Test func aBrowserThatIsntInstalledIsNotFound() async {
        let workspace = LaunchActionFakeWorkspace(installed: [])
        let item = F.website()

        let report = await GroupLauncher(workspace: workspace).open(item, inGroup: group([item]), source: .userAction)

        #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .notFound, launchActionRefusal: .plan(.browserNotInstalled))])
        #expect(!workspace.openedAnything, "no other browser is tried")
    }

    @Test func aFailedStartIsReportedAndNothingElseOpens() async {
        let workspace = LaunchActionFakeWorkspace()
        workspace.failsToStart = true
        let item = F.website()

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: group([item]), source: .userAction)

        #expect(report.entries.first?.launchActionRefusal == .run(.launchFailed))
        #expect(report.problems.map(\.app) == [item])
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
    }

    nonisolated static func needingReview() -> [(GroupItem, LaunchActionItemRefusal)] {
        var imported = AppReference(websiteURL: LaunchActionFixtures.url, name: "Imported")
        imported.launchActionSetting = .needsReview(.imported(.browserProfile(browser: .chrome, profileName: "Work")))
        var invalid = AppReference(websiteURL: LaunchActionFixtures.url, name: "Invalid")
        invalid.launchActionSetting = .needsReview(.invalid(.unknownTemplate))
        let badName = LaunchActionFixtures.website(profile: "--load-extension=/tmp/x")
        var forged = AppReference(websiteURL: LaunchActionFixtures.url, name: "Forged")
        forged.launchActionSetting = .enabled(.browserProfile(browser: .chrome, profileName: "--remote-debugging-port=9222"))
        var app = AppReference(bundleIdentifier: "com.example.app", name: "App")
        app.setLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
        var folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true), kind: .folder)
        folder.launchActionSetting = .enabled(.browserProfile(browser: .chrome, profileName: "Work"))
        let wrongBrowser = LaunchActionFixtures.website().launching(with: ItemOpener(bundleIdentifier: "org.mozilla.firefox", name: "Firefox"))
        let safari = LaunchActionFixtures.website().launching(with: ItemOpener(bundleIdentifier: "com.apple.Safari", name: "Safari"))
        return [
            (imported, .plan(.actionDisabled)),
            (invalid, .plan(.actionNeedsReview)),
            (badName, .plan(.actionNeedsReview)),
            (forged, .plan(.actionNeedsReview)),
            (app, .plan(.itemKindMismatch)),
            (folder, .plan(.itemKindMismatch)),
            (wrongBrowser, .plan(.unsupportedBrowser)),
            (safari, .plan(.unsupportedBrowser)),
        ]
    }

    @Test(arguments: needingReview())
    func anActionThatCantBeUsedKeepsTheItemClosed(item: GroupItem, refusal: LaunchActionItemRefusal) async {
        let workspace = LaunchActionFakeWorkspace(installed: ["com.google.Chrome", "org.mozilla.firefox", "com.apple.Safari", "com.example.app"])

        for report in [
            await GroupLauncher(workspace: workspace, locator: ScriptedLocator()).open(item, inGroup: group([item]), source: .userAction),
            await GroupLauncher(workspace: workspace, locator: ScriptedLocator()).openAll(group([item]), source: .userAction),
        ] {
            #expect(report.entries.map(\.launchActionRefusal) == [refusal])
            #expect(report.entries.map(\.outcome) == [.failed(reason: F.notOpened)])
        }
        // Not plainly, not with another app (D5).
        #expect(!workspace.openedAnything)
    }

    @Test(arguments: LaunchActionFixtures.unattendedSources)
    func unattendedSourcesDontOpenAnItemWithAnAction(source: LaunchSource) async {
        let workspace = LaunchActionFakeWorkspace(installed: ["com.google.Chrome", "com.example.app"])
        let item = F.website()
        let app = AppReference(bundleIdentifier: "com.example.app", name: "App")

        let one = await GroupLauncher(workspace: workspace).open(item, inGroup: group([item]), source: source)
        let all = await GroupLauncher(workspace: workspace).openAll(group([item, app]), source: source)

        #expect(one.entries == [LaunchReport.Entry(app: item, outcome: .failed(reason: F.notOpened), launchActionRefusal: .unattendedSource(source))])
        #expect(all.entries.map(\.launchActionRefusal) == [.unattendedSource(source), nil])
        #expect(all.entries.map(\.outcome) == [.failed(reason: F.notOpened), .launched])
        #expect(workspace.starts.isEmpty && workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty)
        #expect(workspace.launched == [LaunchActionFakeWorkspace.location(of: "com.example.app")], "items without an action open as before")
        #expect(workspace.runningQueries.isEmpty)
    }

    /// The user's click in the app and in a standalone group's own app (D11: the agent runs an
    /// action with the same checks and approval as the app; launch-action-approvals.md).
    @Test func onlyTheUsersOwnClicksAreUserPresent() {
        #expect(LaunchSource.allCases.filter(\.isUserPresent) == [.userAction, .standaloneAgent])
        #expect(LaunchSource.allCases.count == 8)
        let mapped = TransitionTrigger.allCases.map { LaunchSource($0) }
        #expect(mapped == [.userAction, .link, .intent, .focus, .keyboardShortcut, .trigger])
    }

    @Test func aWorkspaceThatCantRunActionsOpensNothing() async {
        let workspace = PlainWorkspace()
        let item = F.website()

        let report = await GroupLauncher(workspace: workspace).open(item, inGroup: group([item]), source: .userAction)

        #expect(report.entries.map(\.launchActionRefusal) == [.noRunner])
        #expect(workspace.websiteRequests.isEmpty && workspace.openedWith.isEmpty && workspace.launched.isEmpty)
    }

    @Test func theReportAndRefusalHoldNothingFromTheItem() async {
        let workspace = LaunchActionFakeWorkspace(running: ["com.google.Chrome"])
        let item = F.website(profile: "SecretProfile", url: URL(string: "https://token.example.org/secret")!)

        let report = await GroupLauncher(workspace: workspace, approvals: F.approving(item)).open(item, inGroup: group([item]), source: .userAction)
        let entry = report.entries.first
        #expect(entry?.launchActionRefusal == .run(.browserAlreadyRunning))
        let texts = [String(describing: entry?.outcome as Any), entry?.launchActionRefusal?.code ?? ""]
        for text in texts {
            #expect(!text.contains("SecretProfile") && !text.contains("token.example.org") && !text.contains("secret"))
        }
    }

    // MARK: Without actions: as before

    @Test(arguments: LaunchSource.allCases)
    func itemsWithoutAnActionOpenAsBeforeFromEverySource(source: LaunchSource) async {
        let reference = LaunchActionFakeWorkspace(installed: ["com.example.app"], running: ["com.example.running"])
        let workspace = LaunchActionFakeWorkspace(installed: ["com.example.app"], running: ["com.example.running"])
        let items = [
            AppReference(bundleIdentifier: "com.example.app", name: "App"),
            AppReference(bundleIdentifier: "com.example.running", name: "Running"),
            AppReference(bundleIdentifier: "com.example.missing", name: "Missing"),
            F.website(nil),
            F.website(nil, url: URL(string: "https://example.com")!, name: "Example")
                .launching(with: ItemOpener(bundleIdentifier: "org.mozilla.firefox", name: "Firefox")),
        ]

        let expected = await GroupLauncher(workspace: reference, catalog: FakeCatalog()).openAll(group(items))
        let report = await GroupLauncher(workspace: workspace, catalog: FakeCatalog()).openAll(group(items), source: source)
        let one = await GroupLauncher(workspace: workspace, catalog: FakeCatalog()).open(items[3], inGroup: group(items), source: source)

        #expect(report == expected)
        #expect(report.entries.allSatisfy { $0.launchActionRefusal == nil })
        #expect(one.entries.map(\.outcome) == [.launched])
        #expect(workspace.starts.isEmpty && workspace.runningQueries.isEmpty)
        #expect(workspace.activated == reference.activated && workspace.launched == reference.launched)
        #expect(workspace.websiteRequests.first == reference.websiteRequests.first)
        #expect(workspace.openedWith.map(\.app) == reference.openedWith.map(\.app))
    }
}

// MARK: - Start and delays

@Suite("Launch actions: Start and delayed items")
@MainActor
struct LaunchActionSwitchingTests {
    typealias F = LaunchActionFixtures

    @Test(arguments: TransitionTrigger.allCases)
    func startOpensTheItemOnlyForTheUsersClick(trigger: TransitionTrigger) async throws {
        let group = DockGroup(name: "Web", apps: [F.website()])
        let rig = SwitchingRig(groups: [group])
        let id = try #require(rig.store.groups.first?.id)
        #expect(rig.store.groups.first?.apps.first?.launchActionSetting != nil)

        let report = try await rig.switcher.start(id, trigger: trigger)

        if trigger == .userAction {
            #expect(report.launch?.entries.map(\.outcome) == [.launched])
            #expect(rig.log.events.contains("start:com.google.Chrome"))
        } else {
            #expect(report.launch?.entries.map(\.launchActionRefusal) == [.unattendedSource(LaunchSource(trigger))])
            #expect(!rig.log.events.contains { $0.hasPrefix("start:") })
        }
        #expect(!rig.log.events.contains("websites"))
    }

    private final class Reports {
        var reports: [LaunchReport] = []
    }

    @MainActor
    private struct DelayRig {
        let workspace = LaunchActionFakeWorkspace()
        let sleeper = FakeSleeper()
        let store = GroupStore(persistence: MemoryGroupPersistence(), saveDelay: .zero)
        let reports = Reports()
        let launcher: GroupLauncher

        init() {
            let store = self.store
            let pending = DelayedLaunches(sleeper: sleeper) { store.group(withID: $0) }
            let reports = self.reports
            pending.onFinished = { reports.reports.append($0) }
            // Both profiles the tests use are approved, so only the checks under test refuse.
            let approvals = LaunchActionApprovalStore.inMemory()
            try? approvals.approve(F.website().launching(after: 5))
            try? approvals.approve(F.website(profile: "Personal").launching(after: 5))
            launcher = GroupLauncher(workspace: workspace, locator: ScriptedLocator(), catalog: FakeCatalog(), pendingLaunches: pending, approvals: approvals)
        }

        func add(_ item: GroupItem) -> DockGroup {
            let group = store.addGroup(named: "Work")
            store.updateGroup(group.id) { $0.apps = [item] }
            return store.group(withID: group.id)!
        }
    }

    @Test func aDelayedItemKeepsItsSource() async throws {
        for source in [LaunchSource.userAction, .link] {
            let rig = DelayRig()
            let group = rig.add(F.website().launching(after: 5))
            #expect(group.apps.first?.launchActionSetting != nil)

            let report = await rig.launcher.openAll(group, source: source)
            #expect(report.entries.map(\.outcome) == [.scheduled(seconds: 5)])
            await settle { rig.sleeper.sleepingCount == 1 }
            rig.sleeper.wakeAll()
            await settle { !rig.reports.reports.isEmpty }

            let entries = try #require(rig.reports.reports.first).entries
            if source == .userAction {
                #expect(entries.map(\.outcome) == [.launched])
                #expect(rig.workspace.starts.map(\.arguments) == [["--profile-directory=Work"]])
            } else {
                #expect(entries.map(\.launchActionRefusal) == [.unattendedSource(.link)])
                #expect(!rig.workspace.openedAnything)
            }
        }
    }

    @Test func aDelayedItemWhoseActionChangedMeanwhileIsntOpened() async {
        let rig = DelayRig()
        let group = rig.add(F.website().launching(after: 5))

        _ = await rig.launcher.openAll(group, source: .userAction)
        await settle { rig.sleeper.sleepingCount == 1 }
        rig.store.updateGroup(group.id) { $0.apps[0].setLaunchAction(.browserProfile(browser: .chrome, profileName: "Personal")) }
        rig.sleeper.wakeAll()
        await settle { false }

        #expect(!rig.workspace.openedAnything, "neither the old nor the new profile")
    }
}
