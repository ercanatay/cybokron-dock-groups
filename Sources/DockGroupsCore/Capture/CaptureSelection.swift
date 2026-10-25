import Foundation

/// Which listed apps the capture sheet has selected (spec §1.5, §1.8): it starts as the plan's
/// `defaultSelection`, only selectable candidates can be in it — never an app the target group has
/// already — and never more than `CapturePlan.maximumItems` of them.
public struct CaptureSelection: Equatable, Sendable {
    public private(set) var ids: Set<CaptureCandidate.ID>

    /// The plan's first selection.
    public init(plan: CapturePlan) {
        ids = Set(plan.defaultSelection)
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    /// Whether as many apps are selected as one capture adds: the others can't be checked.
    public var isAtLimit: Bool { ids.count >= CapturePlan.maximumItems }

    public func isSelected(_ candidate: CaptureCandidate) -> Bool {
        ids.contains(candidate.id)
    }

    /// Whether the candidate's checkbox can change: it's selectable, and either selected or below
    /// the limit.
    public func canToggle(_ candidate: CaptureCandidate) -> Bool {
        candidate.isSelectable && (isSelected(candidate) || !isAtLimit)
    }

    /// Selects or deselects the candidate. Nothing changes for an app the group has, or for a new
    /// one past the limit.
    /// - Returns: Whether the selection changed.
    @discardableResult
    public mutating func set(_ candidate: CaptureCandidate, selected: Bool) -> Bool {
        guard candidate.isSelectable, selected != isSelected(candidate) else { return false }
        if selected {
            guard !isAtLimit else { return false }
            ids.insert(candidate.id)
        } else {
            ids.remove(candidate.id)
        }
        return true
    }

    /// Select All: the first `CapturePlan.maximumItems` selectable candidates, in list order.
    public mutating func selectAll(in plan: CapturePlan) {
        ids = Set(plan.candidates.lazy.filter(\.isSelectable).prefix(CapturePlan.maximumItems).map(\.id))
    }

    /// Select None.
    public mutating func selectNone() {
        ids = []
    }

    /// The items to add, in list order (`CapturePlan.items(selecting:)`).
    public func items(in plan: CapturePlan) -> [GroupItem] {
        plan.items(selecting: ids)
    }
}

/// What capturing did (`GroupStore.capture`).
public enum CaptureResult: Equatable, Sendable {
    /// A new group, at the end of the list.
    case created(DockGroup)
    /// `count` apps were added to the group (0 when it had all of them already).
    case added(count: Int, groupID: DockGroup.ID)
    /// The target group isn't an active group any more: it was archived or deleted meanwhile.
    /// Nothing was added.
    case unavailableGroup
}

extension CapturePlanner {
    /// The name a new group gets: what the user typed, when it isn't blank, kept as typed (as
    /// renaming keeps it); the suggestion otherwise (spec §1.6, Decision 3).
    public static func groupName(typed: String, items: [GroupItem], taken: some Sequence<String>) -> String {
        DockGroup.sanitizedName(typed) ?? suggestedName(for: items, taken: taken)
    }
}

extension GroupStore {
    /// Adds captured `items` where `target` says, in one change and one save: a new group named
    /// `name` (`addGroup(named:items:)`), or the items an existing group doesn't have yet
    /// (`addItems(_:toGroup:)`). Both pass the store's item checks (`AppItemPolicy`). An archived or
    /// deleted group is never a target. Nothing is opened, hidden or quit.
    @discardableResult
    public func capture(_ items: [GroupItem], into target: CaptureTarget, named name: String) -> CaptureResult {
        switch target {
        case .newGroup:
            return .created(addGroup(named: name, items: items))
        case .group(let id):
            guard group(withID: id) != nil else { return .unavailableGroup }
            return .added(count: addItems(items, toGroup: id), groupID: id)
        }
    }
}
