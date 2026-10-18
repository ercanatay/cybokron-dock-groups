import AppKit
import Testing
@testable import DockGroupsCore

@Suite("Close All")
@MainActor
struct GroupTerminatorTests {
    private let editor = AppReference(bundleIdentifier: "com.example.editor", name: "Editor")
    private let browser = AppReference(bundleIdentifier: "com.example.browser", name: "Browser")
    private let stopped = AppReference(bundleIdentifier: "com.example.stopped", name: "Stopped")
    private let stubborn = AppReference(bundleIdentifier: "com.example.stubborn", name: "Stubborn")
    private let ownPID: pid_t = 4242

    @Test func modifierKeysPickTheQuitMode() {
        #expect(QuitMode(modifierFlags: []) == .graceful)
        #expect(QuitMode(modifierFlags: .option) == .graceful)
        #expect(QuitMode(modifierFlags: .command) == .force)
        #expect(QuitMode(modifierFlags: [.command, .option]) == .force)
        #expect(QuitMode(modifierFlags: .shift) == .graceful)
    }

    @Test func gracefulQuitAsksRunningAppsToQuit() {
        let apps = FakeRunningApplications(running: [editor.bundleIdentifier: [11, 12], browser.bundleIdentifier: [13]])
        let group = DockGroup(name: "Work", apps: [editor, stopped, browser])

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID).closeAll(group, mode: .graceful)

        #expect(report.groupName == "Work")
        #expect(report.mode == .graceful)
        #expect(report.quit == [editor, browser])
        #expect(report.refused.isEmpty)
        #expect(apps.terminated == [11, 12, 13])
        #expect(apps.forceTerminated.isEmpty)
    }

    @Test func forceQuitEndsAppsImmediately() {
        let apps = FakeRunningApplications(running: [editor.bundleIdentifier: [11]])

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)
            .closeAll(DockGroup(name: "Work", apps: [editor]), mode: .force)

        #expect(report.quit == [editor])
        #expect(apps.forceTerminated == [11])
        #expect(apps.terminated.isEmpty)
    }

    @Test func refusalsAreReported() {
        let apps = FakeRunningApplications(
            running: [editor.bundleIdentifier: [11], stubborn.bundleIdentifier: [21]],
            refusing: [21]
        )

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)
            .closeAll(DockGroup(name: "Work", apps: [stubborn, editor]), mode: .graceful)

        #expect(report.quit == [editor])
        #expect(report.refused == [stubborn])
    }

    @Test func neverQuitsItselfOrFinishedApps() {
        let apps = FakeRunningApplications(
            running: [editor.bundleIdentifier: [ownPID], browser.bundleIdentifier: [31]],
            alreadyTerminated: [31]
        )
        let group = DockGroup(name: "Self", apps: [editor, browser])
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)

        #expect(!terminator.hasRunningApps(group))
        let report = terminator.closeAll(group, mode: .force)

        #expect(report.quit.isEmpty && report.refused.isEmpty)
        #expect(apps.terminated.isEmpty && apps.forceTerminated.isEmpty)
    }

    @Test func hideAllHidesOnlyRunningApps() {
        let apps = FakeRunningApplications(running: [editor.bundleIdentifier: [11, 12], browser.bundleIdentifier: [13]])
        let group = DockGroup(name: "Work", apps: [editor, stopped, browser])

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID).hideAll(group)

        #expect(report.groupName == "Work")
        #expect(report.hidden == [editor, browser])
        #expect(report.refused.isEmpty)
        #expect(apps.hidden == [11, 12, 13])
        // Hiding never quits anything, and apps that aren't running aren't launched.
        #expect(apps.terminated.isEmpty && apps.forceTerminated.isEmpty)
    }

    @Test func hideAllSkipsHiddenAppsAndReportsRefusals() {
        let apps = FakeRunningApplications(
            running: [editor.bundleIdentifier: [11], browser.bundleIdentifier: [13], stubborn.bundleIdentifier: [21]],
            refusing: [21],
            alreadyHidden: [13]
        )
        let group = DockGroup(name: "Work", apps: [editor, browser, stubborn])

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID).hideAll(group)

        #expect(report.hidden == [editor, browser])
        #expect(report.refused == [stubborn])
        #expect(apps.hidden == [11, 21])
    }

    @Test func hideAllNeverHidesItselfOrFinishedApps() {
        let apps = FakeRunningApplications(
            running: [editor.bundleIdentifier: [ownPID], browser.bundleIdentifier: [31]],
            alreadyTerminated: [31]
        )

        let report = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)
            .hideAll(DockGroup(name: "Self", apps: [editor, browser]))

        #expect(report.hidden.isEmpty && report.refused.isEmpty)
        #expect(apps.hidden.isEmpty)
    }

    @Test func websitesAreLeftAloneByCloseAllAndHideAll() throws {
        let website = AppReference(websiteURL: try WebsiteAddress.parse("github.com"))
        // Even if something claimed to run under the website's identity, it's never touched.
        let apps = FakeRunningApplications(running: [editor.bundleIdentifier: [11], website.bundleIdentifier: [99]])
        let group = DockGroup(name: "Mixed", apps: [website, editor])
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)

        #expect(!terminator.hasRunningApps(DockGroup(name: "Web", apps: [website])))
        #expect(terminator.hideAll(group).hidden == [editor])
        #expect(terminator.closeAll(group, mode: .force).quit == [editor])
        #expect(apps.hidden == [11] && apps.forceTerminated == [11])
    }

    @Test func hasRunningAppsSeesAnyRunningMember() {
        let apps = FakeRunningApplications(running: [browser.bundleIdentifier: [13]])
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: ownPID)

        #expect(terminator.hasRunningApps(DockGroup(name: "Work", apps: [stopped, browser])))
        #expect(!terminator.hasRunningApps(DockGroup(name: "Idle", apps: [stopped])))
    }
}

@Suite("Open one app")
@MainActor
struct OpenSingleAppTests {
    @Test func runningAppIsBroughtForwardOthersAreLaunched() async {
        let running = AppReference(bundleIdentifier: "com.example.running", name: "Running")
        let installed = AppReference(bundleIdentifier: "com.example.installed", name: "Installed")
        let missing = AppReference(bundleIdentifier: "com.example.missing", name: "Missing")
        let workspace = SingleAppWorkspace(running: [running.bundleIdentifier], installed: [installed.bundleIdentifier])
        let launcher = GroupLauncher(workspace: workspace)
        let group = DockGroup(name: "Work", apps: [running, installed, missing])

        #expect(await launcher.open(running, inGroup: group).entries.map(\.outcome) == [.activated])
        #expect(await launcher.open(installed, inGroup: group).entries.map(\.outcome) == [.launched])
        #expect(await launcher.open(missing, inGroup: group).problems.map(\.app) == [missing])
        #expect(workspace.launched == [installed.bundleIdentifier])
    }
}

// MARK: - Fakes

@MainActor
private final class FakeRunningApplications: RunningApplicationsProviding {
    final class App: QuittableApplication {
        let processIdentifier: pid_t
        let isTerminated: Bool
        let isHidden: Bool
        private let refuses: Bool
        private unowned let owner: FakeRunningApplications

        init(processIdentifier: pid_t, isTerminated: Bool, isHidden: Bool, refuses: Bool, owner: FakeRunningApplications) {
            self.processIdentifier = processIdentifier
            self.isTerminated = isTerminated
            self.isHidden = isHidden
            self.refuses = refuses
            self.owner = owner
        }

        func hide() -> Bool {
            MainActor.assumeIsolated { owner.hidden.append(processIdentifier) }
            return !refuses
        }

        func terminate() -> Bool {
            MainActor.assumeIsolated { owner.terminated.append(processIdentifier) }
            return !refuses
        }

        func forceTerminate() -> Bool {
            MainActor.assumeIsolated { owner.forceTerminated.append(processIdentifier) }
            return !refuses
        }
    }

    private var apps: [String: [App]] = [:]
    var terminated: [pid_t] = []
    var forceTerminated: [pid_t] = []
    var hidden: [pid_t] = []

    init(
        running: [String: [pid_t]],
        refusing: Set<pid_t> = [],
        alreadyTerminated: Set<pid_t> = [],
        alreadyHidden: Set<pid_t> = []
    ) {
        for (bundleIdentifier, pids) in running {
            apps[bundleIdentifier] = pids.map {
                App(
                    processIdentifier: $0,
                    isTerminated: alreadyTerminated.contains($0),
                    isHidden: alreadyHidden.contains($0),
                    refuses: refusing.contains($0),
                    owner: self
                )
            }
        }
    }

    func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] {
        apps[bundleIdentifier] ?? []
    }
}

@MainActor
private final class SingleAppWorkspace: ApplicationWorkspace {
    private let running: Set<String>
    private let installed: Set<String>
    private(set) var launched: [String] = []

    init(running: Set<String>, installed: Set<String>) {
        self.running = running
        self.installed = installed
    }

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        running.contains(bundleIdentifier)
    }

    func locateApplication(_ app: AppReference) -> URL? {
        installed.contains(app.bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app") : nil
    }

    func launchApplication(at url: URL) async throws {
        launched.append(url.deletingPathExtension().lastPathComponent)
    }

    func openWebsites(_ urls: [URL]) async throws {}
}
