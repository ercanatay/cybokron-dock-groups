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
/// | `cybokrondockgroups://settings/group/<group>` | Open the group window on the group's settings |
/// | `cybokrondockgroups://groups` | Open the group window |
public enum URLCommand: Hashable, Sendable {
    case showGroup(String)
    case launchGroup(String)
    case quitGroup(String, QuitMode)
    case hideGroup(String)
    case showShortcut(Int)
    case closePopup
    case openSettings
    /// The group's settings — name, apps, Dock tile, popup — in the group window
    /// (`GroupSettingsDestination` picks the group to show).
    case showGroupSettings(String)
    case manageGroups

    public static let scheme = "cybokrondockgroups"

    /// The link to `id`'s group settings, as a standalone group's own app opens it: the main app
    /// edits the groups (and is launched by the link when it isn't running).
    public static func groupSettingsURL(for id: UUID) -> URL {
        URL(string: "\(scheme)://settings/group/\(id.uuidString)")!
    }

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
            if argument.isEmpty {
                self = .openSettings
                return
            }
            // "settings/group/<group>"; the group's name may itself contain a slash ("Dev%2FOps").
            let group = segments.dropFirst(2).joined(separator: "/")
            guard segments.count > 2, segments[1].lowercased() == "group", !group.isEmpty else { return nil }
            self = .showGroupSettings(group)
        case "groups":
            guard argument.isEmpty else { return nil }
            self = .manageGroups
        default:
            return nil
        }
    }

    /// The key that links opening or hiding a group's apps share: whichever group they name, only
    /// one of them is carried out per cooldown (`URLCommandGate`), so a page or script can't open
    /// or hide every group in turn. `nil` for the other commands.
    public var groupActionKey: String? {
        switch self {
        case .launchGroup, .hideGroup: return "group-apps"
        default: return nil
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
        case .showGroupSettings(let group): return "settings/group/\(GroupLookup.normalizedToken(group))"
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

    /// Whether `accept(key, at: now)` would return `true`, without starting a cooldown.
    public func wouldAccept(_ key: String, at now: Date = Date()) -> Bool {
        guard let last = lastAccepted[key] else { return true }
        return !isCoolingDown(since: last, now: now)
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

/// Decides which URL scheme requests are carried out. A repeat of the same request within the
/// cooldown is swallowed (`CommandThrottle`); and links that open or hide a group's apps
/// (`URLCommand.groupActionKey`) share one more cooldown, so only one of them runs per
/// `CommandThrottle.urlCooldown`, whichever group it names. Menus, popups, global shortcuts, Siri
/// and Shortcuts don't come through here and aren't limited.
public struct URLCommandGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case accepted
        /// The same request came less than a cooldown ago.
        case repeated
        /// Another link opened or hid a group's apps less than a cooldown ago.
        case groupActionLimited
    }

    private var requests: CommandThrottle
    private var groupActions: CommandThrottle

    public init(interval: TimeInterval = CommandThrottle.urlCooldown) {
        requests = CommandThrottle(interval: interval)
        groupActions = CommandThrottle(interval: interval)
    }

    /// Accepts `command` and starts its cooldowns, or says why it's dropped. A dropped request
    /// starts no cooldown, so it can be sent again as soon as the earlier one's has run out.
    public mutating func accept(_ command: URLCommand, at now: Date = Date()) -> Decision {
        guard requests.wouldAccept(command.throttleKey, at: now) else { return .repeated }
        if let key = command.groupActionKey {
            guard groupActions.wouldAccept(key, at: now) else { return .groupActionLimited }
            _ = groupActions.accept(key, at: now)
        }
        _ = requests.accept(command.throttleKey, at: now)
        return .accepted
    }

    /// Starts `command`'s own cooldown again (see `CommandThrottle.restartCooldown`).
    public mutating func restartCooldown(for command: URLCommand, at now: Date = Date()) {
        requests.restartCooldown(for: command.throttleKey, at: now)
    }
}
