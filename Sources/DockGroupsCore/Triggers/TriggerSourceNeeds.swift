import Foundation

/// Which system sources the triggers need (triggers spec §5, "Idle"): a source runs only while a
/// trigger that can run — turned on, runnable, of a group that isn't archived — waits for what it
/// reports. A trigger turned on later, or whose group comes back, starts from a fresh baseline, so
/// a source that stood still meanwhile makes no edge of what it missed.
public struct TriggerSourceNeeds: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The connected displays (`DisplaySource`).
    public static let displays = TriggerSourceNeeds(rawValue: 1 << 0)

    public static func of(rules: [GroupTrigger], activeGroups: Set<DockGroup.ID>) -> TriggerSourceNeeds {
        var needs: TriggerSourceNeeds = []
        for trigger in rules where trigger.canRun && activeGroups.contains(trigger.groupID) {
            guard case .condition(let condition, _) = trigger.event else { continue }
            switch condition {
            case .display, .displays: needs.insert(.displays)
            case .wifi, .ethernet, .vpn: break
            }
        }
        return needs
    }
}
