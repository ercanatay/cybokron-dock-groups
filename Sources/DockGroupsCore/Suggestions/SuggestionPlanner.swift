import Foundation

/// Proposes Local Suggestions from the Most Used counts (design local-suggestions.md §3): a pure
/// function of its arguments, reading nothing, writing nothing and logging nothing, so the same
/// input always gives the same suggestions in the same order. Too little or doubtful data gives
/// no suggestion (§5 rule 4): it never falls back to showing something.
public enum SuggestionPlanner: Sendable {
    /// An exact fraction, so thresholds compare integers and never depend on rounding.
    public struct Ratio: Hashable, Sendable {
        public let numerator: Int
        public let denominator: Int

        public init(_ numerator: Int, _ denominator: Int) {
            precondition(numerator >= 0 && denominator > 0, "A ratio needs a non-negative numerator and a positive denominator")
            self.numerator = numerator
            self.denominator = denominator
        }

        /// Whether `part / whole` is at least this ratio. A non-positive `whole` never meets it.
        /// Compared in full width, so huge counts from a hand-edited file can't overflow.
        public func isMet(by part: Int, of whole: Int) -> Bool {
            guard whole > 0, part >= 0 else { return false }
            let lhs = part.multipliedFullWidth(by: denominator)
            let rhs = numerator.multipliedFullWidth(by: whole)
            return (lhs.high, lhs.low) >= (rhs.high, rhs.low)
        }

        /// The smallest part of `whole` that meets this ratio (the fraction of `whole`, rounded up).
        /// Meant for small wholes, such as a group's apps.
        public func minimumPart(of whole: Int) -> Int {
            guard whole > 0 else { return 0 }
            var part = (numerator * whole) / denominator
            while !isMet(by: part, of: whole) { part += 1 }
            return part
        }
    }

    // MARK: - Thresholds (§3.7: constants, not user-editable in v1)

    private static let day: TimeInterval = 86_400

    // §3.1 Cold start: all must hold, or there's no suggestion.
    /// How long Suggestions must have been on (since `SuggestionState.enabledAt`): 7 days.
    public static let observationWindow: TimeInterval = 7 * day
    /// Local calendar days with a recorded launch since they were turned on.
    public static let minimumActiveDays = 5
    /// Launches recorded in all, of all apps (`UsageStats.totalLaunchCount`).
    public static let minimumTotalLaunches = 50

    // §3.2 Eligible apps.
    /// Launches of one app.
    public static let minimumAppLaunches = 5
    /// An app last launched longer ago than this (14 days) isn't part of the current routine.
    public static let maximumLaunchAge: TimeInterval = 14 * day

    // §3.3 Pair strength.
    /// Sessions in which two apps were launched together ("support").
    public static let minimumPairCount = 5
    /// The pair count divided by the launches of the more often launched app: 0.35. The larger
    /// count keeps "hub" apps launched with everything (a browser, mail, chat) out.
    public static let minimumMutualStrength = Ratio(35, 100)

    // §3.4 Building suggestions (D8).
    /// The fewest apps of a new group: two apps are too weak a signal.
    public static let minimumGroupSize = 3
    /// The most apps of a new group.
    public static let maximumGroupSize = 6
    /// A new group isn't suggested when an existing group has this share of its apps already: 75 %.
    public static let existingGroupOverlap = Ratio(3, 4)
    /// An existing group needs this many apps to get an add-to-group suggestion.
    public static let minimumTargetGroupApps = 2
    /// The share of a group's eligible apps the suggested app must be strongly paired with: 2/3,
    /// rounded up…
    public static let addToGroupShare = Ratio(2, 3)
    /// …and at least this many of them.
    public static let minimumAddToGroupLinks = 2
    public static let maximumNewGroupSuggestions = 2
    public static let maximumAddToGroupSuggestions = 2
    /// The most suggestions shown at once, new groups first.
    public static let maximumSuggestions = 3

    // §3.6 Repeat suppression.
    /// A dismissal matches a suggestion of its kind when their app sets overlap this much
    /// (Jaccard index, shared apps divided by all apps): 0.75.
    public static let dismissalOverlap = Ratio(3, 4)
    /// "Not now", and cancelling the review sheet: not again for 7 days.
    public static let shortSnooze: TimeInterval = 7 * day
    /// "Not now" for a month: 30 days.
    public static let longSnooze: TimeInterval = 30 * day

    // MARK: - Planning

    /// The suggestions to show at `now`, at most `maximumSuggestions`: new groups first, strongest
    /// first, then add-to-group suggestions, strongest first.
    /// - Parameters:
    ///   - stats: The Most Used counts.
    ///   - state: When Suggestions were turned on, the active days and the dismissals.
    ///   - groups: The active groups; archived groups aren't passed (and are never suggested to).
    ///   - preferences: `showsSuggestions` and `showsMostUsed` must both be on; `protectedApps`
    ///     are never suggested.
    ///   - now: The moment of the windows and dismissals.
    ///   - isInstalled: Whether the app is on this Mac; asked only about apps that passed the
    ///     other checks.
    public static func plan(
        stats: UsageStats,
        state: SuggestionState,
        groups: [DockGroup],
        preferences: PopupPreferences,
        now: Date,
        isInstalled: (AppReference) -> Bool
    ) -> [SuggestionPlan] {
        guard isReady(stats: stats, state: state, preferences: preferences, now: now) else { return [] }
        let eligible = eligibleApps(in: stats, protectedApps: preferences.protectedApps, now: now, isInstalled: isInstalled)
        guard eligible.count >= 2 else { return [] }
        let graph = PairGraph(stats: stats, eligible: eligible)
        let active = state.dismissed.filter { !$0.hasExpired(at: now) }

        let newGroups = newGroupSuggestions(graph: graph, eligible: eligible, groups: groups, dismissed: active)
        let additions = addToGroupSuggestions(graph: graph, eligible: eligible, groups: groups, dismissed: active)
        return Array((newGroups + additions).prefix(maximumSuggestions))
    }

    /// The cold-start gates (§3.1): both switches on, Suggestions on for `observationWindow`, enough
    /// active days and enough launches.
    public static func isReady(stats: UsageStats, state: SuggestionState, preferences: PopupPreferences, now: Date) -> Bool {
        guard preferences.showsSuggestions, preferences.showsMostUsed,
              let enabledAt = state.enabledAt,
              now.timeIntervalSince(enabledAt) >= observationWindow,
              state.activeDays >= minimumActiveDays
        else { return false }
        // Summed saturating, unlike `UsageStats.totalLaunchCount`, so huge counts can't trap.
        let total = stats.apps.values.reduce(0) { saturatingSum($0, $1.launchCount) }
        return total >= minimumTotalLaunches
    }

    /// The apps that may be suggested (§3.2), keyed by lowercased bundle identifier, with the item
    /// a suggestion would add.
    static func eligibleApps(
        in stats: UsageStats,
        protectedApps: ProtectedApps,
        now: Date,
        isInstalled: (AppReference) -> Bool
    ) -> [String: EligibleApp] {
        var eligible: [String: EligibleApp] = [:]
        for key in stats.apps.keys.sorted() {
            guard let usage = stats.apps[key], key == UsageStats.key(for: key),
                  UsageTracker.isTracked(bundleIdentifier: key),
                  usage.launchCount >= minimumAppLaunches,
                  let lastLaunchedAt = usage.lastLaunchedAt,
                  now.timeIntervalSince(lastLaunchedAt) <= maximumLaunchAge,
                  !protectedApps.lists(identity: key),
                  !ProtectedApps.isAlwaysProtected(identity: key, action: .hiding),
                  !ProtectedApps.isAlwaysProtected(identity: key, action: .quitting)
            else { continue }
            let app = usage.app
            guard app.kind == .application,
                  let item = AppItemPolicy.sanitized(GroupItem(bundleIdentifier: app.bundleIdentifier, name: app.name, path: app.path)),
                  item.kind == .application, item.normalizedBundleIdentifier == key,
                  isInstalled(item)
            else { continue }
            eligible[key] = EligibleApp(key: key, item: item, launchCount: usage.launchCount)
        }
        return eligible
    }

    // MARK: - New groups

    private static func newGroupSuggestions(
        graph: PairGraph,
        eligible: [String: EligibleApp],
        groups: [DockGroup],
        dismissed: [DismissedSuggestion]
    ) -> [SuggestionPlan] {
        let groupApps = groups.map(appKeys(of:))
        var used = Set<String>()
        var suggestions: [SuggestionPlan] = []
        // 1. Strongest pair first, ties by key.
        for seed in graph.pairsByStrength where suggestions.count < maximumNewGroupSuggestions {
            guard !used.contains(seed.first), !used.contains(seed.second) else { continue }
            // 2. Grow the seed while an app is strongly paired with every member.
            var members = [seed.first, seed.second]
            while members.count < maximumGroupSize, let next = bestAddition(to: members, graph: graph, excluding: used) {
                members.append(next)
            }
            // 3. Two apps aren't a suggestion; their apps may still seed or join another one.
            guard members.count >= minimumGroupSize else { continue }
            // 5. The apps are used, whether the set is kept or not.
            used.formUnion(members)
            // 4. Not when a group has most of them already, or the set was turned down.
            let set = Set(members)
            if groupApps.contains(where: { existingGroupOverlap.isMet(by: $0.intersection(set).count, of: set.count) }) { continue }
            if dismissed.contains(where: { matches($0, kind: .newGroup, apps: set, group: nil) }) { continue }

            let ordered = members.compactMap { eligible[$0] }.sorted(by: isLaunchedMoreOften)
            let counts = pairCounts(among: members, graph: graph)
            suggestions.append(SuggestionPlan(
                kind: .newGroup,
                apps: ordered.map(\.item),
                weakestPairCount: counts.min() ?? 0,
                totalPairCount: counts.reduce(0, saturatingSum)
            ))
        }
        return suggestions
    }

    /// The app strongly paired with every member whose weakest such pair is strongest; ties by key.
    private static func bestAddition(to members: [String], graph: PairGraph, excluding used: Set<String>) -> String? {
        let memberSet = Set(members)
        var best: (key: String, weakest: Int)?
        for candidate in graph.neighbors(of: members[0]) where !memberSet.contains(candidate) && !used.contains(candidate) {
            var weakest = Int.max
            for member in members {
                guard let count = graph.count(candidate, member) else {
                    weakest = 0
                    break
                }
                weakest = min(weakest, count)
            }
            guard weakest > 0 else { continue }
            if let current = best, current.weakest > weakest || (current.weakest == weakest && current.key < candidate) { continue }
            best = (candidate, weakest)
        }
        return best?.key
    }

    private static func pairCounts(among members: [String], graph: PairGraph) -> [Int] {
        var counts: [Int] = []
        for (index, first) in members.enumerated() {
            for second in members[(index + 1)...] {
                counts.append(graph.count(first, second) ?? 0)
            }
        }
        return counts
    }

    // MARK: - Add to group

    private static func addToGroupSuggestions(
        graph: PairGraph,
        eligible: [String: EligibleApp],
        groups: [DockGroup],
        dismissed: [DismissedSuggestion]
    ) -> [SuggestionPlan] {
        var candidates: [(plan: SuggestionPlan, groupIndex: Int)] = []
        var seenGroups = Set<DockGroup.ID>()
        for (groupIndex, group) in groups.enumerated() where seenGroups.insert(group.id).inserted {
            let members = appKeys(of: group)
            guard members.count >= minimumTargetGroupApps else { continue }
            let eligibleMembers = members.filter { eligible[$0] != nil }
            let required = max(minimumAddToGroupLinks, addToGroupShare.minimumPart(of: eligibleMembers.count))
            guard eligibleMembers.count >= required else { continue }

            var best: (key: String, total: Int, weakest: Int)?
            for candidate in graph.keys where !members.contains(candidate) {
                let links = eligibleMembers.compactMap { graph.count(candidate, $0) }
                guard links.count >= required,
                      !dismissed.contains(where: { matches($0, kind: .addToGroup, apps: [candidate], group: group.id) })
                else { continue }
                let total = links.reduce(0, saturatingSum)
                if let current = best, current.total > total || (current.total == total && current.key < candidate) { continue }
                best = (candidate, total, links.min() ?? 0)
            }
            guard let best, let app = eligible[best.key] else { continue }
            candidates.append((
                SuggestionPlan(kind: .addToGroup, apps: [app.item], group: group.id, weakestPairCount: best.weakest, totalPairCount: best.total),
                groupIndex
            ))
        }
        return candidates
            .sorted { lhs, rhs in
                if lhs.plan.totalPairCount != rhs.plan.totalPairCount { return lhs.plan.totalPairCount > rhs.plan.totalPairCount }
                return lhs.groupIndex < rhs.groupIndex
            }
            .prefix(maximumAddToGroupSuggestions)
            .map(\.plan)
    }

    // MARK: - Helpers

    /// `lhs + rhs`, at most `Int.max`.
    static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    /// Whether `dismissal`, still in force, turns down a suggestion (§3.6): the same kind and app
    /// sets that overlap by `dismissalOverlap`; for add-to-group, also the same group and the same app.
    static func matches(_ dismissal: DismissedSuggestion, kind: SuggestionPlan.Kind, apps: Set<String>, group: DockGroup.ID?) -> Bool {
        guard dismissal.kind == kind else { return false }
        let dismissed = Set(dismissal.apps)
        if kind == .addToGroup {
            return dismissal.group == group && dismissed == apps
        }
        return dismissalOverlap.isMet(by: dismissed.intersection(apps).count, of: dismissed.union(apps).count)
    }

    /// A group's app items' identities, lowercased; websites, files and folders aren't counted.
    private static func appKeys(of group: DockGroup) -> Set<String> {
        Set(group.apps.filter { $0.kind == .application }.map(\.normalizedBundleIdentifier))
    }

    private static func isLaunchedMoreOften(_ lhs: EligibleApp, than rhs: EligibleApp) -> Bool {
        if lhs.launchCount != rhs.launchCount { return lhs.launchCount > rhs.launchCount }
        return lhs.key < rhs.key
    }

    /// An app that passed §3.2.
    struct EligibleApp: Hashable, Sendable {
        let key: String
        let item: GroupItem
        let launchCount: Int
    }

    /// The strong pairs (§3.3) among eligible apps. A pair's count is the smaller of its two
    /// directions, so a file whose graph isn't symmetric can only weaken a pair.
    struct PairGraph: Sendable {
        struct Pair: Hashable, Sendable {
            /// `first < second`.
            let first: String
            let second: String
            let count: Int
        }

        private var strong: [String: [String: Int]] = [:]
        /// Strongest first, then by keys.
        private(set) var pairsByStrength: [Pair] = []

        init(stats: UsageStats, eligible: [String: EligibleApp]) {
            for first in eligible.keys.sorted() {
                guard let partners = stats.cooccurrence[first], let firstApp = eligible[first] else { continue }
                for (second, forward) in partners where first < second {
                    guard let secondApp = eligible[second],
                          let backward = stats.cooccurrence[second]?[first]
                    else { continue }
                    let count = min(forward, backward)
                    guard count >= SuggestionPlanner.minimumPairCount,
                          SuggestionPlanner.minimumMutualStrength.isMet(by: count, of: max(firstApp.launchCount, secondApp.launchCount))
                    else { continue }
                    strong[first, default: [:]][second] = count
                    strong[second, default: [:]][first] = count
                    pairsByStrength.append(Pair(first: first, second: second, count: count))
                }
            }
            pairsByStrength.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.first != rhs.first { return lhs.first < rhs.first }
                return lhs.second < rhs.second
            }
        }

        /// The apps with at least one strong pair, sorted.
        var keys: [String] { strong.keys.sorted() }

        /// The apps strongly paired with `key`, sorted.
        func neighbors(of key: String) -> [String] {
            (strong[key] ?? [:]).keys.sorted()
        }

        /// The count of a strong pair; `nil` when the pair isn't strong.
        func count(_ lhs: String, _ rhs: String) -> Int? {
            strong[lhs]?[rhs]
        }
    }
}
