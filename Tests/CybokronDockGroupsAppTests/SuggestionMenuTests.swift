import AppKit
import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

private func item(_ name: String) -> GroupItem {
    GroupItem(bundleIdentifier: "com.example.\(name.lowercased())", name: name, path: "/Applications/\(name).app")
}

private func plan(_ names: [String], group: UUID? = nil, weakest: Int = 14) -> SuggestionPlan {
    SuggestionPlan(kind: group == nil ? .newGroup : .addToGroup, apps: names.map(item), group: group, weakestPairCount: weakest, totalPairCount: weakest)
}

/// The menu bar menu's Suggestions rows and Settings' status line (local-suggestions.md §4.1, §2.4).
@Suite("Suggestions menu and settings")
@MainActor
struct SuggestionMenuTests {
    @Test func rowsNameTheAppsAndSayReview() {
        let design = UUID()
        let rows = SuggestionMenuRow.rows(
            for: [plan(["Xcode", "Simulator", "Figma", "Notes"]), plan(["Figma"], group: design), plan(["A", "B", "C"])],
            groupName: { $0 == design ? "Design" : nil }
        )
        let items = StatusBarController.suggestionItems(for: rows, target: nil, action: nil)
        #expect(items.map(\.title) == [
            "New group: Xcode, Simulator, Figma +1 — Review…",
            "Add Figma to “Design” — Review…",
            "New group: A, B, C — Review…",
        ])
        #expect(items.first?.toolTip == "Opened together 14 times in the last weeks. Nothing is created until you review it.")
        #expect((items.first?.representedObject as? SuggestionMenuItemPayload)?.plan == rows.first?.plan)
    }

    @Test func atMostThreeItemsAndNoneWithoutRows() {
        let rows = SuggestionMenuRow.rows(for: (0..<5).map { plan(["A\($0)", "B\($0)", "C\($0)"]) }, groupName: { _ in nil })
        #expect(StatusBarController.suggestionItems(for: rows, target: nil, action: nil).count == 3)
        #expect(StatusBarController.suggestionItems(for: [], target: nil, action: nil).isEmpty)
    }

    @Test func tooltipsCountOnly() {
        let rows = SuggestionMenuRow.rows(for: [plan(["Xcode", "Simulator", "Figma"], weakest: 6)], groupName: { _ in nil })
        let tooltip = StatusBarController.suggestionItems(for: rows, target: nil, action: nil).first?.toolTip ?? ""
        #expect(!tooltip.contains("com.example"))
        #expect(!tooltip.contains("Xcode"))
    }

    @Test func statusLines() {
        typealias View = MostUsedSettingsView
        #expect(View.statusText(.off) == "Off")
        #expect(View.statusText(.needsMostUsed) == "Paused while Most Used is off")
        #expect(View.statusText(.watching(activeDays: 3, of: 5)) == "Watching: 3 of 5 days")
        #expect(View.statusText(.none) == "No suggestions right now")
        #expect(View.statusText(.available(1)) == "1 suggestion")
        #expect(View.statusText(.available(2)) == "2 suggestions")
    }
}
