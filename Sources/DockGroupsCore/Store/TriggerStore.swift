import Combine
import Foundation
import OSLog

/// What adding a trigger did (`TriggerStore.add`).
public enum TriggerAddResult: Equatable, Sendable {
    case added(GroupTrigger)
    /// The group has `GroupTrigger.maximumPerGroup` triggers already; nothing changed.
    case groupLimitReached
    /// `GroupTrigger.maximumCount` triggers exist already; nothing changed.
    case limitReached

    /// Why it wasn't added; `nil` when it was.
    public var message: String? {
        switch self {
        case .added:
            return nil
        case .groupLimitReached:
            let count = GroupTrigger.maximumPerGroup
            return Localization.format("core.trigger.limit.group", "A group can have up to %ld triggers.", count)
        case .limitReached:
            let count = GroupTrigger.maximumCount
            return Localization.format("core.trigger.limit.total", "You can have up to %ld triggers.", count)
        }
    }
}

/// The user's triggers (triggers spec §2.7), kept in their own file, `triggers.json`.
///
/// Like `TemplateStore`: every change is written shortly after it happens; a file that can't be
/// read is moved aside (`triggers.unreadable-<timestamp>.json`) and the store starts empty, saying
/// so in `issue`; when it can't be moved aside either, saving is suspended so the file isn't
/// overwritten. Triggers name their group by identifier: one whose group is archived stays and
/// doesn't run (it's looked up among the active groups), and one whose group is deleted goes with
/// it (`pruneTriggers(for:)`). At most `GroupTrigger.maximumPerGroup` per group and
/// `GroupTrigger.maximumCount` in all; an event this version can't read is kept as it was.
@MainActor
public final class TriggerStore: ObservableObject {
    @Published public private(set) var triggers: [GroupTrigger] = []
    /// The most recent problem to show the user; cleared with `dismissIssue()`.
    @Published public private(set) var issue: GroupStoreIssue?
    /// `true` when the saved file couldn't be read *and* couldn't be moved aside.
    public private(set) var isSavingSuspended = false

    private let persistence: TriggerPersisting
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// - Parameter saveDelay: How long to wait for further changes before writing. `.zero` writes
    ///   synchronously after every change.
    public init(persistence: TriggerPersisting, saveDelay: Duration = .milliseconds(250)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        loadFromDisk()
    }

    public func trigger(withID id: GroupTrigger.ID) -> GroupTrigger? {
        triggers.first { $0.id == id }
    }

    /// The group's triggers, in list order.
    public func triggers(ofGroup id: DockGroup.ID) -> [GroupTrigger] {
        triggers.filter { $0.groupID == id }
    }

    /// How many triggers are on and can run.
    public var enabledCount: Int {
        triggers.filter(\.canRun).count
    }

    public func dismissIssue() {
        issue = nil
    }

    // MARK: - Changes

    /// Adds `trigger` at the end of the list, within the limits. A trigger with the identifier of
    /// one in the store changes nothing (the stored one is returned).
    @discardableResult
    public func add(_ trigger: GroupTrigger) -> TriggerAddResult {
        if let existing = self.trigger(withID: trigger.id) { return .added(existing) }
        guard triggers.count < GroupTrigger.maximumCount else { return .limitReached }
        guard triggers(ofGroup: trigger.groupID).count < GroupTrigger.maximumPerGroup else { return .groupLimitReached }
        triggers.append(trigger)
        scheduleSave()
        return .added(trigger)
    }

    /// Replaces the trigger with `trigger`'s identifier. Moving it to a group that has
    /// `GroupTrigger.maximumPerGroup` triggers already changes nothing. Returns whether it changed.
    @discardableResult
    public func update(_ trigger: GroupTrigger) -> Bool {
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else { return false }
        guard triggers[index] != trigger else { return true }
        if triggers[index].groupID != trigger.groupID, triggers(ofGroup: trigger.groupID).count >= GroupTrigger.maximumPerGroup {
            return false
        }
        triggers[index] = trigger
        scheduleSave()
        return true
    }

    /// Turns a trigger on or off. One that can't run can't be turned on. Returns whether it is as asked.
    @discardableResult
    public func setEnabled(_ enabled: Bool, forTrigger id: GroupTrigger.ID) -> Bool {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return false }
        if enabled, !triggers[index].isRunnable { return false }
        guard triggers[index].isEnabled != enabled else { return true }
        triggers[index].isEnabled = enabled
        scheduleSave()
        return true
    }

    public func delete(_ id: GroupTrigger.ID) {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers.remove(at: index)
        scheduleSave()
    }

    /// Deletes the triggers of groups not in `groupIDs`. Returns how many went.
    @discardableResult
    public func removeTriggers(ofGroupsNotIn groupIDs: Set<DockGroup.ID>) -> Int {
        let kept = triggers.filter { groupIDs.contains($0.groupID) }
        let removed = triggers.count - kept.count
        guard removed > 0 else { return 0 }
        triggers = kept
        scheduleSave()
        return removed
    }

    /// Deletes the triggers of groups that are neither active nor archived in `groups` — unless the
    /// groups couldn't be loaded, when no trigger is deleted (spec §1.12).
    @discardableResult
    public func pruneTriggers(for groups: GroupStore) -> Int {
        guard !groups.loadFailed else { return 0 }
        return removeTriggers(ofGroupsNotIn: Set(groups.groups.map(\.id) + groups.archivedGroups.map(\.id)))
    }

    // MARK: - Restoring

    /// Replaces every trigger, as restoring a backup that has triggers does. The current file is
    /// first copied next to itself (`triggers.pre-import-<timestamp>.json`) and the new list is
    /// written before it's shown, so if anything fails nothing changes.
    /// - Returns: The copy of the previous file, or `nil` when nothing had been saved.
    @discardableResult
    public func replaceTriggers(with newTriggers: [GroupTrigger]) throws -> URL? {
        try replaceTriggers(with: newTriggers, copyLabel: "pre-import")
    }

    @discardableResult
    func replaceTriggers(with newTriggers: [GroupTrigger], copyLabel: String?) throws -> URL? {
        if !isSavingSuspended {
            flushPendingSave()
        }
        let copyURL = try copyLabel.flatMap { try persistence.preserveCopy(label: $0) }
        let sanitized = GroupTrigger.sanitized(newTriggers)
        try persistence.saveTriggers(sanitized)
        triggers = sanitized
        isSavingSuspended = false
        issue = nil
        return copyURL
    }

    /// Adds the triggers of `incoming` that aren't here yet (by identifier), as merging a backup
    /// does, within the limits. When something is added, the current file is copied first.
    /// - Returns: The triggers added.
    @discardableResult
    public func mergeTriggers(_ incoming: [GroupTrigger]) throws -> [GroupTrigger] {
        let currentIDs = Set(triggers.map(\.id))
        let merged = GroupTrigger.sanitized(triggers + incoming)
        let added = merged.filter { !currentIDs.contains($0.id) }
        guard !added.isEmpty else { return [] }
        try replaceTriggers(with: merged, copyLabel: "pre-import")
        return added
    }

    /// Copies the saved file next to itself (`triggers.<label>-<timestamp>.json`), a pending change
    /// written first.
    @discardableResult
    public func preserveCopy(label: String) throws -> URL? {
        if !isSavingSuspended {
            flushPendingSave()
        }
        return try persistence.preserveCopy(label: label)
    }

    // MARK: - Persistence

    /// Writes a pending change right away. Call before the app quits.
    public func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        writeToDisk()
    }

    private func loadFromDisk() {
        do {
            triggers = GroupTrigger.sanitized(try persistence.loadTriggers())
        } catch let loadError {
            logger.error("Loading triggers failed: \(String(describing: loadError), privacy: .public)")
            triggers = []
            do {
                let backupURL = try persistence.preserveUnreadableData()
                let reason = loadError.localizedDescription
                issue = GroupStoreIssue(
                    title: Localization.string("core.trigger.loadFailed.title", "Your triggers couldn't be loaded"),
                    message: backupURL.map { backup in
                        let path = backup.path
                        return Localization.format("core.trigger.loadFailed.kept", "%1$@ Starting without triggers. A copy was kept at “%2$@”.", reason, path)
                    } ?? Localization.format("core.trigger.loadFailed.empty", "%@ Starting without triggers.", reason)
                )
            } catch let moveError {
                logger.error("Preserving unreadable triggers failed: \(String(describing: moveError), privacy: .public)")
                isSavingSuspended = true
                let reason = loadError.localizedDescription
                issue = GroupStoreIssue(
                    title: Localization.string("core.trigger.loadFailed.title", "Your triggers couldn't be loaded"),
                    message: Localization.format(
                        "core.trigger.loadFailed.suspended",
                        "%@ To protect the existing file, changes to triggers won't be saved until the app is restarted.",
                        reason
                    )
                )
            }
        }
    }

    private func scheduleSave() {
        guard !isSavingSuspended else { return }
        pendingSave?.cancel()
        guard saveDelay > .zero else {
            writeToDisk()
            return
        }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    private func writeToDisk() {
        pendingSave = nil
        do {
            try persistence.saveTriggers(triggers)
        } catch {
            logger.error("Saving triggers failed: \(String(describing: error), privacy: .public)")
            if issue == nil {
                issue = GroupStoreIssue(
                    title: Localization.string("core.trigger.saveFailed.title", "Your triggers couldn't be saved"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
