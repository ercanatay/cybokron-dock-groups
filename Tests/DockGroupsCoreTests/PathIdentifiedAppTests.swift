import Foundation
import Testing
@testable import DockGroupsCore

/// Apps without a bundle identifier, such as a hand-made `Half-Life.app` wrapper with no
/// Info.plist, are identified by their location.
@Suite("Apps without a bundle identifier")
@MainActor
struct PathIdentifiedAppTests {
    /// Fixtures live under /var/tmp, which is a symbolic link to /private/var/tmp: running apps
    /// can report either form of the path.
    private static let fixtureBase = URL(fileURLWithPath: "/var/tmp", isDirectory: true)

    @Test func bundleWithoutInfoPlistIsIdentifiedByItsLocation() throws {
        let directory = try TemporaryDirectory(base: Self.fixtureBase)
        defer { directory.remove() }
        let appURL = try directory.makeScriptAppBundle(named: "Half-Life")

        let app = try AppReference(applicationURL: appURL)

        #expect(app.isIdentifiedByPath)
        #expect(app.bundleIdentifier == appURL.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(app.name == "Half-Life")
        #expect(app.resolvedURL()?.standardizedFileURL.path == appURL.standardizedFileURL.path)
    }

    @Test func pathIdentifiedAppIsSavedAndNotAddedTwice() throws {
        let directory = try TemporaryDirectory(base: Self.fixtureBase)
        defer { directory.remove() }
        let appURL = try directory.makeScriptAppBundle(named: "Half-Life")
        let persistence = JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json"))
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Games")

        #expect(store.addApps([try AppReference(applicationURL: appURL)], toGroup: group.id) == 1)
        #expect(store.addApps([try AppReference(applicationURL: appURL)], toGroup: group.id) == 0)

        let reloaded = GroupStore(persistence: persistence, saveDelay: .zero)
        let app = try #require(reloaded.group(withID: group.id)?.apps.first)
        #expect(app.isIdentifiedByPath)
        #expect(app.name == "Half-Life")
    }

    @Test func openAllLaunchesThePathAndCloseAllQuitsIt() async throws {
        let directory = try TemporaryDirectory(base: Self.fixtureBase)
        defer { directory.remove() }
        let appURL = try directory.makeScriptAppBundle(named: "Half-Life")
        let app = try AppReference(applicationURL: appURL)
        let group = DockGroup(name: "Games", apps: [app])

        let workspace = LocatingWorkspace()
        let report = await GroupLauncher(workspace: workspace).openAll(group)
        #expect(report.entries.map(\.outcome) == [.launched])
        #expect(workspace.launched.map(\.standardizedFileURL.path) == [appURL.standardizedFileURL.path])

        workspace.running = [app.bundleIdentifier]
        let second = await GroupLauncher(workspace: workspace).open(app, inGroup: group)
        #expect(second.entries.map(\.outcome) == [.activated])
        #expect(workspace.launched.count == 1)

        let applications = PathRunningApplications(running: [app.bundleIdentifier])
        let quit = GroupTerminator(applications: applications, ownProcessIdentifier: 1).closeAll(group, mode: .graceful)
        #expect(quit.quit == [app])
        #expect(applications.terminated == [app.bundleIdentifier])
    }

    @Test func movedAwayAppIsNotFound() async throws {
        let directory = try TemporaryDirectory(base: Self.fixtureBase)
        let appURL = try directory.makeScriptAppBundle(named: "Half-Life")
        let app = try AppReference(applicationURL: appURL)
        directory.remove()

        #expect(app.resolvedURL() == nil)
        let report = await GroupLauncher(workspace: LocatingWorkspace()).openAll(DockGroup(name: "Games", apps: [app]))
        #expect(report.entries.map(\.outcome) == [.notFound])
    }

    @Test func runningInstancesAreMatchedByTheirBundleLocation() throws {
        let directory = try TemporaryDirectory(base: Self.fixtureBase)
        defer { directory.remove() }
        let appURL = try directory.makeScriptAppBundle(named: "Half-Life")
        let otherURL = try directory.makeScriptAppBundle(named: "Opposing Force")
        let app = try AppReference(applicationURL: appURL)

        let privatePath = "/private" + appURL.standardizedFileURL.path
        for reported in [appURL, URL(fileURLWithPath: privatePath, isDirectory: true), URL(fileURLWithPath: privatePath + "/")] {
            #expect(RunningApplicationLookup.pathIdentity(bundleIdentifier: nil, bundleURL: reported) == app.normalizedBundleIdentifier)
        }
        #expect(RunningApplicationLookup.pathIdentity(bundleIdentifier: nil, bundleURL: otherURL) != app.normalizedBundleIdentifier)
        // Apps with a bundle identifier are matched by it, never by location.
        #expect(RunningApplicationLookup.pathIdentity(bundleIdentifier: "com.example.game", bundleURL: appURL) == nil)
        #expect(RunningApplicationLookup.pathIdentity(bundleIdentifier: nil, bundleURL: nil) == nil)
    }
}

// MARK: - Fakes

/// Finds apps with `AppReference.resolvedURL()` (which, for apps identified by path, only checks
/// the file system) and records launches instead of performing them.
@MainActor
private final class LocatingWorkspace: ApplicationWorkspace {
    var running: Set<String> = []
    private(set) var launched: [URL] = []

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        running.contains(bundleIdentifier)
    }

    func locateApplication(_ app: AppReference) -> URL? {
        app.resolvedURL()
    }

    func launchApplication(at url: URL) async throws {
        launched.append(url)
    }
}

@MainActor
private final class PathRunningApplications: RunningApplicationsProviding {
    final class App: QuittableApplication {
        let processIdentifier: pid_t = 42
        let isTerminated = false
        let isHidden = false
        private let identifier: String
        private unowned let owner: PathRunningApplications

        init(identifier: String, owner: PathRunningApplications) {
            self.identifier = identifier
            self.owner = owner
        }

        func terminate() -> Bool {
            MainActor.assumeIsolated { owner.terminated.append(identifier) }
            return true
        }

        func forceTerminate() -> Bool { terminate() }

        func hide() -> Bool { true }
    }

    private let running: Set<String>
    var terminated: [String] = []

    init(running: Set<String>) {
        self.running = running
    }

    func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] {
        running.contains(bundleIdentifier) ? [App(identifier: bundleIdentifier, owner: self)] : []
    }
}
