import Foundation

/// Counts app launches and which apps are launched together.
///
/// Apps launched within one *session* — a sliding window of `sessionLength` seconds — count as
/// launched together: each newly launched app forms a pair with every app already in the session,
/// counted in both directions. An app stays in the session for `sessionLength` after it was last
/// launched or brought to the front, so apps in active use keep pairing with later launches.
///
/// Pure value logic with the time passed in, so it can be tested without waiting.
public struct UsageTracker: Sendable {
    /// Ten minutes.
    public static let defaultSessionLength: TimeInterval = 600

    /// System processes that launch on their own and would only add noise.
    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.systemuiserver",
        "com.apple.windowmanager",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.apple.finder",
    ]
    /// Helper processes of system frameworks, and the standalone groups' own apps, which run as
    /// regular apps while their Dock menus are on.
    static let excludedBundleIdentifierPrefixes = [
        "com.apple.webkit.",
        "com.apple.security.",
        "com.apple.accessibility.",
        AgentIdentity.bundleIdentifierPrefix,
    ]

    /// Whether launches of the app with this bundle identifier are recorded at all.
    public static func isTracked(bundleIdentifier: String) -> Bool {
        let key = UsageStats.key(for: bundleIdentifier)
        guard !key.isEmpty, !excludedBundleIdentifiers.contains(key) else { return false }
        return !excludedBundleIdentifierPrefixes.contains { key.hasPrefix($0) }
    }

    public private(set) var stats: UsageStats
    /// Seconds an app stays in the session after its last launch or activation.
    public var sessionLength: TimeInterval
    /// The apps of the current session (lowercased bundle identifiers) and when each was last
    /// launched or brought to the front. Not saved: a session ends with the app.
    public private(set) var session: [String: Date] = [:]

    public init(stats: UsageStats = UsageStats(), sessionLength: TimeInterval = UsageTracker.defaultSessionLength) {
        self.stats = stats
        self.sessionLength = sessionLength
    }

    /// Records that `app` was launched at `date`. Returns `false` (and changes nothing) for apps
    /// that aren't tracked.
    @discardableResult
    public mutating func recordLaunch(of app: AppReference, at date: Date) -> Bool {
        guard Self.isTracked(bundleIdentifier: app.bundleIdentifier) else { return false }
        let key = UsageStats.key(for: app.bundleIdentifier)
        endExpiredSessionEntries(at: date)

        var usage = stats.apps[key] ?? AppUsage(app: app, launchCount: 0)
        usage.launchCount += 1
        usage.lastLaunchedAt = date
        // Keep the latest name and location, falling back to what was known before.
        usage.app = AppReference(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name.isEmpty ? usage.app.name : app.name,
            path: app.path ?? usage.app.path
        )
        stats.apps[key] = usage

        // An app launched again within its session was already paired with the others.
        if session[key] == nil {
            for partner in session.keys {
                stats.cooccurrence[key, default: [:]][partner, default: 0] += 1
                stats.cooccurrence[partner, default: [:]][key, default: 0] += 1
            }
        }
        session[key] = date
        return true
    }

    /// Records that a running app came to the front at `date`: an app of the current session stays
    /// in it longer. Activations aren't launches, so nothing is counted.
    public mutating func recordActivation(bundleIdentifier: String, at date: Date) {
        endExpiredSessionEntries(at: date)
        let key = UsageStats.key(for: bundleIdentifier)
        guard let last = session[key], date > last else { return }
        session[key] = date
    }

    /// Forgets all statistics and the current session.
    public mutating func reset() {
        stats = UsageStats()
        session = [:]
    }

    /// The apps that are still in the session at `date`.
    public func sessionMembers(at date: Date) -> Set<String> {
        Set(session.filter { isInSession($0.value, at: date) }.keys)
    }

    private mutating func endExpiredSessionEntries(at date: Date) {
        session = session.filter { isInSession($0.value, at: date) }
    }

    private func isInSession(_ lastSeen: Date, at date: Date) -> Bool {
        date.timeIntervalSince(lastSeen) <= sessionLength
    }
}
