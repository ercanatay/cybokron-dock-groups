import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Restoring running apps' windows")
@MainActor
struct WindowRestorerTests {
    // MARK: - Which windows come back

    @Test func allMinimizedWindowsComeBackWhenNoneIsLeftOut() {
        let first = FakeWindow(isMinimized: true)
        let second = FakeWindow(isMinimized: true)

        #expect(identities(WindowRestorer.windowsToRestore([first, second])) == identities([first, second]))
    }

    @Test func nothingComesBackWhileAStandardWindowIsShown() {
        let shown = FakeWindow(isMinimized: false)
        let minimized = FakeWindow(isMinimized: true)

        #expect(WindowRestorer.windowsToRestore([shown, minimized]).isEmpty)
    }

    @Test func panelsDontCountAsShownWindows() {
        let palette = FakeWindow(isMinimized: false, isStandard: false)
        let minimized = FakeWindow(isMinimized: true)

        #expect(identities(WindowRestorer.windowsToRestore([palette, minimized])) == identities([minimized]))
    }

    @Test func anAppWithoutWindowsHasNothingToRestore() {
        #expect(WindowRestorer.windowsToRestore([]).isEmpty)
    }

    // MARK: - Restoring

    @Test func hiddenAppIsUnhiddenEvenWithoutAccessibilityAccess() {
        let accessibility = FakeAccessibility(isTrusted: false, windows: [FakeWindow(isMinimized: true)])
        let app = FakeApplication(isHidden: true)

        let outcome = WindowRestorer(accessibility: accessibility).restore(app)

        #expect(outcome == WindowRestorer.Outcome(unhid: true, restoredWindowCount: 0))
        #expect(app.unhideCount == 1)
        #expect(accessibility.readCount == 0, "windows aren't read without access")
    }

    @Test func visibleAppIsNotUnhidden() {
        let app = FakeApplication(isHidden: false)

        let outcome = WindowRestorer(accessibility: FakeAccessibility(isTrusted: true, windows: [])).restore(app)

        #expect(outcome == WindowRestorer.Outcome(unhid: false, restoredWindowCount: 0))
        #expect(app.unhideCount == 0)
    }

    @Test func minimizedWindowsAreRestoredAndTheFrontmostRaised() {
        let front = FakeWindow(isMinimized: true)
        let back = FakeWindow(isMinimized: true)
        let accessibility = FakeAccessibility(isTrusted: true, windows: [front, back])

        let outcome = WindowRestorer(accessibility: accessibility).restore(FakeApplication(isHidden: false))

        #expect(outcome.restoredWindowCount == 2)
        #expect(front.restoreCount == 1 && back.restoreCount == 1)
        #expect(front.raiseCount == 1)
        #expect(back.raiseCount == 0)
        #expect(accessibility.requestedProcess == FakeApplication.processIdentifier)
    }

    @Test func windowsTheAppRefusesToRestoreArentCounted() {
        let refusing = FakeWindow(isMinimized: true, restores: false)
        let willing = FakeWindow(isMinimized: true)
        let accessibility = FakeAccessibility(isTrusted: true, windows: [refusing, willing])

        let outcome = WindowRestorer(accessibility: accessibility).restore(FakeApplication(isHidden: false))

        #expect(outcome.restoredWindowCount == 1)
        #expect(willing.raiseCount == 1)
        #expect(refusing.raiseCount == 0)
    }

    @Test func shownWindowsLeaveMinimizedOnesAlone() {
        let shown = FakeWindow(isMinimized: false)
        let minimized = FakeWindow(isMinimized: true)
        let accessibility = FakeAccessibility(isTrusted: true, windows: [shown, minimized])

        let outcome = WindowRestorer(accessibility: accessibility).restore(FakeApplication(isHidden: false))

        #expect(outcome.restoredWindowCount == 0)
        #expect(minimized.restoreCount == 0)
    }

    @Test func unreadableWindowsRestoreNothing() {
        let accessibility = FakeAccessibility(isTrusted: true, windows: nil)

        let outcome = WindowRestorer(accessibility: accessibility).restore(FakeApplication(isHidden: true))

        #expect(outcome == WindowRestorer.Outcome(unhid: true, restoredWindowCount: 0))
    }

    @Test func accessTellsWhetherMinimizedWindowsCanComeBack() {
        #expect(WindowRestorer(accessibility: FakeAccessibility(isTrusted: true, windows: [])).canRestoreMinimizedWindows)
        #expect(!WindowRestorer(accessibility: FakeAccessibility(isTrusted: false, windows: [])).canRestoreMinimizedWindows)
    }

    @Test func accessGrantedWhileRunningWorksOnTheNextRestore() {
        let window = FakeWindow(isMinimized: true)
        let accessibility = FakeAccessibility(isTrusted: false, windows: [window])
        let restorer = WindowRestorer(accessibility: accessibility)

        #expect(restorer.restore(FakeApplication(isHidden: false)).restoredWindowCount == 0)
        accessibility.isTrusted = true

        #expect(restorer.canRestoreMinimizedWindows, "access isn't cached")
        #expect(restorer.restore(FakeApplication(isHidden: false)).restoredWindowCount == 1)
        #expect(window.restoreCount == 1)
    }

    // MARK: - Opening an app

    @Test func openingARunningAppReopensItWhenRestoringWindows() async {
        let workspace = ReopenRecordingWorkspace(running: ["com.example.notes"])
        let app = AppReference(bundleIdentifier: "com.example.notes", name: "Notes")
        let launcher = GroupLauncher(workspace: workspace)
        let group = DockGroup(name: "Work", apps: [app])

        let restoring = await launcher.open(app, inGroup: group, restoringWindows: true)
        let plain = await launcher.open(app, inGroup: group)

        #expect(restoring.entries.map(\.outcome) == [.activated])
        #expect(plain.entries.map(\.outcome) == [.activated])
        #expect(workspace.reopened == ["com.example.notes"])
        #expect(workspace.activated == ["com.example.notes"])
    }

    @Test func restoringWindowsStillLaunchesAppsThatArentRunning() async {
        let workspace = ReopenRecordingWorkspace(running: [])
        let app = AppReference(bundleIdentifier: "com.example.notes", name: "Notes")

        let report = await GroupLauncher(workspace: workspace).open(app, inGroup: DockGroup(name: "Work", apps: [app]), restoringWindows: true)

        #expect(report.entries.map(\.outcome) == [.launched])
        #expect(workspace.launched == ["com.example.notes"])
    }

    // MARK: - Preference

    @Test func restoringIsOnByDefaultAndSavedUnderItsKey() throws {
        #expect(PopupPreferences().restoresWindowsOfRunningApps)

        let data = try JSONEncoder().encode(PopupPreferences(restoresWindowsOfRunningApps: false))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["restoreRunningAppWindows"] as? Bool == false)
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: data).restoresWindowsOfRunningApps == false)
    }

    @Test func missingOrInvalidRestoreSettingFallsBackToOn() throws {
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: Data("{}".utf8)).restoresWindowsOfRunningApps)
        let invalid = Data(#"{ "restoreRunningAppWindows": "no" }"#.utf8)
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: invalid).restoresWindowsOfRunningApps)
    }

    @Test func standaloneGroupsGetTheRestoreSetting() throws {
        let configuration = AgentConfiguration(group: DockGroup(name: "Work"), preferences: PopupPreferences(restoresWindowsOfRunningApps: false))

        #expect(try AgentConfiguration.decode(from: configuration.encoded()).preferences.restoresWindowsOfRunningApps == false)
    }

    private func identities(_ windows: [any AccessibleWindow]) -> [ObjectIdentifier] {
        windows.map { ObjectIdentifier($0) }
    }
}

@MainActor
private final class FakeWindow: AccessibleWindow {
    private(set) var isMinimized: Bool
    let isStandard: Bool
    private let restores: Bool
    private(set) var restoreCount = 0
    private(set) var raiseCount = 0

    init(isMinimized: Bool, isStandard: Bool = true, restores: Bool = true) {
        self.isMinimized = isMinimized
        self.isStandard = isStandard
        self.restores = restores
    }

    func restore() -> Bool {
        restoreCount += 1
        if restores {
            isMinimized = false
        }
        return restores
    }

    func raise() {
        raiseCount += 1
    }
}

@MainActor
private final class FakeAccessibility: WindowAccessibility {
    var isTrusted: Bool
    private let windows: [FakeWindow]?
    private(set) var readCount = 0
    private(set) var requestedProcess: pid_t?

    init(isTrusted: Bool, windows: [FakeWindow]?) {
        self.isTrusted = isTrusted
        self.windows = windows
    }

    func windows(ofProcess processIdentifier: pid_t) -> [any AccessibleWindow]? {
        readCount += 1
        requestedProcess = processIdentifier
        return windows
    }
}

private final class FakeApplication: RestorableApplication {
    static let processIdentifier: pid_t = 4242

    var processIdentifier: pid_t { Self.processIdentifier }
    private(set) var isHidden: Bool
    private(set) var unhideCount = 0

    init(isHidden: Bool) {
        self.isHidden = isHidden
    }

    func unhide() -> Bool {
        unhideCount += 1
        isHidden = false
        return true
    }
}

@MainActor
private final class ReopenRecordingWorkspace: ApplicationWorkspace {
    private let running: Set<String>
    private(set) var activated: [String] = []
    private(set) var reopened: [String] = []
    private(set) var launched: [String] = []

    init(running: Set<String>) {
        self.running = running
    }

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard running.contains(bundleIdentifier) else { return false }
        activated.append(bundleIdentifier)
        return true
    }

    func reopenRunningApplication(bundleIdentifier: String) -> Bool {
        guard running.contains(bundleIdentifier) else { return false }
        reopened.append(bundleIdentifier)
        return true
    }

    func locateApplication(_ app: AppReference) -> URL? {
        URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app")
    }

    func launchApplication(at url: URL) async throws {
        launched.append(url.deletingPathExtension().lastPathComponent)
    }
    func openWebsites(_ urls: [URL]) async throws {}
    func openFileItems(_ urls: [URL]) async -> [URL: any Error] { [:] }
    func revealFileItems(_ urls: [URL]) {}
}
