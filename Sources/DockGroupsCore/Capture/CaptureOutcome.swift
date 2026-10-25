import Foundation

/// What capturing from Siri or the Shortcuts app did (capture spec §1.10, §2.7): there is no sheet,
/// so the apps that would start selected in it are added, and this says what came of it.
public enum CaptureOutcome: Equatable, Sendable {
    /// A new group, at the end of the list, with the open apps that start selected.
    case created(DockGroup)
    /// `count` apps (at least one) were added to the group named `groupName`.
    case added(count: Int, groupName: String)
    /// The group has every open app already: nothing was added.
    case everyAppInGroup(groupName: String)
    /// No open app starts selected — none is open, or every one is protected or, with the window
    /// option, has no open window. Nothing was made or added. `groupName` is the target group's,
    /// `nil` for a new group.
    case nothingToAdd(groupName: String?)
    /// The target group isn't an active group (any more): it's archived or deleted. Nothing was added.
    case unavailableGroup

    /// The apps Siri and Shortcuts never capture: the Shortcuts app runs them, it isn't part of the
    /// work (spec §1.3).
    public static let leftOutApps: Set<String> = ["com.apple.shortcuts"]

    /// The settings capturing uses without a sheet: the remembered ones, with the window option
    /// as the intent's parameter says when it's given.
    public static func settings(_ remembered: CaptureSettings, onlyAppsWithWindows: Bool?) -> CaptureSettings {
        var settings = remembered
        if let onlyAppsWithWindows {
            settings.selectsOnlyAppsWithWindows = onlyAppsWithWindows
        }
        return settings
    }

    /// The group made, for a shortcut to go on with (Launch Group…); `nil` when none was.
    public var createdGroup: DockGroup? {
        if case .created(let group) = self { return group }
        return nil
    }

    /// The answer Siri or the Shortcuts app shows: “Made “Xcode +3” with 4 apps.”
    public var summary: String {
        switch self {
        case .created(let group):
            let count = group.apps.count
            return count == 1 ? "Made “\(group.name)” with 1 app." : "Made “\(group.name)” with \(count) apps."
        case .added(let count, let groupName):
            return count == 1 ? "Added 1 app to “\(groupName)”." : "Added \(count) apps to “\(groupName)”."
        case .everyAppInGroup(let groupName):
            return "Every open app is already in “\(groupName)”."
        case .nothingToAdd(nil):
            return "No open apps to put in a group."
        case .nothingToAdd(let groupName?):
            return "No open apps to add to “\(groupName)”."
        case .unavailableGroup:
            return "The group is archived or was deleted. Nothing was added."
        }
    }
}

extension GroupStore {
    /// Captures without a sheet, for Siri and the Shortcuts app (spec §1.10, §2.7): plans `snapshot`
    /// without the Shortcuts app (`CaptureOutcome.leftOutApps`) and adds the apps that start
    /// selected (`CapturePlan.defaultItems`, at most `CapturePlan.maximumItems`) where `target`
    /// says — a new group named `typedName` as typed, the suggestion when it's blank or `nil`, or
    /// the apps an active group doesn't have yet. Nothing is made when no app starts selected, and
    /// an archived or deleted group is never a target. Nothing is opened, hidden or quit.
    @discardableResult
    public func captureWithoutSheet(
        _ snapshot: OpenAppsSnapshot,
        into target: CaptureTarget,
        typedName: String?,
        settings: CaptureSettings,
        protectedApps: ProtectedApps
    ) -> CaptureOutcome {
        var groupName: String?
        var targetItems: [GroupItem] = []
        if case .group(let id) = target {
            guard let group = group(withID: id) else { return .unavailableGroup }
            groupName = group.name
            targetItems = group.apps
        }
        let plan = CapturePlanner.plan(
            snapshot,
            settings: settings,
            target: target,
            targetItems: targetItems,
            protectedApps: protectedApps,
            leavingOut: CaptureOutcome.leftOutApps
        )
        let items = plan.defaultItems
        guard !items.isEmpty else {
            if let groupName, !plan.candidates.isEmpty, !plan.hasSelectableCandidates {
                return .everyAppInGroup(groupName: groupName)
            }
            return .nothingToAdd(groupName: groupName)
        }
        let name = CapturePlanner.groupName(typed: typedName ?? "", items: items, taken: takenNames)
        switch capture(items, into: target, named: name) {
        case .created(let group):
            return .created(group)
        case .added(let count, _):
            guard let groupName else { return .unavailableGroup }
            return count == 0 ? .everyAppInGroup(groupName: groupName) : .added(count: count, groupName: groupName)
        case .unavailableGroup:
            return .unavailableGroup
        }
    }
}
