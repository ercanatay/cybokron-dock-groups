import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    private func info(
        groups: [DockGroup] = [],
        errors: [String] = [],
        preferences: PopupPreferences = PopupPreferences()
    ) -> DiagnosticsInfo {
        DiagnosticsInfo(
            app: .init(version: "0.5.3", build: "1", path: "/Users/jane/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "Version 15.1 (Build 24B83)", hardwareModel: "Mac15,6", architecture: "arm64"),
            isAccessibilityTrusted: true,
            isStatusItemShown: true,
            preferences: preferences,
            updates: .init(
                lastCheckDate: Date(timeIntervalSince1970: 1_800_000_000),
                lastResult: "Up to date (v0.5.3)",
                offeredVersion: nil,
                skippedVersion: "0.5.2"
            ),
            groups: groups,
            recentErrors: errors,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
    }

    @Test func reportHasEverySectionInOrder() {
        let text = DiagnosticsReport.text(for: info(), homeDirectory: "/Users/jane")
        let positions = DiagnosticsReport.Section.allCases.map { section in
            text.range(of: "== \(section.rawValue) ==")?.lowerBound
        }
        #expect(positions.allSatisfy { $0 != nil })
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted())
        #expect(text.hasPrefix("Cybokron Dock Groups Diagnostics\n"))
        #expect(text.contains("Version: 0.5.3 (build 1)"))
        #expect(text.contains("Model: Mac15,6"))
        #expect(text.contains("Accessibility: granted"))
        #expect(text.contains("Last check: 2027-01-15T08:00:00Z"))
        #expect(text.contains("Skipped version: 0.5.2"))
        #expect(text.contains("Offered version: none"))
    }

    @Test func settingsAreSummarized() {
        var preferences = PopupPreferences()
        preferences.anchor = .dockIcon
        preferences.columns = .fixed(3)
        preferences.maxRows = 2
        preferences.showsTitles = false
        preferences.usesFreeLayout = true
        preferences.showsMostUsed = false
        preferences.automaticallyChecksForUpdates = false

        let text = DiagnosticsReport.text(for: info(preferences: preferences), homeDirectory: "/Users/jane")

        #expect(text.contains("Popup position: above the clicked icon"))
        #expect(text.contains("Columns: 3"))
        #expect(text.contains("Max rows: 2"))
        #expect(text.contains("App names under icons: off"))
        #expect(text.contains("Free Layout: on"))
        #expect(text.contains("Most Used: off"))
        #expect(text.contains("Automatic checks: off"))
    }

    @Test func groupsShowNamesAndCountsButNoApps() {
        let apps = [
            AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            AppReference(bundleIdentifier: "/Users/jane/Tools/Secret.app", name: "Secret Tool", path: "/Users/jane/Tools/Secret.app"),
        ]
        let groups = [
            DockGroup(name: "Work", apps: apps),
            DockGroup(name: "Empty", isStandalone: true),
        ]

        let text = DiagnosticsReport.text(for: info(groups: groups), homeDirectory: "/Users/jane")

        #expect(text.contains("2 groups, 2 apps"))
        #expect(text.contains("- Work: 2 apps"))
        #expect(text.contains("- Empty: 0 apps, standalone"))
        for secret in ["Safari", "com.apple.Safari", "Secret Tool", "/Users/jane/Tools", "/Applications/Safari.app"] {
            #expect(!text.contains(secret), "\(secret) leaked into the report")
        }
    }

    @Test func appLocationIsKeptButHomeIsRedactedInErrors() {
        let errors = (1...12).map { "Error \($0): couldn't read /Users/jane/Library/x.json" }

        let text = DiagnosticsReport.text(for: info(errors: errors), homeDirectory: "/Users/jane/")

        // The app's own location is the user's own business and helps support.
        #expect(text.contains("Location: /Users/jane/Applications/Cybokron Dock Groups.app"))
        #expect(text.contains("Error 12: couldn't read ~/Library/x.json"))
        // Only the latest ten errors.
        #expect(!text.contains("Error 2:"))
        #expect(text.contains("Error 3:"))
        let errorSection = text.components(separatedBy: "== Recent Errors ==").last ?? ""
        #expect(!errorSection.contains("/Users/jane"))
    }

    @Test func noErrorsSaysSo() {
        let text = DiagnosticsReport.text(for: info(), homeDirectory: "/Users/jane")
        #expect(text.contains("None logged since the app started"))
    }

    @Test func redactionLeavesOtherPathsAlone() {
        #expect(DiagnosticsReport.redactingHome(in: "/Users/jane/a and /Users/janet/b", homeDirectory: "/Users/jane")
            == "~/a and /Users/janet/b")
        #expect(DiagnosticsReport.redactingHome(in: "in /Users/jane: denied", homeDirectory: "/Users/jane")
            == "in ~: denied")
        #expect(DiagnosticsReport.redactingHome(in: "/tmp/x", homeDirectory: "/Users/jane") == "/tmp/x")
        #expect(DiagnosticsReport.redactingHome(in: "/tmp/x", homeDirectory: "/") == "/tmp/x")
    }

    @Test func fileNameIsSafe() {
        let name = DiagnosticsReport.fileName(for: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("Cybokron Dock Groups Diagnostics "))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains("/") && !name.contains(":"))
    }

    @Test func currentSystemHasAModel() {
        let system = DiagnosticsInfo.SystemDetails.current()
        #expect(!system.hardwareModel.isEmpty)
        #expect(!system.macOSVersion.isEmpty)
    }
}
