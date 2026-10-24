import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Archived groups and templates: diagnostics")
struct GroupLibraryDiagnosticsTests {
    private func report(archivedGroupCount: Int? = nil, templateCount: Int? = nil) -> String {
        let groups = [DockGroup(name: "Work")]
        let info: DiagnosticsInfo
        if let archivedGroupCount, let templateCount {
            info = DiagnosticsInfo(
                app: .init(version: "0.9.0", build: "900", path: "/Applications/Cybokron Dock Groups.app"),
                system: .init(macOSVersion: "27.0.1", hardwareModel: "Mac15,6", architecture: "arm64"),
                isAccessibilityTrusted: false,
                isStatusItemShown: true,
                preferences: PopupPreferences(),
                updates: .init(lastCheckDate: nil, lastResult: "not checked"),
                groups: groups,
                archivedGroupCount: archivedGroupCount,
                templateCount: templateCount,
                recentErrors: []
            )
        } else {
            info = DiagnosticsInfo(
                app: .init(version: "0.9.0", build: "900", path: "/Applications/Cybokron Dock Groups.app"),
                system: .init(macOSVersion: "27.0.1", hardwareModel: "Mac15,6", architecture: "arm64"),
                isAccessibilityTrusted: false,
                isStatusItemShown: true,
                preferences: PopupPreferences(),
                updates: .init(lastCheckDate: nil, lastResult: "not checked"),
                groups: groups,
                recentErrors: []
            )
        }
        return DiagnosticsReport.text(for: info)
    }

    @Test func countsFollowTheGroupList() throws {
        let text = report(archivedGroupCount: 2, templateCount: 3)
        let groups = try #require(text.range(of: "== Groups =="))
        let archived = try #require(text.range(of: "Archived groups: 2"))
        let templates = try #require(text.range(of: "Templates: 3"))
        #expect(groups.upperBound < archived.lowerBound && archived.upperBound < templates.lowerBound)
        #expect(text.contains("- Work: 0 apps"))
    }

    @Test func withoutCountsBothAreZero() {
        let text = report()
        #expect(text.contains("Archived groups: 0"))
        #expect(text.contains("Templates: 0"))
    }
}
