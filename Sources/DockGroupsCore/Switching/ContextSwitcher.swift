import Combine
import Foundation
import OSLog

/// Why a group couldn't be started or finished.
public enum ContextSwitchingError: Error, Equatable, Sendable {
    /// No group has this identifier (any more).
    case groupNotFound(DockGroup.ID)
}

/// Starts and finishes groups (spec §3.4): plans the transition (`TransitionPlanner`), asks first
/// when it would quit apps and a link, Siri or Shortcuts asked, then hides, quits (gracefully) and
/// shows apps again (`GroupTerminator`), opens the started group's items (`GroupLauncher`), and
/// keeps the current group (`ContextSession`).
///
/// Transitions run one at a time, in the order they were asked for: a second one waits — without
/// polling — until the first is done, so it can't interleave with the first one's Open All, and it
/// plans with the apps and the current group the first one left. A Start of the current group that
/// arrives within `ContextSession.repeatInterval` of the first does nothing.
@MainActor
public final class ContextSwitcher {
    private let store: GroupStore
    private let preferences: PreferencesStore
    private let session: ContextSession
    private let launcher: GroupLauncher
    private let terminator: GroupTerminator
    private let applications: RunningApplicationsListing
    private let questions: TransitionQuestioning
    private let clock: () -> Date
    private var subscriptions: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Switching")

    /// Whether a transition is under way.
    private var isSwitching = false
    /// Transitions waiting for the one under way, in order.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - applications: The running apps, read once per transition.
    ///   - questions: Asks a link's question before a transition quits apps (`GroupQuitRequests`).
    ///   - clock: The time, for `ContextSession.repeatInterval`.
    public init(
        store: GroupStore,
        preferences: PreferencesStore,
        session: ContextSession,
        launcher: GroupLauncher,
        terminator: GroupTerminator,
        applications: RunningApplicationsListing,
        questions: TransitionQuestioning,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.preferences = preferences
        self.session = session
        self.launcher = launcher
        self.terminator = terminator
        self.applications = applications
        self.questions = questions
        self.clock = clock
        // Deleted groups leave the current group and the history.
        store.$groups
            .sink { [weak session] groups in session?.prune(keeping: Set(groups.map(\.id))) }
            .store(in: &subscriptions)
    }

    /// Whether a transition is under way or waiting.
    public var isBusy: Bool { isSwitching }

    /// Starts the group: puts the current group away as its settings say, opens its items, and
    /// makes it current.
    /// - Parameter confirm: Siri's or Shortcuts' question (`trigger == .intent`), asked when the
    ///   transition would quit apps; it throws when the user declines, and then nothing is done.
    ///   Links are asked through `questions`.
    /// - Throws: `ContextSwitchingError.groupNotFound`, or what `confirm` throws.
    public func start(
        _ id: DockGroup.ID,
        trigger: TransitionTrigger,
        confirm: ((TransitionConfirmation) async throws -> Void)? = nil
    ) async throws -> TransitionReport {
        try await oneAtATime {
            guard let target = store.group(withID: id) else { throw ContextSwitchingError.groupNotFound(id) }
            if session.isRepeatedStart(of: id, at: clock()) {
                logger.notice("Start of group \(id, privacy: .public) (\(trigger.rawValue, privacy: .public)): just started, nothing to do")
                return TransitionReport(outcome: .repeated, plan: TransitionPlan(kind: .start(id), trigger: trigger, groupName: target.name, otherGroupName: nil))
            }
            let previous = session.current.flatMap(store.group(withID:))
            let planned = TransitionPlanner.start(
                target,
                previous: previous,
                running: applications.runningApplications(),
                protected: preferences.preferences.protectedApps,
                trigger: trigger
            )
            let plan: TransitionPlan
            switch try await confirmed(planned, confirm: confirm) {
            case .proceed(let confirmedPlan): plan = confirmedPlan
            case .stopped(let outcome): return TransitionReport(outcome: outcome, plan: planned)
            }
            // The group as it is now: asking may have taken a while.
            guard let group = store.group(withID: id) else { throw ContextSwitchingError.groupNotFound(id) }
            var report = TransitionReport(outcome: .done, plan: plan)
            report.hidden = terminator.hide(plan.hide.map(\.app))
            report.quit = terminator.quit(plan.quit.map(\.app))
            report.launch = await launcher.openAll(group)
            session.didStart(id, at: clock(), by: trigger)
            logger.notice("Started group \(id, privacy: .public) (\(trigger.rawValue, privacy: .public)): \(report.hidden.done.count) hidden, \(report.quit.done.count) asked to quit, \(plan.kept.count) left alone")
            return report
        }
    }

    /// Finishes the group: hides (or quits, or leaves) its apps as its settings say and, when it's
    /// current, shows the group started before it again (nothing is launched).
    /// - Parameter confirm: as for `start`.
    /// - Throws: `ContextSwitchingError.groupNotFound`, or what `confirm` throws.
    public func finish(
        _ id: DockGroup.ID,
        trigger: TransitionTrigger,
        confirm: ((TransitionConfirmation) async throws -> Void)? = nil
    ) async throws -> TransitionReport {
        try await oneAtATime {
            guard let group = store.group(withID: id) else { throw ContextSwitchingError.groupNotFound(id) }
            let next = session.current == id && group.switching.afterFinish == .showPreviousGroup
                ? session.previous.flatMap(store.group(withID:))
                : nil
            let planned = TransitionPlanner.finish(
                group,
                next: next,
                running: applications.runningApplications(),
                protected: preferences.preferences.protectedApps,
                trigger: trigger
            )
            let plan: TransitionPlan
            switch try await confirmed(planned, confirm: confirm) {
            case .proceed(let confirmedPlan): plan = confirmedPlan
            case .stopped(let outcome): return TransitionReport(outcome: outcome, plan: planned)
            }
            var report = TransitionReport(outcome: .done, plan: plan)
            report.hidden = terminator.hide(plan.hide.map(\.app))
            report.quit = terminator.quit(plan.quit.map(\.app))
            report.shown = terminator.unhide(plan.unhide.map(\.app), bringingToFront: plan.front)
            session.didFinish(id, showing: plan.next)
            logger.notice("Finished group \(id, privacy: .public) (\(trigger.rawValue, privacy: .public)): \(report.hidden.done.count) hidden, \(report.quit.done.count) asked to quit, \(report.shown.done.count) shown again")
            return report
        }
    }

    // MARK: - Asking

    private enum Confirmation {
        case proceed(TransitionPlan)
        case stopped(TransitionReport.Outcome)
    }

    /// The plan to carry out, after asking when it quits apps and the trigger asks first.
    private func confirmed(_ plan: TransitionPlan, confirm: ((TransitionConfirmation) async throws -> Void)?) async throws -> Confirmation {
        guard plan.requiresConfirmation, let question = TransitionConfirmation(plan: plan) else { return .proceed(plan) }
        switch plan.trigger {
        case .intent:
            guard let confirm else {
                // Nobody to ask: nothing is quit unasked.
                logger.error("A transition from Siri or Shortcuts had no way to ask: hiding instead of quitting")
                return .proceed(TransitionPlanner.hidingInsteadOfQuitting(plan))
            }
            try await confirm(question)
            return .proceed(plan)
        case .link, .userAction, .focus:
            switch questions.askBeforeTransition(question) {
            case nil: return .stopped(.dropped)
            case .cancel: return .stopped(.declined)
            case .hideInstead: return .proceed(TransitionPlanner.hidingInsteadOfQuitting(plan))
            case .quit: return .proceed(plan)
            }
        }
    }

    // MARK: - One at a time

    /// Runs `body` once the transitions asked for before it are done.
    private func oneAtATime<T>(_ body: () async throws -> T) async rethrows -> T {
        if isSwitching {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isSwitching = true
        }
        defer {
            if waiting.isEmpty {
                isSwitching = false
            } else {
                // Hands over to the next one: it runs as soon as this one returns.
                waiting.removeFirst().resume()
            }
        }
        return try await body()
    }
}
