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

    @Test func emptyGroupDoesNothing() async {
        let workspace = FakeWorkspace()

        let report = await GroupLauncher(workspace: workspace).openAll(DockGroup(name: "Empty"))

        #expect(report.entries.isEmpty)
        #expect(workspace.launched.isEmpty && workspace.activated.isEmpty)
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
    private(set) var activated: [String] = []
    private(set) var launched: [String] = []

    init(running: Set<String> = [], installed: Set<String> = [], failing: Set<String> = []) {
        self.running = running
        self.installed = installed
        self.failing = failing
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
}
