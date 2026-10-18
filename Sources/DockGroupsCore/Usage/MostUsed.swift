import Foundation

/// One app of the Most Used list.
public struct MostUsedEntry: Hashable, Sendable {
    public let app: AppReference
    public let launchCount: Int
    public let score: Double
}

/// Ranks apps for the Most Used list.
///
/// An app's score is its launch count plus a bonus of up to 30 %: each launch that happened
/// together with another app's (in the same session) adds 0.3. Launches dominate, so the list
/// mostly follows the launch counts; among apps launched about as often, the ones that are part of
/// the user's routine come first.
public enum MostUsedRanking {
    public static let cooccurrenceWeight = 0.3
    public static let defaultLimit = 10
    public static let allowedLimits = [5, 10, 15]

    public static func score(of key: String, in stats: UsageStats) -> Double {
        guard let launches = stats.apps[key]?.launchCount, launches > 0 else { return 0 }
        let togetherLaunches = min(stats.cooccurrenceCount(of: key), launches)
        return Double(launches) + cooccurrenceWeight * Double(togetherLaunches)
    }

    /// The `limit` best-ranked apps for which `isAvailable` holds, best first. Ties go to the app
    /// launched more often, then the one launched more recently, then by name.
    public static func rank(
        _ stats: UsageStats,
        limit: Int,
        isAvailable: (AppReference) -> Bool = { _ in true }
    ) -> [MostUsedEntry] {
        guard limit > 0 else { return [] }
        let candidates = stats.apps
            .filter { $0.value.launchCount > 0 && UsageTracker.isTracked(bundleIdentifier: $0.key) }
            .map { key, usage in (usage: usage, score: score(of: key, in: stats)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.usage.launchCount != rhs.usage.launchCount { return lhs.usage.launchCount > rhs.usage.launchCount }
                let lhsDate = lhs.usage.lastLaunchedAt ?? .distantPast
                let rhsDate = rhs.usage.lastLaunchedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                let byName = lhs.usage.app.name.localizedStandardCompare(rhs.usage.app.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.usage.app.normalizedBundleIdentifier < rhs.usage.app.normalizedBundleIdentifier
            }

        // Availability checks hit LaunchServices; stop as soon as the list is full.
        var entries: [MostUsedEntry] = []
        for candidate in candidates where entries.count < limit {
            guard isAvailable(candidate.usage.app) else { continue }
            entries.append(MostUsedEntry(app: candidate.usage.app, launchCount: candidate.usage.launchCount, score: candidate.score))
        }
        return entries
    }
}

/// The Most Used list presented like a group, so the menu, the popup and the launcher can show and
/// open it. It isn't one of the user's groups: it's never saved and can't be edited.
public enum MostUsedGroup {
    /// Fixed identifier, distinct from the random identifiers of the user's groups.
    public static let id = UUID(uuidString: "00000000-0000-4000-8000-0000000057ED")!
    /// The list's name, in the user's language.
    public static var name: String { Localization.string("core.mostUsed.name", "Most Used") }
    public static let symbol = "★"
    public static let tile = TileAppearance(
        kind: .emoji,
        backgroundStyle: .gradient,
        backgroundColor: TileColor(red: 0x2A, green: 0x2D, blue: 0x34)
    )

    public static func group(with entries: [MostUsedEntry]) -> DockGroup {
        DockGroup(id: id, name: name, emoji: symbol, apps: entries.map(\.app), tile: tile)
    }
}
