import Foundation

/// What Settings → Diagnostics puts into its report: facts about the app, the Mac and the user's
/// setup that help with a support request or a GitHub issue.
///
/// Group names and app counts are included, but never the apps themselves (names, bundle
/// identifiers or paths) — see `DiagnosticsReport.text(for:)`.
public struct DiagnosticsInfo: Sendable {
    public struct AppDetails: Sendable {
        /// `CFBundleShortVersionString`, e.g. "0.5.3".
        public var version: String
        /// `CFBundleVersion`.
        public var build: String
        /// Where the running app is, e.g. "/Applications/Cybokron Dock Groups.app".
        public var path: String

        public init(version: String, build: String, path: String) {
            self.version = version
            self.build = build
            self.path = path
        }
    }

    public struct SystemDetails: Sendable {
        /// e.g. "Version 15.1 (Build 24B83)".
        public var macOSVersion: String
        /// The hardware model identifier (`hw.model`), e.g. "Mac15,6".
        public var hardwareModel: String
        /// The CPU architecture the app runs as, e.g. "arm64".
        public var architecture: String

        public init(macOSVersion: String, hardwareModel: String, architecture: String) {
            self.macOSVersion = macOSVersion
            self.hardwareModel = hardwareModel
            self.architecture = architecture
        }

        /// This Mac.
        public static func current() -> SystemDetails {
            SystemDetails(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                hardwareModel: sysctlString("hw.model") ?? "unknown",
                architecture: currentArchitecture
            )
        }

        private static var currentArchitecture: String {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    public struct UpdateDetails: Sendable {
        /// When the latest update check finished, `nil` if never.
        public var lastCheckDate: Date?
        /// What that check found, in a few words (e.g. "Up to date (v0.5.3)").
        public var lastResult: String
        /// The newer version the updater offers, if any.
        public var offeredVersion: String?
        /// The version the user chose to skip, if any.
        public var skippedVersion: String?

        public init(lastCheckDate: Date?, lastResult: String, offeredVersion: String? = nil, skippedVersion: String? = nil) {
            self.lastCheckDate = lastCheckDate
            self.lastResult = lastResult
            self.offeredVersion = offeredVersion
            self.skippedVersion = skippedVersion
        }
    }

    public var app: AppDetails
    public var system: SystemDetails
    /// Whether the app has Accessibility access (`AXIsProcessTrusted`).
    public var isAccessibilityTrusted: Bool
    /// Whether the menu bar item is on screen.
    public var isStatusItemShown: Bool
    public var preferences: PopupPreferences
    public var updates: UpdateDetails
    /// The user's groups; only their names, app counts and whether they're standalone are reported.
    public var groups: [DockGroup]
    /// The latest error messages the app logged, oldest first.
    public var recentErrors: [String]
    public var generatedAt: Date

    public init(
        app: AppDetails,
        system: SystemDetails,
        isAccessibilityTrusted: Bool,
        isStatusItemShown: Bool,
        preferences: PopupPreferences,
        updates: UpdateDetails,
        groups: [DockGroup],
        recentErrors: [String],
        generatedAt: Date = Date()
    ) {
        self.app = app
        self.system = system
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isStatusItemShown = isStatusItemShown
        self.preferences = preferences
        self.updates = updates
        self.groups = groups
        self.recentErrors = recentErrors
        self.generatedAt = generatedAt
    }
}

/// Turns `DiagnosticsInfo` into the plain-text report the user copies or saves.
public enum DiagnosticsReport {
    /// How many logged errors the report lists at most.
    public static let maximumErrorCount = 10

    /// The section titles, in report order.
    public enum Section: String, CaseIterable, Sendable {
        case app = "App"
        case system = "System"
        case permissions = "Permissions"
        case settings = "Settings"
        case updates = "Updates"
        case groups = "Groups"
        case recentErrors = "Recent Errors"
    }

    /// The report. `homeDirectory` is replaced by "~" in logged error messages, which may mention
    /// the user's files; the app's own path is kept as it is.
    public static func text(for info: DiagnosticsInfo, homeDirectory: String = NSHomeDirectory()) -> String {
        var lines: [String] = []
        lines.append("Cybokron Dock Groups Diagnostics")
        lines.append("Generated: \(timestamp(info.generatedAt))")

        section(.app, into: &lines)
        lines.append("Version: \(info.app.version) (build \(info.app.build))")
        lines.append("Location: \(info.app.path)")

        section(.system, into: &lines)
        lines.append("macOS: \(info.system.macOSVersion)")
        lines.append("Model: \(info.system.hardwareModel)")
        lines.append("Architecture: \(info.system.architecture)")

        section(.permissions, into: &lines)
        lines.append("Accessibility: \(info.isAccessibilityTrusted ? "granted" : "not granted")")
        lines.append("Menu bar item: \(info.isStatusItemShown ? "shown" : "not shown")")

        let preferences = info.preferences
        section(.settings, into: &lines)
        lines.append("Popup position: \(describe(preferences.anchor))")
        lines.append("Columns: \(describe(preferences.columns))")
        lines.append("Max rows: \(preferences.maxRows)")
        lines.append("App names under icons: \(onOff(preferences.showsTitles))")
        lines.append("Free Layout: \(onOff(preferences.usesFreeLayout))")
        lines.append("Most Used: \(onOff(preferences.showsMostUsed)) (\(preferences.mostUsedLimit) apps)")
        lines.append("Theme: \(preferences.theme.rawValue), frosted glass \(onOff(preferences.usesFrostedGlass))")
        lines.append("Global shortcuts: \(onOff(preferences.shortcutsEnabled))")
        lines.append("Standalone Dock menus: \(onOff(preferences.showsStandaloneDockMenus))")
        lines.append("Restore windows of running apps: \(onOff(preferences.restoresWindowsOfRunningApps))")

        let updates = info.updates
        section(.updates, into: &lines)
        lines.append("Automatic checks: \(onOff(preferences.automaticallyChecksForUpdates))")
        lines.append("Last check: \(updates.lastCheckDate.map(timestamp) ?? "never")")
        lines.append("Last result: \(updates.lastResult)")
        lines.append("Offered version: \(updates.offeredVersion ?? "none")")
        if let skipped = updates.skippedVersion {
            lines.append("Skipped version: \(skipped)")
        }

        section(.groups, into: &lines)
        let appCount = info.groups.reduce(0) { $0 + $1.apps.count }
        lines.append("\(info.groups.count) group\(info.groups.count == 1 ? "" : "s"), \(appCount) app\(appCount == 1 ? "" : "s")")
        for group in info.groups {
            let count = "\(group.apps.count) app\(group.apps.count == 1 ? "" : "s")"
            lines.append("- \(group.name): \(count)\(group.isStandalone ? ", standalone" : "")")
        }

        section(.recentErrors, into: &lines)
        let errors = info.recentErrors.suffix(maximumErrorCount)
        if errors.isEmpty {
            lines.append("None logged since the app started")
        } else {
            lines.append(contentsOf: errors.map { redactingHome(in: $0, homeDirectory: homeDirectory) })
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` with the home folder's path replaced by "~" wherever it appears as a whole path
    /// component (so "/Users/jane" doesn't touch "/Users/janet").
    public static func redactingHome(in text: String, homeDirectory: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard home.count > 1 else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[\s"'”’),:;])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text.replacingOccurrences(of: home, with: "~")
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "~")
    }

    /// A file name for the saved report, e.g. "Cybokron Dock Groups Diagnostics 2026-10-18.txt".
    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Cybokron Dock Groups Diagnostics \(formatter.string(from: date)).txt"
    }

    private static func section(_ section: Section, into lines: inout [String]) {
        lines.append("")
        lines.append("== \(section.rawValue) ==")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func describe(_ anchor: PopupAnchor) -> String {
        switch anchor {
        case .dockCenter: return "centered over the Dock"
        case .dockIcon: return "above the clicked icon"
        }
    }

    private static func describe(_ columns: PopupColumns) -> String {
        switch columns {
        case .auto: return "auto"
        case .fixed(let count): return "\(count)"
        }
    }
}
