import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

/// The hidden `--layout-observe` developer probe: inert without its variable, read-only with it.
@Suite("Layout observation probe")
@MainActor
struct LayoutObservationProbeTests {
    typealias Probe = LayoutObservationProbe
    typealias Instances = LayoutAccessibilityObserver<FakeAccessibilityReader>.RunningInstances

    private static let enabled = [Probe.environmentVariable: "1"]
    private static let editor = "com.example.editor"
    private static let viewer = "com.example.viewer"
    private static let display = LayoutDisplay(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805),
        backingScaleFactor: 2,
        isPrimary: true
    )

    // MARK: - Environment gate

    @Test(arguments: [[String: String](), ["CYBOKRON_LAYOUT_PROBE": "0"], ["CYBOKRON_LAYOUT_PROBE": "true"],
                      ["CYBOKRON_LAYOUT_PROBE": ""], ["CYBOKRON_LAYOUT_PROBE": " 1"], ["cybokron_layout_probe": "1"]])
    func withoutTheVariableTheOptionIsUnknown(environment: [String: String]) async {
        let runtime = Runtime()
        var probed = false
        var resolved = false
        let result = await DockGroupsCLI.run(
            arguments: [Probe.option, "com.apple.finder"],
            application: { resolved = true; return nil },
            runtime: runtime,
            environment: environment,
            layoutProbe: { _ in probed = true; return CLIResult(exitCode: 0, output: "probe", errors: "") }
        )
        #expect(result == CLIResult(exitCode: 2, output: "", errors: DockGroupsCLI.help))
        #expect(!probed && !resolved)
        #expect(runtime.urls.isEmpty && runtime.statusChecks == 0)
    }

    @Test func helpAndReadmeDoNotMentionTheProbe() throws {
        for text in [DockGroupsCLI.help, try String(contentsOf: RepositoryScript.root.appending(path: "README.md"), encoding: .utf8)] {
            #expect(!text.contains(Probe.option))
            #expect(!text.contains("layout-observe"))
            #expect(!text.contains(Probe.environmentVariable))
        }
    }

    @Test func enabledProbeRunsWithoutTheAppOrAURL() async {
        let runtime = Runtime()
        var resolved = false
        var received: [[String]] = []
        let result = await DockGroupsCLI.run(
            arguments: [Probe.option, Self.editor, Self.viewer],
            application: { resolved = true; return nil },
            runtime: runtime,
            environment: Self.enabled,
            layoutProbe: { received.append($0); return CLIResult(exitCode: 0, output: "{}\n", errors: "") }
        )
        #expect(result == CLIResult(exitCode: 0, output: "{}\n", errors: ""))
        #expect(received == [[Self.editor, Self.viewer]])
        #expect(!resolved && runtime.urls.isEmpty && runtime.statusChecks == 0)
    }

    @Test(arguments: [
        [Probe.option], [Probe.option, ""], [Probe.option, "com.example.a", "com.example.a"],
        [Probe.option, "/Applications/Safari.app"], [Probe.option, "https://example.com"],
        [Probe.option, "-x"], [Probe.option, ".hidden"], [Probe.option, "com.example.a b"],
        [Probe.option, "com.exämple.app"], [Probe.option, "com.example.a;rm"],
        [Probe.option, String(repeating: "a", count: 256)],
        [Probe.option] + (0...16).map { "com.example.app\($0)" },
    ])
    func malformedProbeArgumentsFailBeforeReading(arguments: [String]) async {
        var probed = false
        let result = await DockGroupsCLI.run(
            arguments: arguments, application: { nil }, runtime: Runtime(), environment: Self.enabled,
            layoutProbe: { _ in probed = true; return CLIResult(exitCode: 0, output: "", errors: "") }
        )
        #expect(result.exitCode == 2 && result.output.isEmpty)
        #expect(result.errors == Probe.usage)
        #expect(!probed)
    }

    @Test func otherCommandsAreUnchangedWhileTheProbeIsEnabled() async {
        let result = await DockGroupsCLI.run(arguments: ["--help"], application: { nil }, runtime: Runtime(), environment: Self.enabled)
        #expect(result == CLIResult(exitCode: 0, output: DockGroupsCLI.help, errors: ""))
        let misplaced = await DockGroupsCLI.run(
            arguments: ["status", Probe.option], application: { nil }, runtime: Runtime(), environment: Self.enabled,
            layoutProbe: { _ in Issue.record("probe ran"); return CLIResult(exitCode: 0, output: "", errors: "") }
        )
        #expect(misplaced.exitCode == 2 && misplaced.errors == DockGroupsCLI.help)
    }

    @Test func sixteenDistinctIdentifiersAreAccepted() {
        let identifiers = (0..<16).map { "com.example.app_\($0)-x" }
        #expect(Probe.bundleIdentifiers(arguments: [Probe.option] + identifiers) == identifiers)
    }

    // MARK: - Report

    @Test func grantedReportIsSortedJSONWithExplicitUnknowns() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2, nil])
        reader.addStandardWindow(1, frame: CGRect(x: -1200, y: 25, width: 800, height: 600.5))
        // A dialog whose size is unreadable and whose minimized state is not a boolean.
        reader.attributes[2] = [
            kAXRoleAttribute: .value(kAXWindowRole as CFString),
            kAXSubroleAttribute: .value(kAXDialogSubrole as CFString),
            kAXMinimizedAttribute: .value(NSNumber(value: 0)),
            kAXPositionAttribute: .value(FakeAccessibilityReader.point(CGPoint(x: 10, y: 20))),
        ]
        let clock = Clock()
        reader.onAttributeRead = { clock.advance(0.001) }
        let result = Self.run([Self.editor], reader: reader, instances: [Self.editor: .one(10)], clock: clock)

        #expect(result.exitCode == 0)
        let root = try Self.object(result.output)
        #expect(root["probe"] as? String == "layout-observe")
        #expect(root["formatVersion"] as? Int == 1)
        #expect(root["accessibilityPermission"] as? String == "granted")
        #expect(root["accessibilityPermissionAfterRead"] as? String == "granted")
        #expect(root["windowCoordinateSpace"] as? String == "accessibilityTopLeftPoints")
        #expect((root["system"] as? [String: Any])?["operatingSystemVersion"] as? String == "99.1.0")
        let limits = try #require(root["limits"] as? [String: Any])
        #expect(limits["appReadBudgetSeconds"] as? Int == 2 && limits["maximumWindowCount"] as? Int == 64)
        #expect(limits["messagingTimeoutSeconds"] as? Int == 1)

        let displays = try #require(root["displays"] as? [String: Any])
        #expect(displays["configurationAccepted"] as? Bool == true)
        #expect(displays["coordinateSpace"] as? String == "appKitBottomLeftPoints")
        let screen = try #require((displays["screens"] as? [[String: Any]])?.first)
        #expect(screen["primary"] as? Bool == true && screen["backingScaleFactor"] as? Int == 2)
        #expect(Self.rect(screen["visibleFrame"]) == [0, 70, 1440, 805])

        let apps = try #require(root["applications"] as? [[String: Any]])
        let app = try #require(apps.first)
        #expect(apps.count == 1)
        #expect(app["bundleIdentifier"] as? String == Self.editor)
        #expect(app["runningInstances"] as? String == "one")
        #expect(app["appRunningUnprotected"] as? String == "unknown")
        #expect(app["reportedWindowCount"] as? Int == 3)
        #expect(app["readWindowCount"] as? Int == 2)
        #expect(app["completeSnapshot"] as? String == "no")
        #expect(app["durationMilliseconds"] as? Int == 10) // 10 attribute reads at 1 ms each
        let windows = try #require(app["windows"] as? [[String: Any]])
        #expect(windows.count == 2)
        #expect(windows[0]["index"] as? Int == 0)
        #expect(Self.rect(windows[0]["topLeftFrame"]) == [-1200, 25, 800, 600.5])
        #expect(windows[0]["role"] as? String == "window" && windows[0]["subrole"] as? String == "standardWindow")
        #expect(windows[0]["minimized"] as? String == "no")
        #expect(windows[0]["unknownFields"] as? [String] == ["visible", "onCurrentSpace", "fullScreen", "identifiable"])
        #expect(windows[1]["topLeftFrame"] is NSNull)
        #expect(windows[1]["subrole"] as? String == "dialog")
        #expect(windows[1]["minimized"] as? String == "unknown")
        #expect(windows[1]["unknownFields"] as? [String]
            == ["topLeftFrame", "minimized", "visible", "onCurrentSpace", "fullScreen", "identifiable"])
        for window in windows {
            for field in ["visible", "onCurrentSpace", "fullScreen", "identifiable"] {
                #expect(window[field] as? String == "unknown")
            }
        }
        #expect(app["unknownFieldCount"] as? Int == 10)

        let summary = try #require(root["summary"] as? [String: Any])
        #expect(summary["applicationCount"] as? Int == 1)
        #expect(summary["reportedWindowCount"] as? Int == 3 && summary["readWindowCount"] as? Int == 2)
        #expect(summary["unknownFieldCount"] as? Int == 10)
        #expect(summary["totalDurationMilliseconds"] as? Int == 10)

        #expect(result.errors.contains("2 of 3 reported window(s) read; 10 unknown field(s); 10.0 ms total"))
        #expect(result.errors.contains("\(Self.editor): 2 of 3 window(s), snapshot no, 10 unknown, 10.0 ms"))
        // Reads only the observer's attributes; no title.
        #expect(Set(reader.attributeCalls.map(\.name)).isSubset(of: Set(LayoutAccessibilityObserver<FakeAccessibilityReader>.attributeNames)))
    }

    @Test func outputIsDeterministicWithSortedKeysAndExplicitNulls() throws {
        func output() -> String {
            let reader = FakeAccessibilityReader()
            reader.windowLists[10] = .value([1])
            reader.addStandardWindow(1)
            return Self.run([Self.editor, Self.viewer], reader: reader, instances: [Self.editor: .one(10), Self.viewer: .one(20)]).output
        }
        let first = output()
        #expect(first == output())
        #expect(first.hasSuffix("}\n"))
        // Keys of the top-level object, in order of appearance, are sorted.
        let keys = first.split(separator: "\n").filter { $0.hasPrefix("  \"") }
            .map { String($0.dropFirst(3).prefix { $0 != "\"" }) }
        #expect(keys == keys.sorted() && keys.count == 10)
        // The viewer's window list failed: its count is an explicit null, not an omitted key.
        let apps = try #require(Self.object(first)["applications"] as? [[String: Any]])
        #expect(apps.map { $0["bundleIdentifier"] as? String } == [Self.editor, Self.viewer])
        #expect(apps[1]["reportedWindowCount"] is NSNull)
        #expect(apps[1]["completeSnapshot"] as? String == "unknown")
        #expect(first.contains("\"reportedWindowCount\" : null"))
    }

    @Test func deniedPermissionReadsNothingAndExitsTwo() throws {
        let reader = FakeAccessibilityReader()
        reader.trusted = false
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let result = Self.run([Self.editor], reader: reader, instances: [Self.editor: .one(10)])
        #expect(result.exitCode == 2)
        #expect(reader.accessibilityCallCount == 0)
        let root = try Self.object(result.output)
        #expect(root["accessibilityPermission"] as? String == "denied")
        #expect(root["accessibilityPermissionAfterRead"] as? String == "denied")
        let app = try #require((root["applications"] as? [[String: Any]])?.first)
        #expect(app["reportedWindowCount"] is NSNull && (app["windows"] as? [Any])?.isEmpty == true)
        #expect(result.errors.contains("not granted") && result.errors.contains("no prompt"))
    }

    @Test func deniedTakesPrecedenceOverAMissingApp() {
        let reader = FakeAccessibilityReader()
        reader.trusted = false
        #expect(Self.run([Self.editor], reader: reader, instances: [:]).exitCode == 2)
    }

    @Test func accessTurnedOffDuringTheReadExitsTwo() throws {
        let lost = FakeAccessibilityReader()
        lost.windowLists[10] = .value([1])
        lost.addStandardWindow(1)
        let revoking = RevokingReader(lost)
        let revoked = LayoutObservationProbe.run(bundleIdentifiers: [Self.editor], sources: .init(
            reader: revoking, runningInstances: { _ in .one(10) }, displays: [Self.display], now: { 0 },
            operatingSystemVersion: "99.1.0", messagingTimeout: 1
        ))
        #expect(revoked.exitCode == 2)
        let root = try Self.object(revoked.output)
        #expect(root["accessibilityPermission"] as? String == "granted")
        #expect(root["accessibilityPermissionAfterRead"] as? String == "denied")
        #expect(revoked.errors.contains("turned off during the read"))
    }

    @Test(arguments: [
        (Instances.none, "none", "no running app"),
        (Instances.several, "several", "several running instances"),
        (Instances.unknown, "unknown", "running instances could not be looked up"),
    ])
    func anAppNotRunningExactlyOnceExitsThree(instances: Instances, name: String, message: String) throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let result = Self.run([Self.editor, Self.viewer], reader: reader, instances: [Self.editor: .one(10), Self.viewer: instances])
        #expect(result.exitCode == 3)
        #expect(result.errors.contains("error: \(Self.viewer): \(message)"))
        let apps = try #require(Self.object(result.output)["applications"] as? [[String: Any]])
        #expect(apps[0]["readWindowCount"] as? Int == 1)
        #expect(apps[1]["runningInstances"] as? String == name)
        #expect(apps[1]["reportedWindowCount"] is NSNull)
    }

    @Test func anUnresponsiveAppIsTimedOnItsOwnAndTheNextAppIsStillRead() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2])
        reader.windowLists[20] = .value([3])
        reader.addStandardWindow(1)
        reader.addStandardWindow(2)
        reader.addStandardWindow(3)
        reader.attributes[1]?[kAXRoleAttribute] = .failure(.unresponsive)
        let clock = Clock()
        reader.onAttributeRead = { [reader] in
            // The unresponsive answer costs the full messaging timeout; others 1 ms.
            clock.advance(reader.attributeCalls.last?.window == 1 ? 1 : 0.001)
        }
        let result = Self.run([Self.editor, Self.viewer], reader: reader, instances: [Self.editor: .one(10), Self.viewer: .one(20)], clock: clock)
        #expect(result.exitCode == 0)
        let apps = try #require(Self.object(result.output)["applications"] as? [[String: Any]])
        #expect(apps[0]["completeSnapshot"] as? String == "no" && apps[0]["readWindowCount"] as? Int == 0)
        #expect(apps[0]["durationMilliseconds"] as? Int == 1000)
        #expect(apps[1]["completeSnapshot"] as? String == "yes")
        #expect(apps[1]["durationMilliseconds"] as? Int == 5)
        let summary = try #require(Self.object(result.output)["summary"] as? [String: Any])
        #expect(summary["totalDurationMilliseconds"] as? Int == 1005)
        #expect(reader.attributeCalls.filter { $0.window == 2 }.isEmpty)
    }

    @Test func refusedDisplayConfigurationIsReported() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([])
        let result = LayoutObservationProbe.run(bundleIdentifiers: [Self.editor], sources: .init(
            reader: reader, runningInstances: { _ in .one(10) }, displays: [], now: { 0 },
            operatingSystemVersion: "99.1.0", messagingTimeout: 1
        ))
        let displays = try #require(Self.object(result.output)["displays"] as? [String: Any])
        #expect(displays["configurationAccepted"] as? Bool == false)
        #expect((displays["screens"] as? [Any])?.isEmpty == true)
        #expect(result.exitCode == 0)
    }

    @Test func outputHasNoProcessIdentifier() {
        let reader = FakeAccessibilityReader()
        reader.windowLists[4242] = .value([1])
        reader.addStandardWindow(1)
        let result = Self.run([Self.editor], reader: reader, instances: [Self.editor: .one(4242)])
        #expect(!result.output.contains("4242") && !result.errors.contains("4242"))
        #expect(!result.output.lowercased().contains("pid") && !result.output.contains("title"))
    }

    // MARK: - Source scan

    @Test func probeAndCLISourcesHaveNoWriteOrPromptSymbols() throws {
        let root = RepositoryScript.root
        let files = [
            "Sources/DockGroupsCore/Layout/LayoutObservationProbe.swift",
            "Sources/DockGroupsCore/Commands/DockGroupsCLI.swift",
            "Sources/CybokronDockGroupsCLI/CLI.swift",
        ]
        let forbidden = [
            "AXUIElementSetAttributeValue", "AXUIElementPerformAction", "AXUIElementPostKeyboardEvent",
            "AXValueCreate", "AXIsProcessTrustedWithOptions", "kAXTrustedCheckOptionPrompt", "kAXRaiseAction",
            "kAXPressAction", "kAXTitleAttribute", "activate(", "unhide(", "WindowRestorer",
            "x-apple.systempreferences", "Privacy_Accessibility", "CGEvent", "CGWindowList",
        ]
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token), "\(file) mentions \(token)")
            }
        }
        let probe = try String(contentsOf: root.appending(path: files[0]), encoding: .utf8)
        for token in ["NSWorkspace", "FileManager", "UserDefaults", "Process(", "write(to", "open("] {
            #expect(!probe.contains(token), "probe mentions \(token)")
        }
    }

    // MARK: - Helpers

    private static func run(
        _ identifiers: [String],
        reader: FakeAccessibilityReader,
        instances: [String: Instances],
        clock: Clock = Clock()
    ) -> CLIResult {
        LayoutObservationProbe.run(bundleIdentifiers: identifiers, sources: .init(
            reader: reader,
            runningInstances: { instances[$0] ?? .none },
            displays: [display],
            now: { clock.time },
            operatingSystemVersion: "99.1.0",
            messagingTimeout: 1
        ))
    }

    private static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func rect(_ value: Any?) -> [Double]? {
        guard let rect = value as? [String: Any] else { return nil }
        let values = ["x", "y", "width", "height"].compactMap { (rect[$0] as? NSNumber)?.doubleValue }
        return values.count == 4 ? values : nil
    }

    private final class Clock {
        var time: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { time += seconds }
    }

    /// Trusted at the first check, untrusted afterwards.
    private final class RevokingReader: LayoutAccessibilityReading {
        let base: FakeAccessibilityReader
        private var checks = 0
        init(_ base: FakeAccessibilityReader) { self.base = base }
        func isProcessTrusted() -> Bool { checks += 1; return checks <= 2 }
        func application(processIdentifier: pid_t) -> Int { base.application(processIdentifier: processIdentifier) }
        func windows(of application: Int) -> LayoutAccessibilityRead<[Int?]> { base.windows(of: application) }
        func attribute(_ name: String, of window: Int) -> LayoutAccessibilityRead<AnyObject> { base.attribute(name, of: window) }
    }

    @MainActor private final class Runtime: CLIRuntime {
        var statusChecks = 0
        var urls: [URL] = []
        func isRunning(_ application: CLIApplication) -> Bool { statusChecks += 1; return false }
        func dispatch(_ url: URL, to application: CLIApplication) async -> Bool { urls.append(url); return true }
    }
}
