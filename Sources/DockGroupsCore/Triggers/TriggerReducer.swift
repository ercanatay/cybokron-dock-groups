import Foundation

/// A firing the reducer or the coordinator didn't carry out, and why.
public struct TriggerSkip: Hashable, Sendable {
    public let firing: TriggerFiring
    public let reason: TriggerSkipReason

    public init(firing: TriggerFiring, reason: TriggerSkipReason) {
        self.firing = firing
        self.reason = reason
    }
}

/// The firings of one settle window, reduced (`TriggerReducer`).
public struct TriggerReduction: Equatable, Sendable {
    /// What to carry out, in order: finishes, the Start, Open Alls, the popup.
    public var run: [TriggerFiring]
    public var skipped: [TriggerSkip]
}

/// Reduces firings that became due together (triggers spec §1.8) so conflicting actions don't run
/// one after the other:
///
/// 1. **Finish** of different groups first, each group once — not the group being started.
/// 2. **Start**: at most one, the latest occurrence; a tie goes to the trigger listed first.
/// 3. **Open All**: each group once, not the group just started (Start opens it anyway).
/// 4. **Show the Popup**: at most one, the latest, not of a group just started or opened.
///
/// Pure: the coordinator records the skipped ones.
public enum TriggerReducer {
    public static func reduce(_ firings: [TriggerFiring]) -> TriggerReduction {
        var skipped: [TriggerSkip] = []
        func latestFirst(_ lhs: TriggerFiring, _ rhs: TriggerFiring) -> Bool {
            lhs.occurrence != rhs.occurrence ? lhs.occurrence > rhs.occurrence : lhs.order < rhs.order
        }

        let starts = firings.filter { $0.action == .start }.sorted(by: latestFirst)
        let start = starts.first
        skipped += starts.dropFirst().map { TriggerSkip(firing: $0, reason: start?.groupID == $0.groupID ? .alreadyDone : .anotherTrigger) }
        let startedGroup = start?.groupID

        var finishes: [TriggerFiring] = []
        for finish in firings.filter({ $0.action == .finish }).sorted(by: latestFirst) {
            if finish.groupID == startedGroup {
                skipped.append(TriggerSkip(firing: finish, reason: .anotherTrigger))
            } else if finishes.contains(where: { $0.groupID == finish.groupID }) {
                skipped.append(TriggerSkip(firing: finish, reason: .alreadyDone))
            } else {
                finishes.append(finish)
            }
        }

        var openAlls: [TriggerFiring] = []
        for openAll in firings.filter({ $0.action == .openAll }).sorted(by: latestFirst) {
            if openAll.groupID == startedGroup || openAlls.contains(where: { $0.groupID == openAll.groupID }) {
                skipped.append(TriggerSkip(firing: openAll, reason: .alreadyDone))
            } else {
                openAlls.append(openAll)
            }
        }

        let opened = Set(openAlls.map(\.groupID) + [startedGroup].compactMap { $0 })
        var popup: TriggerFiring?
        for show in firings.filter({ $0.action == .showPopup }).sorted(by: latestFirst) {
            if opened.contains(show.groupID) {
                skipped.append(TriggerSkip(firing: show, reason: .alreadyDone))
            } else if let chosen = popup {
                skipped.append(TriggerSkip(firing: show, reason: chosen.groupID == show.groupID ? .alreadyDone : .anotherTrigger))
            } else {
                popup = show
            }
        }

        let run = finishes.sorted { $0.occurrence != $1.occurrence ? $0.occurrence < $1.occurrence : $0.order < $1.order }
            + [start].compactMap { $0 }
            + openAlls.sorted { $0.order < $1.order }
            + [popup].compactMap { $0 }
        return TriggerReduction(run: run, skipped: skipped)
    }
}
