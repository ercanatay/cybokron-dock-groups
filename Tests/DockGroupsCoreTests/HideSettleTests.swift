import AppKit
import Testing
@testable import DockGroupsCore

/// Hide All and Hide on Start/Finish give an app that answered "no" a moment to show up hidden,
/// and don't blame background apps for staying visible.
@Suite("Hide: settling")
@MainActor
struct HideSettleTests {
    private let mail = AppReference(bundleIdentifier: "com.example.mail", name: "Mail")
    private let agent = AppReference(bundleIdentifier: "com.example.agent", name: "Agent")
    private let helper = AppReference(bundleIdentifier: "com.example.helper", name: "Helper")

    /// An app whose `hide()` says no; with `hidesLater` it's hidden once the terminator waits.
    private final class App: SwitchableApplication {
        let processIdentifier: pid_t
        let isTerminated = false
        var isHidden: Bool
        let activationPolicy: NSApplication.ActivationPolicy
        var hideCalls = 0
        var hidesLater = false
        let bundleIdentifier: String?
        var bundleURL: URL? { nil }

        init(pid: pid_t, id: String = "com.example.app", policy: NSApplication.ActivationPolicy = .regular, hidden: Bool = false) {
            processIdentifier = pid
            bundleIdentifier = id
            activationPolicy = policy
            isHidden = hidden
        }

        func hide() -> Bool { hideCalls += 1; return false }
        func unhide() -> Bool { true }
        func activate(options: NSApplication.ActivationOptions) -> Bool { true }
        func terminate() -> Bool { true }
        func forceTerminate() -> Bool { true }
    }

    @MainActor
    private final class Provider: RunningApplicationsProviding, RunningApplicationsListing {
        var apps: [String: [App]] = [:]
        func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] { apps[bundleIdentifier] ?? [] }
        func runningApplications() -> [RunningAppSnapshot] { [] }
        func application(withProcessIdentifier processIdentifier: pid_t) -> (any SwitchableApplication)? {
            apps.values.flatMap { $0 }.first { $0.processIdentifier == processIdentifier }
        }
    }

    /// Applies the delayed hides when the terminator waits.
    @MainActor
    private final class HidingSleeper: Sleeping {
        var apps: [App] = []
        private(set) var sleeps: [Duration] = []

        func sleep(for duration: Duration) async throws {
            sleeps.append(duration)
            for app in apps where app.hidesLater { app.isHidden = true }
        }
    }

    private func make(_ apps: [String: [App]]) -> (GroupTerminator, HidingSleeper) {
        let provider = Provider()
        provider.apps = apps
        let sleeper = HidingSleeper()
        sleeper.apps = apps.values.flatMap { $0 }
        return (GroupTerminator(applications: provider, ownProcessIdentifier: 1, listing: provider, sleeper: sleeper), sleeper)
    }

    @Test func anAppThatHidesAfterSayingNoCountsAsHidden() async {
        let slow = App(pid: 10)
        slow.hidesLater = true
        let (terminator, sleeper) = make([mail.bundleIdentifier: [slow]])

        let report = await terminator.hideAllSettled(DockGroup(name: "Work", apps: [mail]))

        #expect(report.hidden == [mail])
        #expect(report.refused.isEmpty && report.unhideable.isEmpty)
        #expect(slow.hideCalls == 1)
        #expect(sleeper.sleeps == [GroupTerminator.hideSettleDelay])
    }

    @Test func aRegularAppThatNeverHidesIsStillRefused() async {
        let stuck = App(pid: 10)
        let (terminator, sleeper) = make([mail.bundleIdentifier: [stuck]])

        let report = await terminator.hideAllSettled(DockGroup(name: "Work", apps: [mail]))

        #expect(report.hidden.isEmpty)
        #expect(report.refused == [mail])
        #expect(sleeper.sleeps.count == 1)
    }

    @Test func backgroundAppsThatStayVisibleAreNotRefused() async {
        let accessory = App(pid: 10, policy: .accessory)
        let prohibited = App(pid: 11, policy: .prohibited)
        let (terminator, sleeper) = make([agent.bundleIdentifier: [accessory], helper.bundleIdentifier: [prohibited]])

        let report = await terminator.hideAllSettled(DockGroup(name: "Work", apps: [agent, helper]))

        #expect(report.refused.isEmpty && report.hidden.isEmpty)
        #expect(report.unhideable == [agent, helper])
        // Nothing hideable was waiting, so there was nothing to wait for.
        #expect(sleeper.sleeps.isEmpty)
    }

    @Test func anAlreadyHiddenAppIsDoneWithoutAskingOrWaiting() async {
        let hidden = App(pid: 10, hidden: true)
        let (terminator, sleeper) = make([mail.bundleIdentifier: [hidden]])

        let report = await terminator.hideAllSettled(DockGroup(name: "Work", apps: [mail]))

        #expect(report.hidden == [mail])
        #expect(hidden.hideCalls == 0)
        #expect(sleeper.sleeps.isEmpty)
    }

    @Test func mixedGroupReportsEachAppByItsOwnOutcome() async {
        let slow = App(pid: 10)
        slow.hidesLater = true
        let stuck = App(pid: 11)
        let accessory = App(pid: 12, policy: .accessory)
        let stuckApp = AppReference(bundleIdentifier: "com.example.stuck", name: "Stuck")
        let (terminator, _) = make([
            mail.bundleIdentifier: [slow], stuckApp.bundleIdentifier: [stuck], agent.bundleIdentifier: [accessory],
        ])

        let report = await terminator.hideAllSettled(DockGroup(name: "Work", apps: [mail, stuckApp, agent]))

        #expect(report.hidden == [mail])
        #expect(report.refused == [stuckApp])
        #expect(report.unhideable == [agent])
    }

    @Test func startAndFinishHideSettlesToo() async {
        let slow = App(pid: 10, id: "com.example.slow")
        slow.hidesLater = true
        let stuck = App(pid: 11, id: "com.example.stuck")
        let accessory = App(pid: 12, id: "com.example.acc", policy: .accessory)
        let (terminator, sleeper) = make(["a": [slow], "b": [stuck], "c": [accessory]])
        func snapshot(_ app: App) -> RunningAppSnapshot {
            RunningAppSnapshot(
                processIdentifier: app.processIdentifier,
                identity: RunningAppSnapshot.identity(bundleIdentifier: app.bundleIdentifier, bundleURL: nil) ?? "",
                name: app.bundleIdentifier ?? "",
                isHidden: false,
                isRegular: true
            )
        }

        let report = await terminator.hideSettled([snapshot(slow), snapshot(stuck), snapshot(accessory)])

        #expect(report.done.map(\.processIdentifier) == [10])
        #expect(report.refused.map(\.processIdentifier) == [11])
        #expect(report.skipped.map(\.processIdentifier) == [12])
        #expect(sleeper.sleeps == [GroupTerminator.hideSettleDelay])
    }
}
