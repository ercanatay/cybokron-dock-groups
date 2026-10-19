import Foundation

/// A request made through the app's URL scheme. Groups are named by their name — any spelling
/// with the same slug, see `GroupLookup` — or by their identifier:
///
/// | URL | Command |
/// | --- | --- |
/// | `cybokrondockgroups://open/<group>` (or `show/<group>`) | Show the group's popup |
/// | `cybokrondockgroups://launch/<group>` | Open All |
/// | `cybokrondockgroups://quit/<group>` (`?mode=force` to force quit) | Close All |
/// | `cybokrondockgroups://hide/<group>` | Hide All |
/// | `cybokrondockgroups://shortcut/<1…9>` | Show the popup of the group with that shortcut |
/// | `cybokrondockgroups://close` | Close the popup |
/// | `cybokrondockgroups://settings` | Open Settings |
/// | `cybokrondockgroups://groups` | Open the group window |
public enum URLCommand: Hashable, Sendable {
    case showGroup(String)
    case launchGroup(String)
    case quitGroup(String, QuitMode)
    case hideGroup(String)
    case showShortcut(Int)
    case closePopup
    case openSettings
    case manageGroups

    public static let scheme = "cybokrondockgroups"

    /// Parses `url`; `nil` for other schemes, unknown commands and missing or extra arguments.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // In "cybokrondockgroups://open/work" the command is the host and the group the path; the
        // form without slashes ("cybokrondockgroups:open/work") has everything in the path.
        let segments = ([components.percentEncodedHost ?? ""] + components.percentEncodedPath.components(separatedBy: "/"))
            .filter { !$0.isEmpty }
            .map { $0.removingPercentEncoding ?? $0 }
        guard let verb = segments.first?.lowercased() else { return nil }
        let argument = segments.dropFirst().joined(separator: "/")
        let mode = components.queryItems?.first { $0.name.lowercased() == "mode" }?.value?.lowercased()

        switch verb {
        case "open", "show":
            guard !argument.isEmpty else { return nil }
            self = .showGroup(argument)
        case "launch":
            guard !argument.isEmpty else { return nil }
            self = .launchGroup(argument)
        case "quit":
            guard !argument.isEmpty else { return nil }
            self = .quitGroup(argument, mode == "force" ? .force : .graceful)
        case "hide":
            guard !argument.isEmpty else { return nil }
            self = .hideGroup(argument)
        case "shortcut":
            guard let digit = Int(argument), GroupShortcuts.digits.contains(digit) else { return nil }
            self = .showShortcut(digit)
        case "close":
            guard argument.isEmpty else { return nil }
            self = .closePopup
        case "settings":
            guard argument.isEmpty else { return nil }
            self = .openSettings
        case "groups":
            guard argument.isEmpty else { return nil }
            self = .manageGroups
        default:
            return nil
        }
    }

    /// Identifies the request for the activation cooldown: URLs naming the same group in different
    /// spellings ("open/Work", "open/work") are the same request.
    public var throttleKey: String {
        switch self {
        case .showGroup(let group): return "show/\(GroupLookup.normalizedToken(group))"
        case .launchGroup(let group): return "launch/\(GroupLookup.normalizedToken(group))"
        case .quitGroup(let group, let mode): return "quit/\(GroupLookup.normalizedToken(group))?\(mode.rawValue)"
        case .hideGroup(let group): return "hide/\(GroupLookup.normalizedToken(group))"
        case .showShortcut(let digit): return "shortcut/\(digit)"
        case .closePopup: return "close"
        case .openSettings: return "settings"
        case .manageGroups: return "groups"
        }
    }
}

/// Swallows repeats of a request within a cooldown, such as the URL scheme's activation cooldown.
public struct CommandThrottle: Sendable {
    /// Cooldown of URL requests, in seconds.
    public static let urlCooldown: TimeInterval = 5

    public let interval: TimeInterval
    private var lastAccepted: [String: Date] = [:]

    public init(interval: TimeInterval = CommandThrottle.urlCooldown) {
        self.interval = interval
    }

    /// Returns `true` and starts a cooldown for `key` unless the same key was accepted less than
    /// `interval` ago; then it returns `false`, and the swallowed repeat doesn't extend the cooldown.
    public mutating func accept(_ key: String, at now: Date = Date()) -> Bool {
        lastAccepted = lastAccepted.filter { isCoolingDown(since: $0.value, now: now) }
        if let last = lastAccepted[key], isCoolingDown(since: last, now: now) {
            return false
        }
        lastAccepted[key] = now
        return true
    }

    /// Starts `key`'s cooldown again at `now`, e.g. once a question the request asked is answered:
    /// repeats that arrived meanwhile, or right after, are swallowed instead of asking again.
    public mutating func restartCooldown(for key: String, at now: Date = Date()) {
        lastAccepted[key] = now
    }

    /// A clock that went backwards ends the cooldown rather than extending it.
    private func isCoolingDown(since accepted: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(accepted)
        return elapsed >= 0 && elapsed < interval
    }
}
