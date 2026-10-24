import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: Close All and protected apps")
@MainActor
struct ProtectedCloseAllTests {
    private static let ownPID: pid_t = 1
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let music = AppReference(bundleIdentifier: "com.apple.Music", name: "Music")
    private static let finder = AppReference(bundleIdentifier: "com.apple.finder", name: "Finder")

    private func terminator(_ apps: FakeRunningApps, protected: [GroupItem] = []) -> GroupTerminator {
        GroupTerminator(applications: apps, ownProcessIdentifier: Self.ownPID, listing: apps, protectedApps: { ProtectedApps(protected) })
    }

    @Test func closeAllLeavesProtectedAppsAloneWhateverTheMode() {
        for mode in [QuitMode.graceful, .force] {
            let apps = FakeRunningApps()
            apps.run("com.apple.mail")
            apps.run("com.apple.Music")
            let group = DockGroup(name: "Work", apps: [Self.music, Self.mail])

            let report = terminator(apps, protected: [AppReference(bundleIdentifier: "COM.APPLE.MUSIC", name: "Music")]).closeAll(group, mode: mode)

            #expect(report.quit == [Self.mail])
            #expect(report.kept == [Self.music])
            #expect(report.refused.isEmpty)
            #expect(apps.log.events(withPrefix: mode == .force ? "force:" : "quit:") == ["com.apple.mail"])
        }
    }

    @Test func finderAndTheGroupsOwnAppsAreNeverQuitByCloseAll() {
        let apps = FakeRunningApps()
        let agentID = AgentIdentity.bundleIdentifier(for: UUID())
        apps.run("com.apple.finder")
        apps.run(agentID)
        apps.run("com.cybokron.dockgroups")
        apps.run("com.apple.mail")
        let agent = AppReference(bundleIdentifier: agentID, name: "Work")
        let host = AppReference(bundleIdentifier: "com.cybokron.dockgroups", name: "Cybokron Dock Groups")
        let group = DockGroup(name: "Everything", apps: [Self.finder, agent, host, Self.mail])

        let report = terminator(apps).closeAll(group, mode: .force)

        #expect(report.quit == [Self.mail])
        #expect(report.kept == [Self.finder, agent, host])
        // Hide All doesn't consult the list: the user asked to hide the group.
        let running = FakeRunningApps()
        running.run("com.apple.mail")
        let hidden = terminator(running, protected: [Self.mail]).hideAll(DockGroup(name: "Mail", apps: [Self.mail]))
        #expect(hidden.hidden == [Self.mail])
    }

    @Test func protectedAppsStillCountAsRunning() {
        let apps = FakeRunningApps()
        apps.run("com.apple.Music")
        #expect(terminator(apps, protected: [Self.music]).hasRunningApps(DockGroup(name: "Music", apps: [Self.music])))
    }

    @Test func theSummarySaysWhichAppsStayOpen() {
        let report = QuitReport(groupName: "Work", mode: .graceful, quit: [Self.mail], refused: [], kept: [Self.music])
        #expect(report.summary == "Asked 1 app in “Work” to quit. Music is protected and stays open.")
        let onlyKept = QuitReport(groupName: "Work", mode: .graceful, quit: [], refused: [], kept: [Self.music, Self.finder])
        #expect(onlyKept.summary == "Music and Finder are protected and stay open.")
        // Without protected apps the summaries are as before.
        #expect(QuitReport(groupName: "Work", mode: .graceful, quit: [], refused: []).summary == "None of the apps in “Work” are running.")
    }

    // MARK: - Transitions

    @Test func hidingAndQuittingSkipProtectedAppsThisAppAndAppsThatAreGone() {
        let apps = FakeRunningApps()
        let mail = apps.run("com.apple.mail")
        let music = apps.run("com.apple.Music")
        let finder = apps.run("com.apple.finder")
        let gone = apps.run("com.example.gone")
        gone.isTerminated = true
        let own = RunningAppSnapshot(processIdentifier: Self.ownPID, identity: "com.example.anything", name: "Me")
        let terminator = terminator(apps, protected: [Self.music])

        let hidden = terminator.hide([mail.snapshot, music.snapshot, finder.snapshot, gone.snapshot, own])
        #expect(hidden.done.map(\.identity) == ["com.apple.mail", "com.apple.finder"])
        #expect(hidden.skipped.map(\.identity) == ["com.apple.music", "com.example.gone", "com.example.anything"])

        let quit = terminator.quit([mail.snapshot, music.snapshot, finder.snapshot])
        #expect(quit.done.map(\.identity) == ["com.apple.mail"])
        #expect(quit.skipped.map(\.identity) == ["com.apple.music", "com.apple.finder"])
        #expect(apps.log.events(withPrefix: "quit:") == ["com.apple.mail"])
        #expect(apps.log.events(withPrefix: "force:").isEmpty, "never forced")
    }

    @Test func aReusedProcessIdentifierIsLeftAlone() {
        let apps = FakeRunningApps()
        let mail = apps.run("com.apple.mail", pid: 500)
        let planned = mail.snapshot
        // Mail quit, and another app now has its process identifier.
        apps.reuse(pid: 500, for: "com.example.other")

        let report = terminator(apps).quit([planned])

        #expect(report.done.isEmpty && report.skipped == [planned])
        #expect(apps.log.events(withPrefix: "quit:").isEmpty)
    }

    @Test func refusalsAreReported() {
        let apps = FakeRunningApps()
        let stubborn = apps.run("com.example.stubborn")
        stubborn.refuses = true
        let report = terminator(apps).hide([stubborn.snapshot])
        #expect(report.refused == [stubborn.snapshot] && report.done.isEmpty)
    }

    @Test func showingAgainUnhidesAndBringsOneForward() {
        let apps = FakeRunningApps()
        let figma = apps.run("com.figma.Desktop", hidden: true)
        let sketch = apps.run("com.bohemiancoding.sketch3", hidden: false)
        let agent = apps.run(AgentIdentity.bundleIdentifier(for: UUID()), hidden: true)

        let report = terminator(apps, protected: [AppReference(bundleIdentifier: "com.figma.Desktop", name: "Figma")])
            .unhide([figma.snapshot, sketch.snapshot, agent.snapshot], bringingToFront: figma.snapshot)

        // Showing an app again is never refused for protection; this app's agents are left alone.
        #expect(report.done.map(\.identity) == ["com.figma.desktop", "com.bohemiancoding.sketch3"])
        #expect(report.skipped == [agent.snapshot])
        #expect(apps.log.events == ["unhide:com.figma.desktop", "front:com.figma.desktop"])
        #expect(!figma.isHidden)
    }
}
