import Foundation
import OSLog

/// Waits. The app's implementation is `Task.sleep`; tests use a fake that wakes when told to.
@MainActor
public protocol Sleeping: AnyObject {
    /// Returns after `duration`; throws when the task is cancelled meanwhile.
    func sleep(for duration: Duration) async throws
}

/// `Sleeping` with `Task.sleep`: no timers to keep, nothing polled.
@MainActor
public final class TaskSleeping: Sleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The items Open All and Start open after their launch delay (spec §2.9, §3.5).
///
/// Each Open All hands over its delayed items; those with the same delay wait together (one task
/// per delay), counted from the moment Open All started, and open side by side, not one after
/// another. When an item's time comes it's looked up in its group again and opened only if it's
/// still there with the same launch options — through the same checks as every item
/// (`GroupLauncher`), so a file deleted meanwhile is reported as not found. Finishing the group,
/// starting another group, and Hide All or Close All of the group cancel what hasn't opened yet.
///
/// What the delayed items of one Open All did is reported once, when the last of them opened (or
/// the rest were cancelled), through `onFinished`.
@MainActor
public final class DelayedLaunches {
    /// Opens items now, as Open All opens items without a delay.
    public typealias Opening = (_ items: [GroupItem], _ group: DockGroup) async -> LaunchReport

    /// Called with what the delayed items of one Open All did, once all of them opened or the rest
    /// were cancelled; not called when none opened.
    public var onFinished: ((LaunchReport) -> Void)?

    private let sleeper: Sleeping
    private let group: (DockGroup.ID) -> DockGroup?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "DelayedLaunches")

    /// The delayed items of one Open All.
    private final class Command {
        let groupID: DockGroup.ID
        let groupName: String
        var waiting: [Int: Task<Void, Never>] = [:]
        var waitingItemCount: Int
        /// Batches opening now.
        var opening = 0
        /// Done waiting: all opened, or the rest cancelled.
        var isEnded = false
        var entries: [LaunchReport.Entry] = []

        init(groupID: DockGroup.ID, groupName: String, waitingItemCount: Int) {
            self.groupID = groupID
            self.groupName = groupName
            self.waitingItemCount = waitingItemCount
        }
    }

    private var commands: [UUID: Command] = [:]

    /// - Parameters:
    ///   - sleeper: Waits out the delays; `TaskSleeping` by default.
    ///   - group: The group with this identifier as it is now (the store's), `nil` once deleted.
    public init(sleeper: Sleeping? = nil, group: @escaping (DockGroup.ID) -> DockGroup?) {
        self.sleeper = sleeper ?? TaskSleeping()
        self.group = group
    }

    /// Opens `items` of `group` after their launch delays, with `open`. Items without a delay are
    /// left out: they're Open All's to open.
    public func schedule(_ items: [GroupItem], of group: DockGroup, open: @escaping Opening) {
        let delayed = items.filter { $0.launch.delay > 0 }
        guard !delayed.isEmpty else { return }
        let id = UUID()
        let command = Command(groupID: group.id, groupName: group.name, waitingItemCount: delayed.count)
        commands[id] = command
        for seconds in Set(delayed.map(\.launch.delay)).sorted() {
            let batch = delayed.filter { $0.launch.delay == seconds }
            command.waiting[seconds] = Task { @MainActor [weak self] in
                do {
                    try await self?.sleeper.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                await self?.fire(batch, delay: seconds, of: id, open: open)
            }
        }
    }

    /// How many delayed items of the group haven't opened yet.
    public func pendingCount(of group: DockGroup.ID) -> Int {
        commands.values.filter { $0.groupID == group }.reduce(0) { $0 + $1.waitingItemCount }
    }

    /// Whether any delayed item hasn't opened yet.
    public var hasPending: Bool { !commands.isEmpty }

    /// Cancels the group's delayed items that haven't opened yet: finishing it, Hide All, Close All.
    public func cancel(group id: DockGroup.ID) {
        for (commandID, command) in commands where command.groupID == id {
            end(commandID, command, cancelled: true)
        }
    }

    /// Cancels every delayed item that hasn't opened yet: starting a group, the app quitting.
    public func cancelAll() {
        for (commandID, command) in commands {
            end(commandID, command, cancelled: true)
        }
    }

    // MARK: - Firing

    private func fire(_ batch: [GroupItem], delay: Int, of commandID: UUID, open: Opening) async {
        guard let command = commands[commandID], command.waiting[delay] != nil else { return }
        command.waiting[delay] = nil
        command.waitingItemCount -= batch.count
        // The items as they are now: still in the group, with the same launch options.
        if let current = group(command.groupID) {
            let unchanged = batch.filter { scheduled in
                current.apps.contains {
                    $0.normalizedBundleIdentifier == scheduled.normalizedBundleIdentifier && $0.kind == scheduled.kind && $0.launch == scheduled.launch
                }
            }
            if unchanged.count < batch.count {
                logger.notice("\(batch.count - unchanged.count) delayed item(s) of group \(command.groupID, privacy: .public) changed or were removed: not opened")
            }
            if !unchanged.isEmpty {
                command.opening += 1
                let report = await open(unchanged, current)
                command.opening -= 1
                command.entries += report.entries
            }
        }
        if command.isEnded {
            // Cancelled while this batch opened: what it opened is reported now.
            if command.opening == 0 { report(command) }
        } else if command.waiting.isEmpty {
            end(commandID, command, cancelled: false)
        }
    }

    private func end(_ commandID: UUID, _ command: Command, cancelled: Bool) {
        commands[commandID] = nil
        command.isEnded = true
        if cancelled {
            command.waiting.values.forEach { $0.cancel() }
            if command.waitingItemCount > 0 {
                logger.notice("Cancelled \(command.waitingItemCount) delayed item(s) of group \(command.groupID, privacy: .public)")
            }
            command.waiting = [:]
            command.waitingItemCount = 0
        }
        // A batch still opening reports once it's done.
        if command.opening == 0 { report(command) }
    }

    private func report(_ command: Command) {
        guard !command.entries.isEmpty else { return }
        let entries = command.entries
        command.entries = []
        onFinished?(LaunchReport(groupName: command.groupName, entries: entries))
    }
}
