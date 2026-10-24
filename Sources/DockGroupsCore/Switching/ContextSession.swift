import Combine
import Foundation

/// Which group is current — the one started last, until it's finished — and the groups started
/// before it, most recent first (spec §2.4). Only Start makes a group current; Open All, showing a
/// popup and clicking an item don't.
///
/// Kept in memory only: it starts empty at each launch, so after an update or a restart no group is
/// current and nothing is shown again until a group is started.
@MainActor
public final class ContextSession: ObservableObject {
    /// The most groups the history keeps.
    public static let maximumHistoryCount = 8
    /// Starting the current group again sooner than this after it was started does nothing: the
    /// same request arriving twice (a Focus and a Shortcuts automation, a double click) is carried
    /// out once.
    public static let repeatInterval: TimeInterval = 3

    /// The current group; `nil` when none is.
    @Published public private(set) var current: DockGroup.ID?
    /// Started groups, most recent first, each once. While a group is current it's the first.
    public private(set) var history: [DockGroup.ID] = []
    /// When the current group was started; `nil` when it became current by Finish going back to it.
    public private(set) var startedAt: Date?
    /// Who started the current group.
    public private(set) var startTrigger: TransitionTrigger?

    public init() {}

    /// The group started before the current one: the one Finish goes back to.
    public var previous: DockGroup.ID? {
        guard let current, history.first == current else { return nil }
        return history.dropFirst().first
    }

    /// Whether starting `id` at `date` repeats a Start that just happened (`repeatInterval`).
    public func isRepeatedStart(of id: DockGroup.ID, at date: Date) -> Bool {
        guard current == id, let startedAt else { return false }
        let elapsed = date.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed < Self.repeatInterval
    }

    /// `id` was started: it's current now, and first in the history.
    public func didStart(_ id: DockGroup.ID, at date: Date, by trigger: TransitionTrigger) {
        history = Array(([id] + history.filter { $0 != id }).prefix(Self.maximumHistoryCount))
        current = id
        startedAt = date
        startTrigger = trigger
    }

    /// `id` was finished and leaves the history; `next`, the group shown again (if any), becomes
    /// current. Finishing a group that isn't current leaves the current one as it is.
    public func didFinish(_ id: DockGroup.ID, showing next: DockGroup.ID?) {
        let wasCurrent = current == id
        history.removeAll { $0 == id }
        guard wasCurrent else { return }
        if let next {
            history = Array(([next] + history.filter { $0 != next }).prefix(Self.maximumHistoryCount))
        }
        current = next
        startedAt = nil
        startTrigger = nil
    }

    /// Forgets groups that were deleted; when the current one was, no group is current.
    public func prune(keeping ids: Set<DockGroup.ID>) {
        history.removeAll { !ids.contains($0) }
        if let current, !ids.contains(current) {
            self.current = nil
            startedAt = nil
            startTrigger = nil
        }
    }
}
