import Foundation

/// The order apps were brought to the front while this app runs, the most recent first, for
/// capturing the open apps "most recently used first". It holds identities only — no times — in
/// memory only: it's never saved, and it's gone when the app quits.
///
/// Identities are as group items match running apps (`RunningAppSnapshot.identity`): a lowercased
/// bundle identifier, or the normalized location of an app without one.
public struct ActivationHistory: Equatable, Sendable {
    /// The most identities kept; the least recent ones go first.
    public static let maximumCount = 200

    /// Most recent first, each once.
    public private(set) var recentIdentities: [String]

    /// A history with `identities` in that order, the most recent first: lowercased, each once
    /// (its most recent place), at most `maximumCount`, empty ones left out. Seeded at launch with
    /// the app in front.
    public init(recentIdentities identities: [String] = []) {
        var seen = Set<String>()
        var kept: [String] = []
        for identity in identities.map({ $0.lowercased() }) where kept.count < Self.maximumCount {
            if !identity.isEmpty, seen.insert(identity).inserted {
                kept.append(identity)
            }
        }
        recentIdentities = kept
    }

    /// The app with `identity` came to the front: it's the most recent one now.
    public mutating func recordActivation(ofIdentity identity: String) {
        let identity = identity.lowercased()
        guard !identity.isEmpty else { return }
        recentIdentities.removeAll { $0 == identity }
        recentIdentities.insert(identity, at: 0)
        if recentIdentities.count > Self.maximumCount {
            recentIdentities.removeLast(recentIdentities.count - Self.maximumCount)
        }
    }

    /// Where the app with `identity` stands, 0 for the most recent; `nil` when it hasn't come to the
    /// front since this app started (or fell out of the history).
    public func rank(ofIdentity identity: String) -> Int? {
        recentIdentities.firstIndex(of: identity.lowercased())
    }

    /// Every identity's rank at once, for ordering many apps.
    var ranks: [String: Int] {
        Dictionary(uniqueKeysWithValues: recentIdentities.enumerated().map { ($0.element, $0.offset) })
    }
}
