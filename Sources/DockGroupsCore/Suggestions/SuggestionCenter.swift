import Foundation
import OSLog

/// Local Suggestions in the main app (design local-suggestions.md §4, §5): what the menu bar menu
/// and Settings → Most Used show, the review sheet's plan, and turning a suggestion down.
///
/// Fail-closed: while Suggestions or Most Used is off nothing is computed — not even whether an
/// app is installed — and nothing is shown. A suggestion never acts on its own: this creates no
/// group and runs nothing; only the review sheet's commit (`GroupStore.capture`) does. Only the
/// main app's menu and Settings use it: the popup, standalone agents, Siri and Shortcuts, links,
/// the CLI, triggers and group shortcuts don't (D5).
///
/// Logs counts and outcomes only — never an app's name or bundle identifier, a path or a pair
/// count, at any level (§2.5).
@MainActor
public final class SuggestionCenter {
    private let usage: UsageStore
    private let preferences: PreferencesStore
    private let groups: GroupStore
    private let isInstalled: (AppReference) -> Bool
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Suggestions")
    /// The count last logged, so opening the menu again doesn't repeat the line.
    private var lastLoggedCount: Int?

    /// - Parameter isInstalled: Whether the app is on this Mac (`AppIconProviding.isInstalled`);
    ///   asked only while Suggestions are on.
    public init(
        usage: UsageStore,
        preferences: PreferencesStore,
        groups: GroupStore,
        isInstalled: @escaping (AppReference) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.usage = usage
        self.preferences = preferences
        self.groups = groups
        self.isInstalled = isInstalled
        self.now = now
    }

    /// Whether suggestions may be computed and shown: Suggestions and Most Used both on.
    public var isActive: Bool {
        let settings = preferences.preferences
        return settings.showsSuggestions && settings.showsMostUsed
    }

    /// The suggestions now, at most `SuggestionPlanner.maximumSuggestions`; empty while
    /// `isActive` doesn't hold. Computed afresh on every call and never saved. Only the active
    /// groups are passed to the planner.
    public func suggestions() -> [SuggestionPlan] {
        guard isActive else { return [] }
        let plans = SuggestionPlanner.plan(
            stats: usage.stats,
            state: usage.suggestionState,
            groups: groups.groups,
            preferences: preferences.preferences,
            now: now(),
            isInstalled: isInstalled
        )
        if plans.count != lastLoggedCount {
            lastLoggedCount = plans.count
            logger.notice("Computed \(plans.count, privacy: .public) suggestions")
        }
        return plans
    }

    /// The menu bar menu's rows: at most `SuggestionMenuRow.maximumRows`; none while off.
    public func menuRows() -> [SuggestionMenuRow] {
        SuggestionMenuRow.rows(for: suggestions()) { [groups] id in groups.group(withID: id)?.name }
    }

    /// What Settings says.
    public func status() -> SuggestionStatus {
        let settings = preferences.preferences
        guard settings.showsSuggestions else { return .off }
        guard settings.showsMostUsed else { return .needsMostUsed }
        let state = usage.suggestionState
        let required = SuggestionPlanner.minimumActiveDays
        if state.enabledAt == nil || state.activeDays < required {
            return .watching(activeDays: min(state.activeDays, required), of: required)
        }
        let count = suggestions().count
        return count == 0 ? .none : .available(count)
    }

    /// Whether `plan` is still one of the suggestions now: the menu's row may be from before a
    /// change (the group was archived, the app added, the setting turned off).
    public func isCurrent(_ plan: SuggestionPlan) -> Bool {
        suggestions().contains(plan)
    }

    /// The review sheet's plan for `plan`; `nil` when it isn't a current suggestion any more, or
    /// its group isn't an active group.
    public func reviewPlan(for plan: SuggestionPlan) -> CapturePlan? {
        guard isCurrent(plan) else { return nil }
        guard plan.kind == .addToGroup else { return plan.capturePlan() }
        guard let id = plan.group, let group = groups.group(withID: id) else { return nil }
        return plan.capturePlan(groupItems: group.apps)
    }

    /// Records that the user turned `plan` down: not again for `snooze`.
    public func dismiss(_ plan: SuggestionPlan, for snooze: SuggestionSnooze) {
        usage.addSuggestionDismissal(plan.dismissal(until: snooze.until(from: now())))
        lastLoggedCount = nil
        logger.notice("Dismissed (\(plan.kind.rawValue, privacy: .public), \(plan.apps.count, privacy: .public) apps) for \(snooze.rawValue, privacy: .public)")
    }

    /// The number of dismissals kept: Settings and Diagnostics show it.
    public var dismissedCount: Int { usage.suggestionState.dismissed.count }

    /// Reset Dismissed Suggestions….
    public func resetDismissed() {
        let count = dismissedCount
        usage.resetDismissedSuggestions()
        lastLoggedCount = nil
        logger.notice("Reset \(count, privacy: .public) dismissed suggestions")
    }

    /// Whether turning Suggestions on should explain them first: they never were on, or the
    /// history was cleared since.
    public var needsExplanation: Bool { usage.suggestionState.enabledAt == nil }

    /// Turns Suggestions on or off (`UsageStore.setSuggestionsEnabled`).
    public func setEnabled(_ enabled: Bool) {
        usage.setSuggestionsEnabled(enabled, in: preferences)
        lastLoggedCount = nil
        logger.notice("Suggestions turned \(enabled ? "on" : "off", privacy: .public)")
    }
}
