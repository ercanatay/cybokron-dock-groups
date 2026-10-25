import Foundation

/// How the app was opened, as the trigger controller tells after its launch settled (triggers spec
/// §2.5).
public enum LaunchKind: Hashable, Sendable {
    /// Opened at login; `session` is when the login session began, so At Login runs once per session.
    case login(session: Date)
    /// Opened by the user (Finder, the Dock, Spotlight).
    case normal
    /// Opened to handle a link or a Siri or Shortcuts request, or again after an update or a
    /// language change: no launch trigger runs.
    case quiet
}

/// The Wi-Fi network, as far as the app can tell.
public enum WiFiReading: Hashable, Sendable {
    /// The name can't be read (no Location access, access taken back, macOS redacting it): never an
    /// edge (spec §1.5, "Unknown never makes an edge").
    case unknown
    /// Not on any Wi-Fi network (Wi-Fi off, or Ethernet only).
    case notConnected
    case connected(WiFiNetworkName)
}

/// The network once it settled (spec §1.5). `nil` values are unknown and change nothing.
public struct NetworkReading: Hashable, Sendable {
    public var usesEthernet: Bool?
    public var wifi: WiFiReading
    /// Whether the primary network service is a tunnel (a VPN); `nil` when that can't be told.
    public var tunnelIsPrimary: Bool?

    public init(usesEthernet: Bool? = nil, wifi: WiFiReading = .unknown, tunnelIsPrimary: Bool? = nil) {
        self.usesEthernet = usesEthernet
        self.wifi = wifi
        self.tunnelIsPrimary = tunnelIsPrimary
    }

    /// Nothing known.
    public static let unknown = NetworkReading()
}

/// What the system sources report (spec §2.2): plain values, so every rule can be tested without
/// AppKit, CoreGraphics or the network.
public enum TriggerSignal: Hashable, Sendable {
    /// The clock: the timer for the next due time fired, or times must be looked at again (a wake,
    /// a day, clock or time zone change). The moment is the evaluator's `now`.
    case clock
    /// The app was opened, once its launch settled.
    case launched(LaunchKind)
    /// The displays went to sleep or woke.
    case screens(asleep: Bool)
    /// The user's session became the active one, or stopped being it (fast user switching).
    case session(active: Bool)
    /// The displays connected, once they settled; `nil` when they couldn't be read.
    case displays([DisplayIdentity]?)
    /// The network, once it settled.
    case network(NetworkReading)
}

extension TriggerCondition {
    /// What `signal` says about this condition.
    enum Reading: Equatable {
        /// The signal isn't about it.
        case notConcerned
        /// It can't be told now: nothing changes.
        case unknown
        /// How many times it holds: matching displays, or 0 and 1 for the others.
        case value(Int)
    }

    func reading(in signal: TriggerSignal) -> Reading {
        switch (self, signal) {
        case (.display, .displays(nil)), (.displays, .displays(nil)):
            return .unknown
        case (.display(let match), .displays(let displays?)):
            return .value(match.count(in: displays))
        case (.displays(let arrangement), .displays(let displays?)):
            return .value(arrangement.matches(displays) ? 1 : 0)
        case (.wifi(let name), .network(let network)):
            switch network.wifi {
            case .unknown: return .unknown
            case .notConnected: return .value(0)
            case .connected(let current): return .value(current.name == name.name ? 1 : 0)
            }
        case (.ethernet, .network(let network)):
            return network.usesEthernet.map { .value($0 ? 1 : 0) } ?? .unknown
        case (.vpn, .network(let network)):
            return network.tunnelIsPrimary.map { .value($0 ? 1 : 0) } ?? .unknown
        default:
            return .notConcerned
        }
    }
}
