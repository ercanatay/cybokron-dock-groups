import Foundation

/// What the popup, the menu bar menu and the group window offer for a group (spec §4.1–§4.3):
/// Start, or Finish for the current group, with a help text that says what it will do with the
/// group's settings — which group's apps are hidden or quit, and which group comes back.
public struct SwitchingOffer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case start
        case finish
    }

    public let action: Action
    public let groupName: String
    /// Start: the current group, which Start puts away. Finish: the group started before it, which
    /// Finish shows again (only when the group's settings say so). `nil` when there's none.
    public let otherGroupName: String?
    public let switching: GroupSwitching

    public init(action: Action, groupName: String, otherGroupName: String?, switching: GroupSwitching) {
        self.action = action
        self.groupName = groupName
        self.otherGroupName = otherGroupName
        self.switching = switching
    }

    /// Starting `group` while `current` is the current group.
    public static func start(_ group: DockGroup, current: DockGroup?) -> SwitchingOffer {
        let previous = current?.id == group.id ? nil : current
        return SwitchingOffer(action: .start, groupName: group.name, otherGroupName: previous?.name, switching: group.switching)
    }

    /// Finishing `group`, the current group, with `previous` started before it.
    public static func finish(_ group: DockGroup, previous: DockGroup?) -> SwitchingOffer {
        let next = group.switching.afterFinish == .showPreviousGroup && previous?.id != group.id ? previous : nil
        return SwitchingOffer(action: .finish, groupName: group.name, otherGroupName: next?.name, switching: group.switching)
    }

    /// What the popup and the menus offer for `group`: Finish when it's the current group, Start
    /// otherwise.
    /// - Parameters:
    ///   - current: The current group (`ContextSession.current`).
    ///   - previous: The group started before it (`ContextSession.previous`).
    ///   - groups: Every group, to name the current and the previous one.
    public static func offer(for group: DockGroup, current: DockGroup.ID?, previous: DockGroup.ID?, in groups: [DockGroup]) -> SwitchingOffer {
        let lookup = { (id: DockGroup.ID?) in id.flatMap { id in groups.first { $0.id == id } } }
        return current == group.id
            ? finish(group, previous: lookup(previous))
            : start(group, current: lookup(current))
    }

    /// The button's title: "Start" or "Finish".
    public var title: String {
        switch action {
        case .start: return Localization.string("popup.switching.start", "Start")
        case .finish: return Localization.string("popup.switching.finish", "Finish")
        }
    }

    /// The SF Symbol of the button.
    public var systemImage: String {
        switch action {
        case .start: return "play.fill"
        case .finish: return "stop.fill"
        }
    }

    /// VoiceOver's label, with the group's name: "Start Coding".
    public var accessibilityLabel: String {
        switch action {
        case .start: return Localization.format("popup.switching.start.accessibility", "Start %@", groupName)
        case .finish: return Localization.format("popup.switching.finish.accessibility", "Finish %@", groupName)
        }
    }

    /// What it does, as its settings say: "Start: open this group's items and hide the apps of
    /// “Design”."
    public var help: String {
        switch action {
        case .start: return startHelp
        case .finish: return finishHelp
        }
    }

    private var startHelp: String {
        switch switching.onStart {
        case .leaveOthers:
            return Localization.string("popup.switching.help.start.leave", "Start: open this group's items and leave the other apps as they are.")
        case .hideAllOtherApps:
            return Localization.string("popup.switching.help.start.hideAll", "Start: open this group's items and hide all other apps.")
        case .hidePreviousGroup, .quitPreviousGroup:
            guard let otherGroupName else {
                return Localization.string("popup.switching.help.start.alone", "Start: open this group's items and make it the current group.")
            }
            return switching.onStart == .quitPreviousGroup
                ? Localization.format("popup.switching.help.start.quit", "Start: open this group's items and quit the apps of “%@” it doesn't use.", otherGroupName)
                : Localization.format("popup.switching.help.start.hide", "Start: open this group's items and hide the apps of “%@”.", otherGroupName)
        }
    }

    private var finishHelp: String {
        switch (switching.onFinish, otherGroupName) {
        case (.hideApps, nil):
            return Localization.string("popup.switching.help.finish.hide", "Finish: hide this group's apps.")
        case (.hideApps, let next?):
            return Localization.format("popup.switching.help.finish.hideAndShow", "Finish: hide this group's apps and show “%@” again.", next)
        case (.quitApps, nil):
            return Localization.string("popup.switching.help.finish.quit", "Finish: quit this group's apps.")
        case (.quitApps, let next?):
            return Localization.format("popup.switching.help.finish.quitAndShow", "Finish: quit this group's apps and show “%@” again.", next)
        case (.leaveApps, nil):
            return Localization.string("popup.switching.help.finish.leave", "Finish: leave this group's apps open; it's no longer the current group.")
        case (.leaveApps, let next?):
            return Localization.format("popup.switching.help.finish.leaveAndShow", "Finish: leave this group's apps open and show “%@” again.", next)
        }
    }
}
