import Foundation

/// What starting and finishing a group does besides opening its items: Start brings the group
/// forward and puts the group started before it away; Finish puts the group away and can show the
/// one started before it again (`TransitionPlanner`).
///
/// Quitting is never a default: Start hides the previous group's apps, and Finish hides the
/// group's own. An automatic trigger (a Focus) never quits, whatever the settings say
/// (`withoutQuitting`).
public struct GroupSwitching: Hashable, Sendable {
    /// What Start does to the apps that aren't in the group being started.
    public enum OnStart: String, Codable, CaseIterable, Sendable {
        /// Nothing: Start opens the group's items and leaves every other app as it is.
        case leaveOthers
        /// The running apps of the group started before this one (that this one doesn't use) are
        /// hidden.
        case hidePreviousGroup
        /// Every other running app is hidden, as ⌥⌘H in an app does.
        case hideAllOtherApps
        /// The running apps of the group started before this one (that this one doesn't use) are
        /// asked to quit; they can still ask to save changes.
        case quitPreviousGroup
    }

    /// What Finish does to the group's own running apps.
    public enum OnFinish: String, Codable, CaseIterable, Sendable {
        case hideApps
        /// Asked to quit; they can still ask to save changes.
        case quitApps
        case leaveApps
    }

    /// What Finish does after putting the group away.
    public enum AfterFinish: String, Codable, CaseIterable, Sendable {
        case nothing
        /// Shows the running apps of the group started before this one again (nothing is launched).
        case showPreviousGroup
    }

    public var onStart: OnStart
    public var onFinish: OnFinish
    public var afterFinish: AfterFinish

    public init(onStart: OnStart = .hidePreviousGroup, onFinish: OnFinish = .hideApps, afterFinish: AfterFinish = .showPreviousGroup) {
        self.onStart = onStart
        self.onFinish = onFinish
        self.afterFinish = afterFinish
    }

    /// Whether these are the defaults: a group with them is saved without a `switching` key, as
    /// every group was before Start and Finish existed.
    public var isDefault: Bool { self == GroupSwitching() }

    /// Whether starting or finishing the group with these settings may quit apps.
    public var quitsApps: Bool { onStart == .quitPreviousGroup || onFinish == .quitApps }

    /// The settings a trigger that may not quit uses (a Focus): quitting becomes hiding.
    public var withoutQuitting: GroupSwitching {
        var settings = self
        if settings.onStart == .quitPreviousGroup { settings.onStart = .hidePreviousGroup }
        if settings.onFinish == .quitApps { settings.onFinish = .hideApps }
        return settings
    }
}

extension GroupSwitching: Codable {
    private enum CodingKeys: String, CodingKey {
        case onStart, onFinish, afterFinish
    }

    /// Each setting is read on its own: a missing or unknown value (one a newer version wrote) is the
    /// default, and the others are kept.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GroupSwitching()
        onStart = container.decodeLeniently(OnStart.self, forKey: .onStart) ?? defaults.onStart
        onFinish = container.decodeLeniently(OnFinish.self, forKey: .onFinish) ?? defaults.onFinish
        afterFinish = container.decodeLeniently(AfterFinish.self, forKey: .afterFinish) ?? defaults.afterFinish
    }
}
