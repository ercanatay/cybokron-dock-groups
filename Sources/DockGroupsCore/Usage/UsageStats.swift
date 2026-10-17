import Foundation

/// How often one app has been launched, and how to find it again.
public struct AppUsage: Hashable, Sendable {
    /// The app as last seen launching: its bundle identifier, name and location.
    public var app: AppReference
    public var launchCount: Int
    public var lastLaunchedAt: Date?

    public init(app: AppReference, launchCount: Int, lastLaunchedAt: Date? = nil) {
        self.app = app
        self.launchCount = launchCount
        self.lastLaunchedAt = lastLaunchedAt
    }
}

/// Everything the Most Used list is computed from: per-app launch counts, and how often two apps
/// were launched in the same session.
///
/// Both maps are keyed by lowercased bundle identifier, because LaunchServices treats bundle
/// identifiers case-insensitively.
public struct UsageStats: Hashable, Sendable {
    public var apps: [String: AppUsage]
    /// `cooccurrence[a][b]` counts the sessions in which `a` and `b` were both launched. The graph
    /// is kept symmetric: every pair is counted in both directions.
    public var cooccurrence: [String: [String: Int]]

    public init(apps: [String: AppUsage] = [:], cooccurrence: [String: [String: Int]] = [:]) {
        self.apps = apps
        self.cooccurrence = cooccurrence
    }

    public var isEmpty: Bool { apps.isEmpty }
    public var totalLaunchCount: Int { apps.values.reduce(0) { $0 + $1.launchCount } }

    public static func key(for bundleIdentifier: String) -> String {
        bundleIdentifier.lowercased()
    }

    /// The number of launches of `key` that happened together with another app's.
    public func cooccurrenceCount(of key: String) -> Int {
        cooccurrence[key]?.values.reduce(0, +) ?? 0
    }
}
