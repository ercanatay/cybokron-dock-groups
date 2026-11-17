import Foundation

/// One Local Suggestion, as `SuggestionPlanner` proposes it (design local-suggestions.md §3.4): a
/// new group of 3 to 6 apps, or one app to add to an existing group. It holds no text: what the
/// menu and the review sheet say is worded from these values where they're shown. Turning it into
/// the review sheet's `CapturePlan` (§4.2) is left to the caller: `target` is the sheet's target
/// and `apps` the apps it lists, preselected.
public struct SuggestionPlan: Hashable, Sendable {
    /// The same kinds a dismissal records.
    public typealias Kind = DismissedSuggestion.Kind

    public let kind: Kind
    /// App items that passed `AppItemPolicy`, built from the usage statistics. For a new group,
    /// its apps — launched most often first, then by bundle identifier — in the order they'd be
    /// added; for an add-to-group suggestion, the one app to add.
    public let apps: [GroupItem]
    /// The existing group an add-to-group suggestion is for; `nil` for a new group.
    public let group: DockGroup.ID?
    /// The fewest times two of the suggestion's apps were launched together. For an add-to-group
    /// suggestion, the pairs are the suggested app with each group app it's strongly paired with.
    public let weakestPairCount: Int
    /// The sum of those pairs' counts; add-to-group suggestions are ranked by it.
    public let totalPairCount: Int

    public init(kind: Kind, apps: [GroupItem], group: DockGroup.ID? = nil, weakestPairCount: Int, totalPairCount: Int) {
        self.kind = kind
        self.apps = apps
        self.group = kind == .addToGroup ? group : nil
        self.weakestPairCount = weakestPairCount
        self.totalPairCount = totalPairCount
    }

    /// The apps' identities: lowercased bundle identifiers, in `apps` order.
    public var appKeys: [String] { apps.map(\.normalizedBundleIdentifier) }

    /// Where the review sheet puts the apps: a new group, or the suggested group.
    public var target: CaptureTarget {
        if kind == .addToGroup, let group { return .group(group) }
        return .newGroup
    }

    /// What turning this suggestion down records: `until` is the end of a "Not now"
    /// (`SuggestionPlanner.shortSnooze` or `longSnooze` from now), `nil` for "Don't suggest this
    /// again".
    public func dismissal(until: Date?) -> DismissedSuggestion {
        DismissedSuggestion(kind: kind, apps: appKeys, group: group, until: until)
    }
}
