import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Runs the triggers while the app runs (triggers spec §2.5, DECISION 1): it owns the triggers
/// (`TriggerStore`, `triggers.json`), their state (`TriggerStateStore`, `trigger-state.json`), the
/// coordinator, the notice and the sources — the clock and the workspace in this version — and
/// passes what the sources see to the coordinator, which decides and carries out through
/// `AutomationBridge` with `TransitionTrigger.automation`: nothing a trigger does quits an app or
/// asks a question.
///
/// - Rule changes start the changed triggers from a fresh baseline (`rulesChanged`); group changes
///   delete the triggers of deleted groups — never after the groups couldn't be loaded — and
///   archived groups' triggers just don't run (`activeGroups` is `store.groups`).
/// - The launch is told 5 seconds after the app finished launching (the launch settle): a link or
///   a Siri or Shortcuts request meanwhile makes it quiet, and so does the marker an update's or a
///   language change's relaunch leaves (`markQuietRelaunch`).
/// - Only the main app creates one (`AppDelegate`): a standalone group's agent never evaluates,
///   runs or registers anything.
@MainActor
final class TriggerController: ObservableObject {
    /// How long after the launch it's told, so requests that came with it are seen first.
    static let launchSettle: Duration = .seconds(5)
    /// How long the quiet-launch marker lasts.
    static let quietRelaunchWindow: TimeInterval = 2 * 60

    let store: TriggerStore
    let loginItem: LoginItem
    let coordinator: TriggerCoordinator
    /// The state as the coordinator keeps it, for the rows' last-run lines and the pause.
    @Published private(set) var state: TriggerState

    private let groups: GroupStore
    private let stateStore: TriggerStateStore
    private let notice = TriggerNoticePanel()
    private var clock: ClockSource?
    private var workspace: WorkspaceSource?
    private var rules: [GroupTrigger]
    private var subscriptions: Set<AnyCancellable> = []
    private var launchSettle: Task<Void, Never>?
    /// Redraws what shows the pause when it ends.
    private var pauseEnd: Task<Void, Never>?
    /// The groups that were active (not archived) at the last look, to tell a restored one.
    private var activeGroupIDs: Set<DockGroup.ID> = []
    private var requestsDuringLaunch = 0
    private var isLaunchSettled = false
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    /// - Parameters: `store`, `stateStore` and `loginItem` default to the app's own files and login
    ///   item.
    init(groups: GroupStore, store: TriggerStore? = nil, stateStore: TriggerStateStore? = nil, loginItem: LoginItem? = nil) {
        let store = store ?? TriggerStore(persistence: JSONFileTriggerPersistence())
        let stateStore = stateStore ?? TriggerStateStore()
        self.groups = groups
        self.store = store
        self.stateStore = stateStore
        self.loginItem = loginItem ?? LoginItem()
        rules = store.triggers
        state = stateStore.state
        // Archived and deleted groups aren't in `groups.groups`: their triggers never run.
        coordinator = TriggerCoordinator(
            state: stateStore.state,
            rules: { [store] in store.triggers },
            activeGroups: { [groups] in Set(groups.groups.map(\.id)) }
        )
    }

    // MARK: - Starting

    /// Starts the triggers: their baseline, the coordinator's handler and notice, the sources, and —
    /// after the launch settle — the launch itself.
    func start(handler: AutomationHandling, launchedAsLoginItem: Bool, launchedAt: Date) {
        guard clock == nil else { return }
        notice.describe = { [weak self] notice in
            guard let trigger = self?.store.trigger(withID: notice.triggerID) else { return "" }
            return TriggerDescriptions.event(trigger.event, appName: AppInfo.name, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        }
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            let pauseChanged = state.pausedUntil != self.state.pausedUntil
            self.stateStore.update(state)
            self.state = state
            if pauseChanged {
                self.watchPauseEnd()
            }
        }
        coordinator.noticePresenter = notice
        coordinator.handler = handler
        store.pruneTriggers(for: groups)
        rules = store.triggers
        activeGroupIDs = Set(groups.groups.map(\.id))
        coordinator.start()
        state = coordinator.state
        watchPauseEnd()

        // @Published says before the value changes: look once it has.
        store.$triggers
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.triggersChanged() }
            .store(in: &subscriptions)
        groups.$groups
            .combineLatest(groups.$archivedGroups)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.groupsChanged() }
            .store(in: &subscriptions)

        let clock = ClockSource(
            nextDue: { [weak self] in self?.coordinator.nextDue },
            onTick: { [weak self] in self?.coordinator.receive(.clock) }
        )
        self.clock = clock
        let workspace = WorkspaceSource { [weak self] signal in self?.coordinator.receive(signal) }
        self.workspace = workspace
        workspace.start()
        clock.start()

        launchSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchSettle)
            guard let self, !Task.isCancelled else { return }
            self.isLaunchSettled = true
            let kind = LaunchClassifier.kind(
                launchedAsLoginItem: launchedAsLoginItem,
                consoleSessionStart: LaunchSignals.consoleSessionStart(),
                launchedAt: launchedAt,
                hadRequest: self.requestsDuringLaunch > 0
            )
            let counted = self.coordinator.launchKind(kind)
            self.logger.notice("Launch: \(String(describing: counted), privacy: .public)")
            self.coordinator.receive(.launched(counted))
            self.clock?.reschedule()
        }
    }

    /// A link, a document or a Siri or Shortcuts request reached the app: while the launch settles,
    /// it makes the launch quiet.
    func noteRequest() {
        guard !isLaunchSettled else { return }
        requestsDuringLaunch += 1
    }

    /// The app is about to relaunch for an update or a language change: the launch after it is
    /// quiet. Written to disk right away.
    func markQuietRelaunch() {
        coordinator.markQuietLaunch(until: Date().addingTimeInterval(Self.quietRelaunchWindow))
        stateStore.update(coordinator.state)
        stateStore.flushPendingSave()
    }

    /// Before the app quits.
    func flush() {
        store.flushPendingSave()
        stateStore.flushPendingSave()
    }

    // MARK: - Pausing

    var isPaused: Bool { coordinator.isPaused }

    func pause(_ length: TriggerPauseLength) {
        coordinator.pause(length)
    }

    func resume() {
        coordinator.resume()
    }

    /// How triggers are paused now; `nil` while they run.
    enum PauseStatus: Equatable {
        /// Until a time, as "18:00" or "Tomorrow at 0:00".
        case until(String)
        case untilResumed
        /// They ran too often (`TriggerBudget`).
        case budget
    }

    var pauseStatus: PauseStatus? {
        guard let until = state.pausedUntil, state.isPaused(at: Date()) else { return nil }
        if state.pauseReason == .budget { return .budget }
        // Until I Resume Them pauses until the distant future.
        if until.timeIntervalSinceNow > 365 * 24 * 3600 { return .untilResumed }
        return .until(Self.pauseEndText(until))
    }

    /// The pause as the menu bar menu and the group window say it: "Triggers paused until 18:00".
    var pauseDescription: String? {
        switch pauseStatus {
        case nil: return nil
        case .until(let time): return L10n.Triggers.MenuBar.pausedUntil(time)
        case .untilResumed: return L10n.Triggers.MenuBar.pausedIndefinitely
        case .budget: return TriggerBudget.pauseMessage
        }
    }

    /// The time of today, or the day and time ("Tomorrow at 0:00") of another day.
    private static func pauseEndText(_ date: Date) -> String {
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// Once the pause ends, what shows it shows the triggers running again.
    private func watchPauseEnd() {
        pauseEnd?.cancel()
        pauseEnd = nil
        guard let until = state.pausedUntil, until.timeIntervalSinceNow > 0, until.timeIntervalSinceNow < 365 * 24 * 3600 else { return }
        pauseEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else { return }
            self?.objectWillChange.send()
        }
    }

    // MARK: - What the rows show

    /// Whether any trigger is on and can run.
    var hasRunnableTriggers: Bool { store.enabledCount > 0 }

    static func summary(of trigger: GroupTrigger) -> String {
        TriggerDescriptions.summary(trigger, appName: AppInfo.name, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }

    /// The last-run line of `trigger`, or why it can't run.
    func statusLine(of trigger: GroupTrigger) -> String {
        if let problem = trigger.problem { return problem }
        if groups.archivedGroup(withID: trigger.groupID) != nil {
            return L10n.Triggers.GroupWindow.archived
        }
        let name = groups.group(withID: trigger.groupID)?.name ?? ""
        return TriggerDescriptions.lastRun(state.entry(for: trigger.id), groupName: name, now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }

    // MARK: - Changes

    private func triggersChanged() {
        let previous = rules
        rules = store.triggers
        coordinator.rulesChanged(previous: previous)
        clock?.reschedule()
        objectWillChange.send()
    }

    /// Triggers of deleted groups go. A restored group's triggers start from a fresh baseline, as
    /// turned-on ones do: what came while it was archived never runs.
    private func groupsChanged() {
        let active = Set(groups.groups.map(\.id))
        let restored = active.subtracting(activeGroupIDs)
        activeGroupIDs = active
        store.pruneTriggers(for: groups)
        if store.triggers.contains(where: { restored.contains($0.groupID) }) {
            let asBefore = store.triggers.map { trigger -> GroupTrigger in
                guard restored.contains(trigger.groupID) else { return trigger }
                var off = trigger
                off.isEnabled = false
                return off
            }
            coordinator.rulesChanged(previous: asBefore)
        }
        clock?.reschedule()
        objectWillChange.send()
    }
}

/// What triggers do, done the way the app's own buttons do it (triggers spec §2.5): Start and Finish
/// through the `ContextSwitcher` with the trigger they're given (always
/// `TransitionTrigger.automation`), Open All through the launcher, the popup through the popup's
/// controller. Problems — items that couldn't open, apps that couldn't be hidden — are shown after
/// the action returns, so an alert never holds the next trigger up. A Start or Finish that fails
/// (the group is gone) returns `nil`.
@MainActor
final class AutomationBridge: AutomationHandling {
    struct Actions {
        let group: (DockGroup.ID) -> DockGroup?
        let currentGroupID: () -> DockGroup.ID?
        let currentGroupStartTrigger: () -> TransitionTrigger?
        let start: (DockGroup.ID, TransitionTrigger) async throws -> TransitionReport
        let finish: (DockGroup.ID, TransitionTrigger, Bool) async throws -> TransitionReport
        let openAll: (DockGroup) async -> LaunchReport
        let showPopup: (DockGroup) -> Void
    }

    private let actions: Actions
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")

    init(actions: Actions) {
        self.actions = actions
    }

    func group(withID id: DockGroup.ID) -> DockGroup? { actions.group(id) }
    var currentGroupID: DockGroup.ID? { actions.currentGroupID() }
    var currentGroupStartTrigger: TransitionTrigger? { actions.currentGroupStartTrigger() }

    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport? {
        do {
            let report = try await actions.start(id, trigger)
            Self.presentLater(report)
            return report
        } catch {
            logger.error("A trigger couldn't start group \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport? {
        do {
            let report = try await actions.finish(id, trigger, showsPrevious)
            Self.presentLater(report)
            return report
        } catch {
            logger.error("A trigger couldn't finish group \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func openAllItems(of group: DockGroup) async -> LaunchReport {
        let report = await actions.openAll(group)
        Task { @MainActor in LaunchReportPresenter.presentProblems(in: report) }
        return report
    }

    func showPopup(of group: DockGroup) {
        actions.showPopup(group)
    }

    private static func presentLater(_ report: TransitionReport) {
        Task { @MainActor in LaunchReportPresenter.presentProblems(in: report) }
    }
}
