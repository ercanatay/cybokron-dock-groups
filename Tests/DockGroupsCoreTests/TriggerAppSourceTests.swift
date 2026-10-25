import Foundation
import Testing

/// What the app's trigger code may and may not do (triggers spec §2.5, §4.2), read from its
/// sources: the app target isn't linked into the tests.
@Suite("Triggers: the app's wiring")
struct TriggerAppSourceTests {
    static func source(_ components: String...) throws -> String {
        let url = components.reduce(LocalizationTests.root.appending(path: "Sources")) { $0.appending(path: $1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every Swift file of the app target, by name.
    static func appSources() throws -> [String: String] {
        let folder = LocalizationTests.root.appending(components: "Sources", "CybokronDockGroups")
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var sources: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }

    /// The clock arms one timer, 1 second of tolerance (TS-1), and never polls.
    @Test func theClockArmsOneTimerWithASecondOfTolerance() throws {
        let clock = try Self.source("CybokronDockGroups", "Triggers", "TriggerSources.swift")
        #expect(clock.contains("static let tolerance: TimeInterval = 1"))
        #expect(clock.contains("timer.tolerance = Self.tolerance"))
        #expect(clock.contains("Timer(fire: due, interval: 0, repeats: false)"))
        #expect(!clock.contains("repeats: true"))
        #expect(!clock.contains("scheduledTimer"))
    }

    /// Only the main app's delegate creates the controller; an agent never evaluates, runs or
    /// registers anything.
    @Test func onlyTheMainAppRunsTriggers() throws {
        let sources = try Self.appSources()
        let creators = sources.filter { $0.value.contains("TriggerController(") }.keys.sorted()
        #expect(creators == ["AppDelegate.swift"])
        let agent = try Self.source("CybokronDockGroups", "Agent", "AgentAppDelegate.swift")
        for name in ["TriggerController", "LoginItem", "SMAppService", "TriggerCoordinator"] {
            #expect(!agent.contains(name), "the agent mentions \(name)")
        }
        let services = sources.filter { $0.value.contains("SMAppService") }.keys.sorted()
        #expect(services == ["LoginItem.swift"])
    }

    /// Open at Login changes only when the user clicks: `register` and `unregister` are in
    /// `LoginItem.set`, which only the Settings pane's switch and the editor's button call.
    @Test func openAtLoginIsOnlyEverTheUsersChoice() throws {
        let sources = try Self.appSources()
        let login = try #require(sources["LoginItem.swift"])
        #expect(login.components(separatedBy: "try service.register()").count == 2)
        #expect(login.components(separatedBy: "try service.unregister()").count == 2)
        let callers = sources.filter { $0.key != "LoginItem.swift" && $0.value.contains("loginItem.set(") }.keys.sorted()
        #expect(callers == ["TriggerEditorSheet.swift", "TriggersSettingsView.swift"])
    }

    /// What triggers do goes through Start, Finish, Open All and the popup — as
    /// `TransitionTrigger.automation`, without a question — and nothing else (T-S1, T-S3).
    @Test func triggersOnlyStartFinishOpenOrShow() throws {
        let delegate = try Self.source("CybokronDockGroups", "App", "AppDelegate.swift")
        let start = try #require(delegate.range(of: "private lazy var automation = AutomationBridge("))
        let end = try #require(delegate.range(of: "/// The templates (`templates.json`)", range: start.upperBound..<delegate.endIndex))
        let bridge = String(delegate[start.lowerBound..<end.lowerBound])
        #expect(bridge.contains("self.switcher.start(id, trigger: trigger)"))
        #expect(bridge.contains("self.switcher.finish(id, trigger: trigger, showsPrevious: showsPrevious)"))
        #expect(bridge.contains("self.launcher.openAll(group)"))
        #expect(bridge.contains("popupController.show(groupID: group.id)"))
        for word in ["quit", "Quit", "confirm", "terminate", "forceTerminate", "closeAll"] {
            #expect(!bridge.contains(word), "the automation bridge mentions \(word)")
        }
        let triggers = try Self.source("CybokronDockGroups", "Triggers", "TriggerController.swift")
        for call in [".quit", "terminate(", "confirm:", "quitRequests"] {
            #expect(!triggers.contains(call), "TriggerController calls \(call)")
        }
    }

    /// A relaunch for an update or a language change leaves the quiet-launch marker first.
    @Test func relaunchesMarkTheNextLaunchQuiet() throws {
        let updater = try Self.source("CybokronDockGroups", "Updates", "AutoUpdater.swift")
        let marker = try #require(updater.range(of: "beforeRelaunch()\n"))
        let run = try #require(updater.range(of: "try process.run()", range: marker.upperBound..<updater.endIndex))
        #expect(marker.upperBound <= run.lowerBound)
        let language = try Self.source("CybokronDockGroups", "Support", "AppLanguageSupport.swift")
        #expect(language.contains("beforeRelaunch?()\n        do {\n            try process.run()"))
        let delegate = try Self.source("CybokronDockGroups", "App", "AppDelegate.swift")
        #expect(delegate.contains("updater.beforeRelaunch = { [weak self] in self?.triggers.markQuietRelaunch() }"))
        #expect(delegate.contains("AppLanguageSupport.beforeRelaunch = { [weak self] in self?.triggers.markQuietRelaunch() }"))
    }

    /// Links and Siri or Shortcuts requests during the launch make it quiet (TS-4).
    @Test func requestsDuringTheLaunchAreNoted() throws {
        let delegate = try Self.source("CybokronDockGroups", "App", "AppDelegate.swift")
        let handle = try #require(delegate.range(of: "private func handle(_ url: URL) {"))
        #expect(delegate[handle.upperBound...].prefix(200).contains("triggers.noteRequest()"))
        for intent in ["func launchAll(", "func start(_ group: DockGroup, confirm:", "func finish(_ group: DockGroup, confirm:", "func showPopup(forGroup id:"] {
            let range = try #require(delegate.range(of: intent), "no \(intent)")
            #expect(delegate[range.upperBound...].prefix(300).contains("triggers.noteRequest()"), "\(intent) doesn't note the request")
        }
    }
}
