import AppKit
import Foundation
import Testing
@testable import DockGroupsCore

// The "Run a Shortcut" template, slice 3 (docs/design/launch-action-shortcut.md §3.3, §3.4, §6):
// the address, its strict encoding and read-back, the gates in their order, the two-second rule,
// the screen lock, the failure path, what is logged and reported, and which files may hand anything
// to the system. No shortcut is ever run: every workspace is a fake, no `NSWorkspace`, no
// `shortcuts` tool.

/// Records what was asked of it; Shortcuts.app is at `/System/Applications/Shortcuts.app` unless
/// told otherwise. Opening an address is recorded with its configuration; nothing runs.
@MainActor
final class ShortcutFakeWorkspace: ApplicationWorkspace, ShortcutOpening {
    struct Open: Equatable {
        let url: URL
        let application: URL
        let activates: Bool
        let addsToRecentItems: Bool
        let arguments: [String]
        let environment: [String: String]
        let createsNewApplicationInstance: Bool
    }

    /// An error whose text quotes the address, as a system error might.
    struct OpenError: LocalizedError {
        let url: URL
        var errorDescription: String? { "Couldn't open \(url.absoluteString)" }
    }

    static let systemLocation = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")

    /// Where LaunchServices says Shortcuts is; `nil`: not installed.
    var location: URL? = systemLocation
    /// What the bundle at `location` says it is.
    var identifier: String? = "com.apple.shortcuts"
    var failsToOpen = false

    private(set) var opens: [Open] = []
    private(set) var locationQueries: [String] = []
    private(set) var launched: [URL] = []
    private(set) var activated: [String] = []
    private(set) var openedWith: [URL] = []
    private(set) var websiteRequests: [[URL]] = []
    private(set) var fileRequests: [[URL]] = []

    var openedAnything: Bool {
        !opens.isEmpty || !launched.isEmpty || !activated.isEmpty || !openedWith.isEmpty || !websiteRequests.isEmpty || !fileRequests.isEmpty
    }

    // ShortcutOpening

    func applicationLocation(bundleIdentifier: String) -> URL? {
        locationQueries.append(bundleIdentifier)
        return bundleIdentifier == "com.apple.shortcuts" ? location : nil
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? { identifier }

    func openShortcutURL(_ url: URL, withApplicationAt applicationURL: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        opens.append(Open(
            url: url, application: applicationURL, activates: configuration.activates,
            addsToRecentItems: configuration.addsToRecentItems, arguments: configuration.arguments,
            environment: configuration.environment, createsNewApplicationInstance: configuration.createsNewApplicationInstance
        ))
        if failsToOpen { throw OpenError(url: url) }
    }

    // ApplicationWorkspace: an item without an action still opens through these.

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        activated.append(bundleIdentifier)
        return false
    }

    func locateApplication(_ app: AppReference) -> URL? { URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app") }
    func launchApplication(at url: URL) async throws { launched.append(url) }
    func openWebsites(_ urls: [URL]) async throws { websiteRequests.append(urls) }
    func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        fileRequests.append(urls)
        return [:]
    }
    func revealFileItems(_ urls: [URL]) {}
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws { openedWith.append(applicationURL) }
}

/// A screen lock reading that counts how often it was read.
@MainActor
final class FakeScreenLock {
    var reading: Bool?
    private(set) var reads = 0

    init(_ reading: Bool?) { self.reading = reading }

    func read() -> Bool? {
        reads += 1
        return reading
    }
}

@Suite("Launch actions: running a shortcut")
@MainActor
struct ShortcutLaunchRunnerTests {
    typealias F = LaunchActionFixtures

    nonisolated static let shortcuts = AppReference(bundleIdentifier: "com.apple.shortcuts", name: "Shortcuts")

    nonisolated static func item(_ name: String = "Work Setup") -> GroupItem {
        var item = shortcuts
        item.setLaunchAction(.shortcut(name: name))
        return item
    }

    /// A launcher on `workspace` that approves `approved` and reads `lock`, its clock at `time`.
    static func launcher(
        _ workspace: ApplicationWorkspace, approving approved: [GroupItem], lock: FakeScreenLock, time: TimeInterval = 1_000
    ) -> GroupLauncher {
        let approvals = LaunchActionApprovalStore.inMemory()
        for item in approved { try? approvals.approve(item) }
        let launcher = GroupLauncher(workspace: workspace, approvals: approvals, screenLock: { lock.read() })
        launcher.shortcutRuns.now = { time }
        return launcher
    }

    static func open(_ item: GroupItem, with launcher: GroupLauncher, source: LaunchSource = .userAction) async -> LaunchReport.Entry {
        await launcher.open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: source).entries[0]
    }

    // MARK: - The address

    /// Names and their exact encoding: every byte outside `A–Z a–z 0–9 - . _ ~` is `%XX`.
    nonisolated static let encodings: [(String, String)] = [
        ("Work Setup", "Work%20Setup"),
        ("A&input=clipboard", "A%26input%3Dclipboard"),
        ("a+b", "a%2Bb"),
        ("x#y", "x%23y"),
        ("q?r", "q%3Fr"),
        ("a=b", "a%3Db"),
        ("50%", "50%25"),
        ("Work: start;now", "Work%3A%20start%3Bnow"),
        ("🚀 Launch", "%F0%9F%9A%80%20Launch"),
        ("Çalışma Şablonu", "%C3%87al%C4%B1%C5%9Fma%20%C5%9Eablonu"),
        ("إعداد العمل", "%D8%A5%D8%B9%D8%AF%D8%A7%D8%AF%20%D8%A7%D9%84%D8%B9%D9%85%D9%84"),
        ("仕事の準備", "%E4%BB%95%E4%BA%8B%E3%81%AE%E6%BA%96%E5%82%99"),
        ("Café", "Caf%C3%A9"),
        ("~._-x", "~._-x"),
    ]

    @Test(arguments: encodings)
    func theAddressHasOnlyTheStrictlyEncodedName(name: String, encoded: String) throws {
        #expect(ShortcutRunURL.percentEncoded(name) == encoded)
        let url = try #require(ShortcutRunURL.make(name: name))
        #expect(url.absoluteString == "shortcuts://run-shortcut?name=" + encoded)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "shortcuts" && components.host == "run-shortcut" && components.path.isEmpty)
        #expect(components.queryItems?.map(\.name) == ["name"], "one query item, nothing else")
        #expect(components.queryItems?.first?.value.map { Array($0.unicodeScalars) } == Array(name.unicodeScalars))
        #expect(ShortcutRunURL.isExactly(url, name: name))
        // Only unreserved characters and %XX escapes after `name=`.
        let query = String(url.absoluteString.dropFirst(ShortcutRunURL.prefix.count))
        #expect(query.unicodeScalars.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%".unicodeScalars.contains($0) })
    }

    @Test func aNameTheGrammarRefusesGetsNoAddress() {
        // `../x` is encoded strictly, but a "/" is refused before any address is made.
        #expect(ShortcutRunURL.percentEncoded("../x") == "..%2Fx")
        for name in ["../x", "a/b", "a\\b", "", " lead", "-x", "Wo\u{0}rk", "Work\nSetup", "Caf\u{65}\u{301}", "a\u{200D}b", "\u{202E}x"] {
            #expect(ShortcutRunURL.make(name: name) == nil, "\(name.debugDescription)")
        }
    }

    @Test(arguments: [
        "shortcuts://run-shortcut?name=a&input=clipboard",
        "shortcuts://run-shortcut?name=a&name=b",
        "shortcuts://run-shortcut?name=a#x-success",
        "shortcuts://x-callback-url/run-shortcut?name=a",
        "shortcuts://user@run-shortcut?name=a",
        "shortcuts://user:pass@run-shortcut?name=a",
        "shortcuts://run-shortcut:80?name=a",
        "shortcuts://run-shortcut/x?name=a",
        "shortcuts://run-shortcut?text=a",
        "shortcuts://run-shortcut?name",
        "shortcuts://run-shortcut?name=",
        "shortcuts://run-shortcut",
        "shortcuts:run-shortcut?name=a",
        "SHORTCUTS://run-shortcut?name=a",
        "shortcuts://RUN-SHORTCUT?name=a",
        "https://run-shortcut?name=a",
    ])
    func anAddressOfAnotherShapeIsntReadBack(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(ShortcutRunURL.name(in: url) == nil)
        #expect(!ShortcutRunURL.isExactly(url, name: "a"))
    }

    @Test func theReadBackComparesScalarsAndTheExactText() throws {
        let nfc = "Café"
        let nfd = "Cafe\u{301}"
        #expect(nfc == nfd, "String equality would call them the same")
        let url = try #require(ShortcutRunURL.make(name: nfc))
        #expect(ShortcutRunURL.isExactly(url, name: nfc))
        #expect(!ShortcutRunURL.isExactly(url, name: nfd))
        // The same name read back from a looser encoding isn't accepted: only the strict text is.
        let loose = try #require(URL(string: "shortcuts://run-shortcut?name=a+b"))
        #expect(ShortcutRunURL.name(in: loose) == "a+b")
        #expect(!ShortcutRunURL.isExactly(loose, name: "a+b"))
        let other = try #require(ShortcutRunURL.make(name: "Work Setup"))
        #expect(!ShortcutRunURL.isExactly(other, name: "Work Setup "))
        #expect(!ShortcutRunURL.isExactly(other, name: "Work"))
    }

    // MARK: - Running it

    @Test func anApprovedShortcutIsHandedToShortcutsInTheBackground() async {
        let item = Self.item("A&input=clipboard")
        let workspace = ShortcutFakeWorkspace()
        let lock = FakeScreenLock(false)
        let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: lock))
        #expect(entry == LaunchReport.Entry(app: item, outcome: .launched))
        #expect(workspace.opens == [ShortcutFakeWorkspace.Open(
            url: URL(string: "shortcuts://run-shortcut?name=A%26input%3Dclipboard")!,
            application: ShortcutFakeWorkspace.systemLocation,
            activates: false, addsToRecentItems: false, arguments: [], environment: [:],
            createsNewApplicationInstance: false
        )])
        #expect(workspace.locationQueries == ["com.apple.shortcuts"])
        #expect(workspace.launched.isEmpty && workspace.activated.isEmpty && workspace.openedWith.isEmpty, "Shortcuts isn't started or brought forward otherwise")
        #expect(lock.reads == 1)
    }

    @Test func theConfigurationIsFixed() {
        let configuration = ShortcutLaunchRunner.configuration()
        #expect(!configuration.activates)
        #expect(!configuration.addsToRecentItems)
        #expect(configuration.arguments.isEmpty)
        #expect(configuration.environment.isEmpty)
        #expect(!configuration.createsNewApplicationInstance)
    }

    // MARK: - Gate 1: only the user's click in the app

    @Test(arguments: LaunchSource.allCases.filter { $0 != .userAction })
    func everyOtherSourceIsRefusedFirst(source: LaunchSource) async {
        let item = Self.item()
        let workspace = ShortcutFakeWorkspace()
        let lock = FakeScreenLock(false)
        let launcher = Self.launcher(workspace, approving: [item], lock: lock)
        let one = await Self.open(item, with: launcher, source: source)
        let all = await launcher.openAll(DockGroup(name: "Work", apps: [item]), source: source).entries[0]
        for entry in [one, all] {
            #expect(entry.launchActionRefusal == .unattendedSource(source))
            #expect(entry.outcome == LaunchActionItemRefusal.shortcutNotRun)
        }
        #expect(!workspace.openedAnything)
        #expect(lock.reads == 0)
        #expect(workspace.locationQueries.isEmpty)
    }

    @Test func aStandaloneGroupsAppNeverRunsOne() async {
        // Q6: an agent's click is "user present" for a browser action, not for a shortcut.
        #expect(LaunchSource.standaloneAgent.isUserPresent)
        let item = Self.item()
        let workspace = ShortcutFakeWorkspace()
        let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false)), source: .standaloneAgent)
        #expect(entry.launchActionRefusal == .unattendedSource(.standaloneAgent))
        #expect(LaunchActionItemRefusal.unattendedSource(.standaloneAgent).code == "source.standaloneAgent")
        #expect(!workspace.openedAnything)
    }

    // MARK: - Gate 2: the action and the item

    @Test func anActionThatIsntOnIsRefused() async {
        var imported = Self.item()
        imported.launchActionSetting = imported.launchActionSetting?.disabledForImport
        var invalid = Self.shortcuts
        invalid.setLaunchAction(.shortcut(name: "a/b"))
        var browserOnShortcuts = Self.shortcuts
        browserOnShortcuts.setLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
        let cases: [(GroupItem, LaunchActionItemRefusal)] = [
            (imported, .shortcutPlan(.actionDisabled)),
            (invalid, .shortcutPlan(.actionNeedsReview)),
            (browserOnShortcuts, .shortcutPlan(.actionNeedsReview)),
        ]
        for (item, refusal) in cases {
            let workspace = ShortcutFakeWorkspace()
            let lock = FakeScreenLock(false)
            let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: lock))
            #expect(entry.launchActionRefusal == refusal)
            #expect(!workspace.openedAnything && lock.reads == 0)
        }
    }

    @Test func aShortcutOnAnyOtherItemOrANameTheGrammarRefusesIsntRun() async {
        // Set past the model's checks, as a crafted file could not but a careless caller might.
        var mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
        mail.launchActionSetting = .enabled(.shortcut(name: "Work Setup"))
        var website = AppReference(websiteURL: F.url, name: "GitHub")
        website.launchActionSetting = .enabled(.shortcut(name: "Work Setup"))
        var fakeShortcuts = AppReference(bundleIdentifier: "com.example.shortcuts", name: "Shortcuts")
        fakeShortcuts.launchActionSetting = .enabled(.shortcut(name: "Work Setup"))
        var badName = Self.shortcuts
        badName.launchActionSetting = .enabled(.shortcut(name: "Work\u{202E}Setup"))
        var browser = Self.shortcuts
        browser.launchActionSetting = .enabled(.browserPrivate(browser: .chrome))
        let cases: [(GroupItem, LaunchActionItemRefusal)] = [
            (mail, .shortcutPlan(.notShortcutsItem)),
            (website, .shortcutPlan(.notShortcutsItem)),
            (fakeShortcuts, .shortcutPlan(.notShortcutsItem)),
            (badName, .shortcutPlan(.actionNeedsReview)),
            (browser, .shortcutPlan(.notShortcutsItem)),
        ]
        for (item, refusal) in cases {
            #expect(ShortcutLaunchRunner.handles(item))
            let workspace = ShortcutFakeWorkspace()
            let lock = FakeScreenLock(false)
            let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: lock))
            #expect(entry.launchActionRefusal == refusal, "\(item.bundleIdentifier)")
            #expect(!workspace.openedAnything && lock.reads == 0)
        }
    }

    // MARK: - Gate 3: the approval digest

    @Test func withoutTheApprovalOfExactlyThisNameNothingRuns() async {
        let approved = Self.item("Work Setup")
        let renamed = Self.item("Work Setup 2")
        for (item, refusal) in [(renamed, LaunchActionApprovalRefusal.mismatch), (approved, .missing)] {
            let workspace = ShortcutFakeWorkspace()
            let lock = FakeScreenLock(false)
            let launcher = Self.launcher(workspace, approving: refusal == .mismatch ? [approved] : [], lock: lock)
            let entry = await Self.open(item, with: launcher)
            #expect(entry.launchActionRefusal == .approval(refusal))
            #expect(!workspace.openedAnything)
            #expect(lock.reads == 0, "the lock is read only once the approval passed")
        }
        // Without an approval store at all, nothing is approved.
        let workspace = ShortcutFakeWorkspace()
        let entry = await GroupLauncher(workspace: workspace, screenLock: { false })
            .open(approved, inGroup: DockGroup(name: "Work", apps: [approved]), source: .userAction).entries[0]
        #expect(entry.launchActionRefusal == .approval(.missing))
        #expect(!workspace.openedAnything)
    }

    // MARK: - Gate 4: the screen lock

    @Test func aLockedOrUnknownScreenRunsNothing() async {
        let item = Self.item()
        for (reading, refusal) in [(true, ShortcutRunRefusal.screenLocked), (nil, .lockUnknown)] as [(Bool?, ShortcutRunRefusal)] {
            let workspace = ShortcutFakeWorkspace()
            let lock = FakeScreenLock(reading)
            let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: lock))
            #expect(entry.launchActionRefusal == .shortcutRun(refusal))
            #expect(!workspace.openedAnything && workspace.locationQueries.isEmpty)
            #expect(lock.reads == 1)
        }
        // A launcher told nothing about the lock (the standalone group's app) never runs one.
        let workspace = ShortcutFakeWorkspace()
        let entry = await GroupLauncher(workspace: workspace, approvals: F.approving(item))
            .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: .userAction).entries[0]
        #expect(entry.launchActionRefusal == .shortcutRun(.lockUnknown))
        #expect(!workspace.openedAnything)
    }

    @Test func aDelayedItemReadsTheLockWhenItFires() async {
        let item = Self.item()
        let workspace = ShortcutFakeWorkspace()
        let lock = FakeScreenLock(false)
        let launcher = Self.launcher(workspace, approving: [item], lock: lock)
        lock.reading = true
        let report = await launcher.openRightAway([item], inGroup: DockGroup(name: "Work", apps: [item]), context: "Delayed Open All", source: .userAction)
        #expect(report.entries.map(\.launchActionRefusal) == [.shortcutRun(.screenLocked)])
        #expect(!workspace.openedAnything)
        lock.reading = false
        let unlocked = await launcher.openRightAway([item], inGroup: DockGroup(name: "Work", apps: [item]), context: "Delayed Open All", source: .userAction)
        #expect(unlocked.entries.map(\.outcome) == [.launched])
    }

    // MARK: - Gate 5: two seconds

    @Test func theSameShortcutTwiceWithinTwoSecondsRunsOnce() async {
        let item = Self.item()
        let workspace = ShortcutFakeWorkspace()
        let launcher = Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false), time: 50)
        #expect(await Self.open(item, with: launcher).outcome == .launched)
        launcher.shortcutRuns.now = { 51.99 }
        let again = await Self.open(item, with: launcher)
        #expect(again.launchActionRefusal == .shortcutRun(.recentlyRun))
        #expect(again.outcome == LaunchActionItemRefusal.shortcutNotRun)
        #expect(workspace.opens.count == 1)
        launcher.shortcutRuns.now = { 52 }
        #expect(await Self.open(item, with: launcher).outcome == .launched)
        #expect(workspace.opens.count == 2)
        // A clock that seems to have gone back counts as recent.
        launcher.shortcutRuns.now = { 10 }
        #expect(await Self.open(item, with: launcher).launchActionRefusal == .shortcutRun(.recentlyRun))
        #expect(ShortcutRecentRuns.interval == 2)
    }

    @Test func oneRequestWithTheItemTwiceRunsItOnce() async {
        let item = Self.item()
        let workspace = ShortcutFakeWorkspace()
        let launcher = Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false))
        let report = await launcher.openAll(DockGroup(name: "Work", apps: [item, item]), source: .userAction)
        #expect(report.entries.map(\.launchActionRefusal) == [nil, .shortcutRun(.recentlyRun)])
        #expect(workspace.opens.count == 1)
    }

    @Test func anotherApprovedNameIsntHeldBackAndARefusalRecordsNothing() async {
        let first = Self.item("Work Setup")
        let second = Self.item("Home Setup")
        let workspace = ShortcutFakeWorkspace()
        let lock = FakeScreenLock(true)
        let launcher = Self.launcher(workspace, approving: [first, second], lock: lock)
        // Refused for the lock: not recorded, so it runs once unlocked, right away.
        #expect(await Self.open(first, with: launcher).launchActionRefusal == .shortcutRun(.screenLocked))
        lock.reading = false
        #expect(await Self.open(first, with: launcher).outcome == .launched)
        // Another digest (another name) at the same moment isn't the same run.
        #expect(await Self.open(second, with: launcher).outcome == .launched)
        #expect(workspace.opens.map(\.url.absoluteString) == [
            "shortcuts://run-shortcut?name=Work%20Setup", "shortcuts://run-shortcut?name=Home%20Setup",
        ])
    }

    // MARK: - Shortcuts.app itself

    @Test func shortcutsOutsideTheSystemAppsOrWithAnotherIdentityIsntUsed() async {
        let item = Self.item()
        let setups: [(URL?, String?)] = [
            (nil, "com.apple.shortcuts"),
            (URL(fileURLWithPath: "/Applications/Shortcuts.app"), "com.apple.shortcuts"),
            (URL(fileURLWithPath: "/Users/me/System/Applications/Shortcuts.app"), "com.apple.shortcuts"),
            (URL(fileURLWithPath: "/System/Applications/../../Users/me/Shortcuts.app"), "com.apple.shortcuts"),
            (URL(fileURLWithPath: "/System/Applications/Shortcuts.command"), "com.apple.shortcuts"),
            (URL(string: "https://example.com/System/Applications/Shortcuts.app"), "com.apple.shortcuts"),
            (ShortcutFakeWorkspace.systemLocation, "com.example.impostor"),
            (ShortcutFakeWorkspace.systemLocation, nil),
        ]
        for (location, identifier) in setups {
            let workspace = ShortcutFakeWorkspace()
            workspace.location = location
            workspace.identifier = identifier
            let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false)))
            #expect(entry.launchActionRefusal == .shortcutPlan(.shortcutsNotInstalled), "\(String(describing: location))")
            #expect(entry.outcome == LaunchActionItemRefusal.shortcutNotRun)
            #expect(workspace.opens.isEmpty && !workspace.openedAnything, "no fallback: Shortcuts isn't just brought forward")
        }
        // Compared ignoring case, as bundle identifiers are.
        let workspace = ShortcutFakeWorkspace()
        workspace.identifier = "com.apple.Shortcuts"
        #expect(await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false))).outcome == .launched)
    }

    @Test func aWorkspaceThatCantOpenAnAddressRefusesItLast() async {
        let item = Self.item()
        let workspace = LaunchActionFakeWorkspace(installed: ["com.apple.shortcuts"])
        let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false)))
        #expect(entry.launchActionRefusal == .noRunner)
        #expect(!workspace.openedAnything)
    }

    // MARK: - Failures and what is told

    @Test func aFailedOpenIsReportedInOneLineWithoutTheName() async {
        let secret = "secret-token-123"
        let item = Self.item(secret)
        let workspace = ShortcutFakeWorkspace()
        workspace.failsToOpen = true
        let entry = await Self.open(item, with: Self.launcher(workspace, approving: [item], lock: FakeScreenLock(false)))
        #expect(entry.launchActionRefusal == .shortcutRun(.openFailed))
        #expect(entry.outcome == .failed(reason: "The shortcut wasn't run."))
        #expect(workspace.opens.count == 1)
        guard case .failed(let reason) = entry.outcome else { return }
        #expect(!reason.contains(secret) && !reason.contains("\n"))
        #expect(entry.outcome.isProblem)
    }

    @Test func noCodeOrReportNamesTheShortcut() async {
        let secret = "secret-token-123"
        let item = Self.item(secret)
        var refusals: [LaunchActionItemRefusal] = LaunchSource.allCases.filter { $0 != .userAction }.map { .unattendedSource($0) }
        refusals += ShortcutPlanRefusal.allCases.map { .shortcutPlan($0) } + ShortcutRunRefusal.allCases.map { .shortcutRun($0) }
        refusals += LaunchActionApprovalRefusal.allCases.map { .approval($0) } + [.noRunner]
        for refusal in refusals {
            #expect(!refusal.code.contains(secret) && !refusal.code.contains(" "))
        }
        // Every path, as the launcher reports it.
        let failing = ShortcutFakeWorkspace()
        failing.failsToOpen = true
        let paths: [(ApplicationWorkspace, [GroupItem], Bool?, LaunchSource)] = [
            (ShortcutFakeWorkspace(), [item], false, .userAction),
            (ShortcutFakeWorkspace(), [item], false, .link),
            (ShortcutFakeWorkspace(), [], false, .userAction),
            (ShortcutFakeWorkspace(), [item], true, .userAction),
            (ShortcutFakeWorkspace(), [item], nil, .userAction),
            (failing, [item], false, .userAction),
        ]
        for (workspace, approved, reading, source) in paths {
            let report = await Self.launcher(workspace, approving: approved, lock: FakeScreenLock(reading))
                .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: source)
            for entry in report.entries {
                #expect(!String(describing: entry.outcome).contains(secret))
                #expect(!(entry.launchActionRefusal?.code.contains(secret) ?? false))
            }
        }
    }

    @Test func refusalCodesAreFixed() {
        #expect(ShortcutPlanRefusal.allCases.map(\.rawValue) == ["actionDisabled", "actionNeedsReview", "notShortcutsItem", "urlRejected", "shortcutsNotInstalled"])
        #expect(ShortcutRunRefusal.allCases.map(\.rawValue) == ["screenLocked", "lockUnknown", "recentlyRun", "openFailed"])
        #expect(LaunchActionItemRefusal.shortcutPlan(.notShortcutsItem).code == "plan.notShortcutsItem")
        #expect(LaunchActionItemRefusal.shortcutPlan(.shortcutsNotInstalled).code == "plan.shortcutsNotInstalled")
        #expect(LaunchActionItemRefusal.shortcutRun(.screenLocked).code == "run.screenLocked")
        #expect(LaunchActionItemRefusal.shortcutRun(.lockUnknown).code == "run.lockUnknown")
        #expect(LaunchActionItemRefusal.shortcutRun(.recentlyRun).code == "run.recentlyRun")
        #expect(LaunchActionItemRefusal.shortcutRun(.openFailed).code == "run.openFailed")
        #expect(LaunchActionItemRefusal.shortcutRun(.openFailed).outcome == LaunchActionItemRefusal.shortcutNotRun)
    }

    // MARK: - Gate order

    @Test func theFirstFailingGateWins() async {
        let item = Self.item()
        // Unattended + unapproved + locked: the source.
        let one = ShortcutFakeWorkspace()
        let lockOne = FakeScreenLock(true)
        #expect(await Self.open(item, with: Self.launcher(one, approving: [], lock: lockOne), source: .intent).launchActionRefusal == .unattendedSource(.intent))
        #expect(lockOne.reads == 0)
        // Unapproved + locked: the approval, before the lock is read.
        let two = ShortcutFakeWorkspace()
        let lockTwo = FakeScreenLock(true)
        #expect(await Self.open(item, with: Self.launcher(two, approving: [], lock: lockTwo)).launchActionRefusal == .approval(.missing))
        #expect(lockTwo.reads == 0)
        // Locked + no Shortcuts.app: the lock, before LaunchServices is asked.
        let three = ShortcutFakeWorkspace()
        three.location = nil
        #expect(await Self.open(item, with: Self.launcher(three, approving: [item], lock: FakeScreenLock(true))).launchActionRefusal == .shortcutRun(.screenLocked))
        #expect(three.locationQueries.isEmpty)
        // Ran just before + no Shortcuts.app: the two seconds.
        let four = ShortcutFakeWorkspace()
        let launcher = Self.launcher(four, approving: [item], lock: FakeScreenLock(false))
        #expect(await Self.open(item, with: launcher).outcome == .launched)
        four.location = nil
        #expect(await Self.open(item, with: launcher).launchActionRefusal == .shortcutRun(.recentlyRun))
        #expect(four.locationQueries.count == 1)
    }

    @Test func itemsWithoutAnActionStillOpenFromEverySource() async {
        let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
        let plainShortcuts = Self.shortcuts
        #expect(!ShortcutLaunchRunner.handles(mail) && ShortcutLaunchRunner.handles(plainShortcuts) == true)
        for source in LaunchSource.allCases {
            let workspace = ShortcutFakeWorkspace()
            let report = await Self.launcher(workspace, approving: [], lock: FakeScreenLock(nil))
                .openAll(DockGroup(name: "Work", apps: [mail]), source: source)
            #expect(report.entries.map(\.outcome) == [.launched])
            #expect(workspace.opens.isEmpty)
        }
    }

    // MARK: - Source scans

    static func sources() throws -> [(path: String, text: String)] { try LaunchActionExecutionScanTests.swiftFiles() }
    static let runnerFile = LaunchActionExecutionScanTests.shortcutRunnerFile

    /// Settings' "Open Shortcuts" button (older than this template) opens the bare scheme: no host,
    /// no name, nothing run.
    static let settingsShortcutsButton = "CybokronDockGroups/Settings/ShortcutsSettingsView.swift"

    @Test func onlyTheRunnerFileBuildsAShortcutsAddress() throws {
        let files = try Self.sources()
        #expect(files.contains { $0.path == Self.runnerFile })
        for token in ["run-shortcut", "openShortcutURL", "ShortcutRunURL"] {
            let using = Set(files.filter { $0.text.contains(token) }.map(\.path))
            #expect(using == [Self.runnerFile], "\(token): \(using.sorted())")
        }
        let opening = Set(files.filter { $0.text.contains("ShortcutOpening") }.map(\.path))
        #expect(opening == [Self.runnerFile, "DockGroupsCore/Launching/GroupLauncher.swift"])
        let scheme = Set(files.filter { $0.text.contains("shortcuts://") }.map(\.path))
        #expect(scheme == [Self.runnerFile, Self.settingsShortcutsButton])
        let settings = try #require(files.first { $0.path == Self.settingsShortcutsButton })
        let uses = settings.text.split(separator: "\n").filter { $0.contains("shortcuts://") }
        #expect(uses.map { $0.trimmingCharacters(in: .whitespaces) } == [#"guard let url = URL(string: "shortcuts://") else { return }"#])
    }

    @Test func noProcessToolScriptOrCallbackInTheShortcutPath() throws {
        let files = try Self.sources()
        // The launch action files, the runner among them; and the app's launcher setup.
        let checked = LaunchActionExecutionScanTests.allowedFiles
        for file in files where checked.contains(file.path) {
            for token in ["Process(", "Process.", "NSTask", "posix_spawn", "execv", "system(", "/usr/bin/shortcuts",
                          "x-callback-url/", "NSAppleScript", "OSAScript", "/bin/sh", "/bin/zsh"] {
                #expect(!file.text.contains(token), "\(file.path) mentions \(token)")
            }
        }
        let runner = try #require(files.first { $0.path == Self.runnerFile })
        for token in ["Process", "AppleScript", "x-success=", "x-error=", "x-cancel=", "input=", "text=", "identifier=",
                      "URLQueryItem", "queryItems =", "percentEncodedQuery =", "addingPercentEncoding", "FileManager",
                      "Logger", "os_log", "NSLog", "print("] {
            #expect(!runner.text.contains(token), "the shortcut runner mentions \(token)")
        }
    }

    @Test func onlyTheRunnerFilesAskTheSystemToOpenAndNeverTheDefaultHandler() throws {
        let files = try Self.sources()
        // The launch action code proper (the model's `AppReference` resolves an app's location and
        // the group window watches volumes; neither runs an action).
        let launchActionFiles = files.filter {
            $0.path.hasPrefix("DockGroupsCore/LaunchActions/") || $0.path.hasPrefix("DockGroupsCore/Launching/")
                || $0.path.hasPrefix("DockGroupsCore/Model/LaunchAction")
        }
        let usingWorkspace = Set(launchActionFiles.filter { $0.text.contains("NSWorkspace") }.map(\.path))
        #expect(usingWorkspace.isSuperset(of: LaunchActionExecutionScanTests.runnerFiles))
        for path in usingWorkspace.subtracting(LaunchActionExecutionScanTests.runnerFiles) {
            let file = try #require(files.first { $0.path == path })
            #expect(!LaunchActionExecutionScanTests.actionTokens.contains(where: file.text.contains), "\(path) has NSWorkspace and launch actions")
        }
        // Of the files that know a shortcut is run, only the runner file has `NSWorkspace`.
        for file in files where ["ShortcutLaunchRunner", "ShortcutOpening", "ShortcutRunURL"].contains(where: file.text.contains) {
            #expect(file.text.contains("NSWorkspace") == (file.path == Self.runnerFile), "\(file.path)")
        }
        let runner = try #require(files.first { $0.path == Self.runnerFile })
        let code = runner.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let opens = code.filter { $0.contains(".open(") }
        #expect(opens.map { $0.trimmingCharacters(in: .whitespaces) } == [
            "workspace.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in",
        ])
        for token in ["NSWorkspace.shared", "openApplication", "urlForApplication(toOpen", ".open(url", "open(url)"] {
            #expect(!runner.text.contains(token), "the shortcut runner mentions \(token)")
        }
        let configuration = code.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("configuration.") }
        #expect(configuration == [
            "configuration.activates = false",
            "configuration.addsToRecentItems = false",
            "configuration.arguments = []",
            "configuration.environment = [:]",
            "configuration.createsNewApplicationInstance = false",
        ])
    }

    /// The main app's launcher reads the screen lock; a standalone group's app gives none, so its
    /// launcher never runs a shortcut (Q6), whatever the source.
    @Test func onlyTheMainAppGivesTheLauncherALockReading() throws {
        let files = try Self.sources()
        let app = try #require(files.first { $0.path == "CybokronDockGroups/App/AppDelegate.swift" })
        let agent = try #require(files.first { $0.path == "CybokronDockGroups/Agent/AgentAppDelegate.swift" })
        #expect(app.text.contains("screenLock: { ScreenLockSource.sessionDictionaryReading() })"))
        #expect(!agent.text.contains("screenLock"))
    }

    /// The launcher's log lines interpolate fixed codes, kinds and identities only: never a name,
    /// an address, an error's text or the action.
    @Test func theLauncherLogsNoShortcutName() throws {
        let files = try Self.sources()
        let launcher = try #require(files.first { $0.path == "DockGroupsCore/Launching/GroupLauncher.swift" })
        let allowed: Set<String> = [
            "refusal.code", "String(describing: item.kind)", "context", "app.logIdentity", "description",
            "opener.bundleIdentifier", "item.logIdentity",
        ]
        let interpolation = try NSRegularExpression(pattern: #"\\\(((?:[^,()]|\([^()]*\))+)"#)
        let lines = launcher.text.split(separator: "\n").filter { $0.contains("logger.") }
        #expect(lines.count >= 5)
        for line in lines {
            let text = String(line)
            for match in interpolation.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let expression = String(text[Range(match.range(at: 1), in: text)!]).trimmingCharacters(in: .whitespaces)
                #expect(allowed.contains(expression), "logged: \(expression)")
            }
            for token in ["name", "url", "absoluteString", "error", "launchAction", "shortcutName"] {
                #expect(!text.lowercased().contains("\\(\(token.lowercased())"), "\(text)")
            }
        }
        // The shortcut path logs only through these two lines.
        let shortcutLines = lines.filter { $0.contains("hortcut") }
        #expect(shortcutLines.map { $0.trimmingCharacters(in: .whitespaces) } == [
            #"logger.notice("Handed a shortcut to Shortcuts for an application item")"#,
            #"logger.error("Shortcut not run, launch action \(refusal.code, privacy: .public): an application item")"#,
        ])
    }
}
