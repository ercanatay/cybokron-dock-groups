import Foundation

/// How long a suggestion the user turned down stays away (design local-suggestions.md §3.6, D9).
public enum SuggestionSnooze: String, CaseIterable, Hashable, Sendable {
    /// "Not now", and cancelling the review sheet: 7 days.
    case week
    /// "Not now" for a month: 30 days.
    case month
    /// "Don't suggest this again".
    case forever

    /// The end of the snooze from `now`; `nil` for never again.
    public func until(from now: Date) -> Date? {
        switch self {
        case .week: now.addingTimeInterval(SuggestionPlanner.shortSnooze)
        case .month: now.addingTimeInterval(SuggestionPlanner.longSnooze)
        case .forever: nil
        }
    }
}

/// What Settings → Most Used → Suggestions says about them (§2.4).
public enum SuggestionStatus: Equatable, Sendable {
    /// Suggestions are off.
    case off
    /// Suggestions are on, but Most Used is off, so they're silent.
    case needsMostUsed
    /// Still watching: this many active days of `SuggestionPlanner.minimumActiveDays`.
    case watching(activeDays: Int, of: Int)
    /// Past the active days, nothing to suggest now (or the other gates aren't met yet).
    case none
    /// This many suggestions in the menu.
    case available(Int)
}

extension SuggestionPlan {
    /// The review sheet's plan for this suggestion (§4.2): only the suggested apps can be chosen,
    /// all of them preselected. For an add-to-group suggestion the group's apps come after the
    /// suggested app as *In this group*, which can't be chosen. Nothing is read: no open app, no
    /// window list, no disk.
    /// - Parameter groupItems: The target group's items, for an add-to-group suggestion.
    public func capturePlan(groupItems: [GroupItem] = []) -> CapturePlan {
        let inGroup = Set(groupItems.map(\.normalizedBundleIdentifier))
        var seen: Set<String> = []
        var candidates: [CaptureCandidate] = []
        for app in apps where seen.insert(app.normalizedBundleIdentifier).inserted {
            let isInGroup = kind == .addToGroup && inGroup.contains(app.normalizedBundleIdentifier)
            candidates.append(CaptureCandidate(item: app, notes: isInGroup ? [.inGroup] : [], isSelectable: !isInGroup))
        }
        if kind == .addToGroup {
            for item in groupItems where item.kind == .application && seen.insert(item.normalizedBundleIdentifier).inserted {
                candidates.append(CaptureCandidate(item: item, notes: [.inGroup], isSelectable: false))
            }
        }
        let selection = candidates.filter(\.isSelectable).prefix(CapturePlan.maximumItems).map(\.id)
        return CapturePlan(
            target: target,
            candidates: Array(candidates.prefix(CapturePlan.maximumCandidates)),
            defaultSelection: Array(selection),
            unavailableCount: 0,
            hasWindowInformation: false
        )
    }
}

/// One row of the menu bar menu's Suggestions section (§4.1): the suggestion and what the row
/// says about it. Holds no text of its own; the menu words it.
public struct SuggestionMenuRow: Equatable, Sendable {
    /// The most rows the section shows.
    public static let maximumRows = SuggestionPlanner.maximumSuggestions
    /// The most app names a new group's row spells out; the rest are counted ("+1").
    public static let maximumNamedApps = 3

    public let plan: SuggestionPlan
    /// The first `maximumNamedApps` apps' names, in the suggestion's order.
    public let appNames: [String]
    /// The apps not named.
    public let otherAppCount: Int
    /// The group an add-to-group suggestion is for.
    public let groupName: String?

    /// The rows for `plans`, at most `maximumRows`. An add-to-group suggestion whose group isn't
    /// an active group (`groupName` returns `nil`) has no row.
    public static func rows(for plans: [SuggestionPlan], groupName: (DockGroup.ID) -> String?) -> [SuggestionMenuRow] {
        var rows: [SuggestionMenuRow] = []
        for plan in plans where rows.count < maximumRows && !plan.apps.isEmpty {
            var name: String?
            if plan.kind == .addToGroup {
                guard let id = plan.group, let found = groupName(id) else { continue }
                name = found
            }
            let names = plan.apps.prefix(maximumNamedApps).map(\.displayName)
            rows.append(SuggestionMenuRow(
                plan: plan,
                appNames: Array(names),
                otherAppCount: plan.apps.count - names.count,
                groupName: name
            ))
        }
        return rows
    }
}
