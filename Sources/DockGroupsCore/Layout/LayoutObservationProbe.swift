import Foundation

// Developer probe for the Accessibility experiment in `window-layouts-and-cli-spec.md` §5,
// described in `docs/design/window-layout-probe.md`. Not a user feature: the CLI runs it only when
// `CYBOKRON_LAYOUT_PROBE=1` is set, and otherwise treats `--layout-observe` as an unknown option.
// Its help text, the README and the app never mention it.
//
// It reads only, through `LayoutAccessibilityObserver` and `LayoutScreenProvider` unchanged: no
// attribute is set, no action performed, no app activated or raised, no permission requested and
// no settings pane opened. Window titles are never read. Its output holds the requested bundle
// identifiers, window geometry and timings; no process identifier, path or window title.

/// The hidden `--layout-observe` developer probe.
public enum LayoutObservationProbe {
    /// The variable that enables the probe; only the exact value `1` does.
    public static let environmentVariable = "CYBOKRON_LAYOUT_PROBE"
    /// The CLI option, accepted only while the probe is enabled.
    public static let option = "--layout-observe"
    /// Bundle identifiers per run at most.
    static let maximumApplicationCount = 16
    /// The output format; changes when a field changes meaning.
    static let formatVersion = 1
    /// The longest time spent on one app's windows (passed to the observer).
    static let appReadBudget: TimeInterval = 2

    static let usage = """
        Usage: CYBOKRON_LAYOUT_PROBE=1 cybokrondockgroups --layout-observe <bundle id> [<bundle id> ...]

        Developer probe: reads the windows of up to 16 running apps without changing anything and
        prints JSON on stdout and a summary on stderr. It never asks for Accessibility access.
        Exit codes: 0 = observed; 2 = bad arguments, or Accessibility access is not granted;
                    3 = an app is not running exactly once.

        """

    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentVariable] == "1"
    }

    /// The bundle identifiers of a well-formed `--layout-observe` invocation: between one and
    /// `maximumApplicationCount` distinct plain bundle identifiers.
    static func bundleIdentifiers(arguments: [String]) -> [String]? {
        guard arguments.first == option else { return nil }
        let identifiers = Array(arguments.dropFirst())
        guard (1...maximumApplicationCount).contains(identifiers.count),
              Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy(isPlainBundleIdentifier)
        else { return nil }
        return identifiers
    }

    /// ASCII letters, digits, `.`, `-` and `_`, not starting with `-` or `.`, at most 255 characters.
    static func isPlainBundleIdentifier(_ identifier: String) -> Bool {
        guard let first = identifier.first, first != "-", first != ".", identifier.utf8.count <= 255 else { return false }
        return identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    // MARK: - Running

    /// What one run reads from. The system run uses the Accessibility reader, `NSRunningApplication`
    /// and `NSScreen`; tests supply fakes.
    struct Sources<Reader: LayoutAccessibilityReading> {
        let reader: Reader
        let runningInstances: (String) -> LayoutAccessibilityObserver<Reader>.RunningInstances
        /// The displays, read once before any window.
        let displays: [LayoutDisplay]
        /// A monotonic clock in seconds.
        let now: () -> TimeInterval
        let operatingSystemVersion: String
        let messagingTimeout: Double
    }

    /// Runs the probe against the current system. Synchronous: Accessibility calls block, each
    /// bounded by the messaging timeout and each app by the read budget.
    @MainActor
    public static func runSystem(bundleIdentifiers: [String]) -> CLIResult {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return run(bundleIdentifiers: bundleIdentifiers, sources: Sources(
            reader: SystemLayoutAccessibilityReader(),
            runningInstances: LayoutAccessibilityObserver<SystemLayoutAccessibilityReader>.systemRunningInstances,
            displays: LayoutScreenProvider.currentDisplays(),
            now: { ProcessInfo.processInfo.systemUptime },
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            messagingTimeout: Double(SystemLayoutAccessibilityReader.messagingTimeout)
        ))
    }

    static func run<Reader>(bundleIdentifiers: [String], sources: Sources<Reader>) -> CLIResult {
        let start = sources.now()
        let observer = LayoutAccessibilityObserver(
            reader: sources.reader,
            runningInstances: sources.runningInstances,
            appReadBudget: appReadBudget,
            now: sources.now
        )
        let permission = observer.accessibilityPermission()
        var applications: [ApplicationReport] = []
        for identifier in bundleIdentifiers {
            let instances = sources.runningInstances(identifier)
            let appStart = sources.now()
            // One app per call, so each app's time is measured on its own.
            let observation = observer.observeWindows(bundleIdentifiers: [identifier]).first
                ?? LayoutWindowObservation(bundleIdentifier: identifier, appRunningUnprotected: .unknown,
                                           reportedWindowCount: nil, windows: [])
            applications.append(ApplicationReport(
                instances: instances, observation: observation, duration: sources.now() - appStart
            ))
        }
        let permissionAfterRead = observer.accessibilityPermission()
        let total = sources.now() - start

        let report = Report(
            permission: permission,
            permissionAfterRead: permissionAfterRead,
            displays: sources.displays,
            applications: applications,
            duration: total,
            operatingSystemVersion: sources.operatingSystemVersion,
            messagingTimeout: sources.messagingTimeout
        )
        return CLIResult(exitCode: report.exitCode, output: report.json(), errors: report.summary())
    }

    // MARK: - Report

    struct ApplicationReport {
        /// What was known about the app's running instances before its windows were read.
        enum Instances: String {
            case none, one, several, unknown
        }

        let instances: Instances
        let observation: LayoutWindowObservation
        let duration: TimeInterval

        init<Reader>(instances: LayoutAccessibilityObserver<Reader>.RunningInstances,
                     observation: LayoutWindowObservation, duration: TimeInterval) {
            switch instances {
            case .none: self.instances = .none
            case .one: self.instances = .one
            case .several: self.instances = .several
            case .unknown: self.instances = .unknown
            }
            self.observation = observation
            self.duration = duration
        }

        var unknownFieldCount: Int { observation.windows.reduce(0) { $0 + Report.unknownFields(of: $1).count } }
    }

    struct Report {
        let permission: LayoutAccessibilityPermission
        let permissionAfterRead: LayoutAccessibilityPermission
        let displays: [LayoutDisplay]
        let applications: [ApplicationReport]
        let duration: TimeInterval
        let operatingSystemVersion: String
        let messagingTimeout: Double

        var exitCode: Int32 {
            if permission != .granted || permissionAfterRead != .granted { return 2 }
            if applications.contains(where: { $0.instances != .one }) { return 3 }
            return 0
        }

        /// The window fields that are `null` or `"unknown"`, in output order.
        static func unknownFields(of window: LayoutWindowObservation.Window) -> [String] {
            var names: [String] = []
            if window.topLeftFrame == nil { names.append("topLeftFrame") }
            if window.role == .unknown { names.append("role") }
            if window.subrole == .unknown { names.append("subrole") }
            if window.minimized == .unknown { names.append("minimized") }
            if window.visible == .unknown { names.append("visible") }
            if window.onCurrentSpace == .unknown { names.append("onCurrentSpace") }
            if window.fullScreen == .unknown { names.append("fullScreen") }
            if window.identifiable == .unknown { names.append("identifiable") }
            return names
        }

        static func milliseconds(_ seconds: TimeInterval) -> ProbeJSON {
            guard seconds.isFinite else { return .null }
            return .number((max(0, seconds) * 10_000).rounded() / 10)
        }

        static func rect(_ rect: CGRect?) -> ProbeJSON {
            guard let rect else { return .null }
            return .object([
                "x": .number(Double(rect.origin.x)), "y": .number(Double(rect.origin.y)),
                "width": .number(Double(rect.size.width)), "height": .number(Double(rect.size.height)),
            ])
        }

        func json() -> String {
            let readWindows = applications.reduce(0) { $0 + $1.observation.windows.count }
            let reportedWindows = applications.reduce(0) { $0 + ($1.observation.reportedWindowCount ?? 0) }
            let root: ProbeJSON = .object([
                "probe": .string("layout-observe"),
                "formatVersion": .number(Double(LayoutObservationProbe.formatVersion)),
                "system": .object(["operatingSystemVersion": .string(operatingSystemVersion)]),
                "accessibilityPermission": .string(permission.rawValue),
                "accessibilityPermissionAfterRead": .string(permissionAfterRead.rawValue),
                "limits": .object([
                    "messagingTimeoutSeconds": .number(messagingTimeout),
                    "appReadBudgetSeconds": .number(LayoutObservationProbe.appReadBudget),
                    "maximumWindowCount": .number(Double(LayoutAccessibilityObserver<SystemLayoutAccessibilityReader>.maximumWindowCount)),
                ]),
                "displays": .object([
                    "coordinateSpace": .string("appKitBottomLeftPoints"),
                    "configurationAccepted": .bool(LayoutDisplayConfiguration(displays: displays) != nil),
                    "screens": .array(displays.map { display in
                        .object([
                            "frame": Self.rect(display.frame),
                            "visibleFrame": Self.rect(display.visibleFrame),
                            "backingScaleFactor": .number(Double(display.backingScaleFactor)),
                            "primary": .bool(display.isPrimary),
                        ])
                    }),
                ]),
                "windowCoordinateSpace": .string("accessibilityTopLeftPoints"),
                "applications": .array(applications.map(Self.application)),
                "summary": .object([
                    "applicationCount": .number(Double(applications.count)),
                    "reportedWindowCount": .number(Double(reportedWindows)),
                    "readWindowCount": .number(Double(readWindows)),
                    "unknownFieldCount": .number(Double(applications.reduce(0) { $0 + $1.unknownFieldCount })),
                    "totalDurationMilliseconds": Self.milliseconds(duration),
                ]),
            ])
            return root.serialized() + "\n"
        }

        static func application(_ application: ApplicationReport) -> ProbeJSON {
            let observation = application.observation
            return .object([
                "bundleIdentifier": .string(observation.bundleIdentifier),
                "runningInstances": .string(application.instances.rawValue),
                "appRunningUnprotected": .string(observation.appRunningUnprotected.rawValue),
                "reportedWindowCount": observation.reportedWindowCount.map { .number(Double($0)) } ?? .null,
                "readWindowCount": .number(Double(observation.windows.count)),
                "completeSnapshot": .string(observation.completeSnapshot.rawValue),
                "unknownFieldCount": .number(Double(application.unknownFieldCount)),
                "durationMilliseconds": milliseconds(application.duration),
                "windows": .array(observation.windows.enumerated().map { index, window in
                    .object([
                        "index": .number(Double(index)),
                        "topLeftFrame": rect(window.topLeftFrame),
                        "role": .string(window.role.rawValue),
                        "subrole": .string(window.subrole.rawValue),
                        "minimized": .string(window.minimized.rawValue),
                        "visible": .string(window.visible.rawValue),
                        "onCurrentSpace": .string(window.onCurrentSpace.rawValue),
                        "fullScreen": .string(window.fullScreen.rawValue),
                        "identifiable": .string(window.identifiable.rawValue),
                        "unknownFields": .array(unknownFields(of: window).map(ProbeJSON.string)),
                    ])
                }),
            ])
        }

        func summary() -> String {
            var lines: [String] = []
            if permission != .granted {
                lines.append("layout-observe: Accessibility access is not granted to this process or the app that "
                    + "started it (\(permission.rawValue)); no window was read and no prompt was shown.")
            } else if permissionAfterRead != .granted {
                lines.append("layout-observe: Accessibility access was turned off during the read; later reads stopped.")
            }
            for application in applications {
                let identifier = application.observation.bundleIdentifier
                switch application.instances {
                case .none: lines.append("layout-observe: error: \(identifier): no running app with this bundle identifier.")
                case .several: lines.append("layout-observe: error: \(identifier): several running instances; not read.")
                case .unknown: lines.append("layout-observe: error: \(identifier): running instances could not be looked up.")
                case .one: break
                }
            }
            let readWindows = applications.reduce(0) { $0 + $1.observation.windows.count }
            let reportedWindows = applications.reduce(0) { $0 + ($1.observation.reportedWindowCount ?? 0) }
            let unknown = applications.reduce(0) { $0 + $1.unknownFieldCount }
            lines.append("layout-observe: permission \(permission.rawValue); \(applications.count) app(s); "
                + "\(readWindows) of \(reportedWindows) reported window(s) read; \(unknown) unknown field(s); "
                + "\(Self.format(duration)) total")
            for application in applications {
                let observation = application.observation
                let count = observation.reportedWindowCount.map(String.init) ?? "unknown"
                lines.append("  \(observation.bundleIdentifier): \(observation.windows.count) of \(count) window(s), "
                    + "snapshot \(observation.completeSnapshot.rawValue), \(application.unknownFieldCount) unknown, "
                    + Self.format(application.duration))
            }
            return lines.joined(separator: "\n") + "\n"
        }

        static func format(_ seconds: TimeInterval) -> String {
            guard seconds.isFinite else { return "unknown ms" }
            return String(format: "%.1f ms", max(0, seconds) * 1000)
        }
    }
}

/// A JSON value written with sorted keys, so equal reports serialize identically. `null` is
/// written explicitly; nothing is omitted.
indirect enum ProbeJSON: Encodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ProbeJSON])
    case object([String: ProbeJSON])

    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            // Integral values print without a fraction; anything non-finite is unknown.
            if !value.isFinite {
                try container.encodeNil()
            } else if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let members):
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in members { try container.encode(value, forKey: Key(stringValue: key)) }
        }
    }

    func serialized() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
