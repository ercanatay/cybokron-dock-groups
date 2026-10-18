import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Open All")
@MainActor
struct GroupLauncherTests {
    private let running = AppReference(bundleIdentifier: "com.example.running", name: "Running")
    private let installed = AppReference(bundleIdentifier: "com.example.installed", name: "Installed")
    private let missing = AppReference(bundleIdentifier: "com.example.missing", name: "Missing")
    private let broken = AppReference(bundleIdentifier: "com.example.broken", name: "Broken")

    @Test func launchesStoppedAppsAndActivatesRunningOnes() async {
        let workspace = FakeWorkspace(
            running: [running.bundleIdentifier],
            installed: [running.bundleIdentifier, installed.bundleIdentifier, broken.bundleIdentifier],
            failing: [broken.bundleIdentifier]
        )
        let group = DockGroup(name: "Mixed", apps: [running, installed, missing, broken])

        let report = await GroupLauncher(workspace: workspace).openAll(group)

        #expect(report.groupName == "Mixed")
        #expect(report.entries.map(\.app) == group.apps)
        #expect(report.entries.map(\.outcome) == [
            .activated,
            .launched,
            .notFound,
            .failed(reason: FakeWorkspace.LaunchError().localizedDescription),
        ])
        #expect(report.problems.map(\.app) == [missing, broken])
        #expect(workspace.activated == [running.bundleIdentifier])
        #expect(Set(workspace.launched) == [installed.bundleIdentifier, broken.bundleIdentifier])
    }

    @Test func neverLaunchesARunningAppAgain() async {
        let workspace = FakeWorkspace(running: [running.bundleIdentifier], installed: [running.bundleIdentifier])

        let report = await GroupLauncher(workspace: workspace).openAll(DockGroup(name: "One", apps: [running]))

        #expect(report.problems.isEmpty)
        #expect(workspace.launched.isEmpty)
    }

    @Test func openAllOpensTheWebsitesTogetherInOneRequest() async throws {
        let github = AppReference(websiteURL: try WebsiteAddress.parse("github.com"))
        let docs = AppReference(websiteURL: try WebsiteAddress.parse("https://developer.apple.com/documentation"), name: "Docs")
        let workspace = FakeWorkspace(installed: [installed.bundleIdentifier])
        let group = DockGroup(name: "Web", apps: [github, installed, docs])

        let report = await GroupLauncher(workspace: workspace).openAll(group)

        #expect(report.entries.map(\.outcome) == [.launched, .launched, .launched])
        #expect(workspace.websiteRequests == [["https://github.com", "https://developer.apple.com/documentation"]])
        #expect(workspace.launched == [installed.bundleIdentifier])
        // Websites are never looked up or activated as apps.
        #expect(workspace.activated.isEmpty)
    }

    @Test func openingAWebsiteUsesTheBrowser() async throws {
        let github = AppReference(websiteURL: try WebsiteAddress.parse("github.com"))
        let workspace = FakeWorkspace()

        let report = await GroupLauncher(workspace: workspace).open(github, inGroup: DockGroup(name: "Web", apps: [github]))

        #expect(report.entries.map(\.outcome) == [.launched])
        #expect(workspace.websiteRequests == [["https://github.com"]])
        #expect(workspace.launched.isEmpty)
    }

    @Test func aRefusedWebsiteIsReported() async throws {
        let github = AppReference(websiteURL: try WebsiteAddress.parse("github.com"))
        let workspace = FakeWorkspace(refusesWebsites: true)

        let report = await GroupLauncher(workspace: workspace).openAll(DockGroup(name: "Web", apps: [github]))

        #expect(report.problems.map(\.app) == [github])
        #expect(report.entries.map(\.outcome) == [.failed(reason: FakeWorkspace.LaunchError().localizedDescription)])
    }

    @Test func emptyGroupDoesNothing() async {
        let workspace = FakeWorkspace()

        let report = await GroupLauncher(workspace: workspace).openAll(DockGroup(name: "Empty"))

        #expect(report.entries.isEmpty)
        #expect(workspace.launched.isEmpty && workspace.activated.isEmpty && workspace.websiteRequests.isEmpty)
    }
}

@MainActor
private final class FakeWorkspace: ApplicationWorkspace {
    struct LaunchError: LocalizedError {
        var errorDescription: String? { "Launch refused." }
    }

    private let running: Set<String>
    private let installed: Set<String>
    private let failing: Set<String>
    private let refusesWebsites: Bool
    private(set) var activated: [String] = []
    private(set) var launched: [String] = []
    /// Each request to open websites, with its addresses.
    private(set) var websiteRequests: [[String]] = []

    init(running: Set<String> = [], installed: Set<String> = [], failing: Set<String> = [], refusesWebsites: Bool = false) {
        self.running = running
        self.installed = installed
        self.failing = failing
        self.refusesWebsites = refusesWebsites
    }

    func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard running.contains(bundleIdentifier) else { return false }
        activated.append(bundleIdentifier)
        return true
    }

    func locateApplication(_ app: AppReference) -> URL? {
        installed.contains(app.bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app") : nil
    }

    func launchApplication(at url: URL) async throws {
        let bundleIdentifier = url.deletingPathExtension().lastPathComponent
        launched.append(bundleIdentifier)
        if failing.contains(bundleIdentifier) {
            throw LaunchError()
        }
    }

    func openWebsites(_ urls: [URL]) async throws {
        websiteRequests.append(urls.map(\.absoluteString))
        if refusesWebsites {
            throw LaunchError()
        }
    }
}
