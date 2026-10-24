import Foundation
import OSLog

/// What a Focus filter asks for when its Focus turns on (spec §2.10). Only these three: a Focus never
/// quits or finishes anything on its own — its one other choice is to finish, by hiding, the group it
/// started when it turns off (`FocusRequest.finishesWhenFocusEnds`).
///
/// The raw values are what macOS keeps in its Focus settings (the filter's `AppEnum`): never change
/// them.
public enum FocusGroupAction: String, Codable, CaseIterable, Sendable {
    /// Start the group (`ContextSwitcher.start`, trigger `.focus`: quitting acts as hiding).
    case start
    /// Open All, without putting anything away.
    case openAll
    /// Show the group's popup.
    case showPopup
}

/// One call of the Focus filter: when its Focus turns on, the group it names and what to do; when the
/// Focus turns off, the defaults (no group).
public struct FocusRequest: Equatable, Sendable {
    /// `nil` when the Focus turned off, or the filter names no group.
    public let groupID: DockGroup.ID?
    public let action: FocusGroupAction
    /// Whether the group the Focus started is finished when the Focus turns off (off by default,
    /// DECISION 3).
    public let finishesWhenFocusEnds: Bool

    public init(groupID: DockGroup.ID?, action: FocusGroupAction = .start, finishesWhenFocusEnds: Bool = false) {
        self.groupID = groupID
        self.action = action
        self.finishesWhenFocusEnds = finishesWhenFocusEnds
    }

    /// The defaults the system sends when the Focus turns off.
    public static let focusEnded = FocusRequest(groupID: nil)
}

/// What a Focus request is carried out with: the app's groups, its current group and its commands.
/// The coordinator always passes `.focus` as the trigger, so nothing a Focus asks for quits an app.
@MainActor
public protocol FocusRequestHandling: AnyObject {
    func group(withID id: DockGroup.ID) -> DockGroup?
    /// The current group (`ContextSession.current`) and who started it.
    var currentGroupID: DockGroup.ID? { get }
    var currentGroupStartTrigger: TransitionTrigger? { get }
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async
    func openAllItems(of group: DockGroup) async
    func showPopup(of group: DockGroup)
}

/// Turns the calls of the Focus filter into at most one action per Focus change (spec §3.6): each
/// call (re)starts a 1-second wait, so a switch from one Focus to another, or off and on again,
/// comes down to the last call. Then:
///
/// - **No group** (the Focus turned off): the group a Focus started is finished — by hiding — only
///   when that Focus's filter asked for it and the group is still current.
/// - **A group**: a group the previous Focus started is finished first when its filter asked for it,
///   it's still current and it isn't this group (without showing the group before it: another one
///   is about to start); then the group is started, opened or shown. Starting it again within
///   `ContextSession.repeatInterval` does nothing, whoever asked (a Shortcuts automation starting it
///   too, for example), and so does opening or showing it again within that time.
///
/// Calls that arrive before the app is ready (no `handler` yet) are kept — the last one — and carried
/// out once it is. Requests are carried out one at a time. Nothing is polled: one wait per call, and
/// nothing is written: Focus pairings are macOS's.
@MainActor
public final class FocusRequestCoordinator {
    /// How long a call waits for the next one before it's carried out.
    public static let settleInterval: Duration = .seconds(1)

    /// Carries the requests out; until it's set, the last request waits.
    public weak var handler: FocusRequestHandling? {
        didSet {
            guard handler != nil, let waiting else { return }
            self.waiting = nil
            enqueue(waiting)
        }
    }

    /// The last request received, carried out or not.
    public private(set) var lastRequest: FocusRequest?

    private let sleeper: Sleeping
    private let clock: () -> Date
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Focus")
    /// Bumped by every call: only the wait of the last one carries it out.
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    /// The request settled before the app was ready.
    private var waiting: FocusRequest?
    /// The request being carried out, so the next one waits for it.
    private var carrying: Task<Void, Never>?
    /// Bumped for every request carried out, so only the last one clears `carrying`.
    private var carryingNumber = 0
    /// The Focus request that started the current group, while that group is current.
    private var startedBy: FocusRequest?
    /// Open All and Show Popup carried out last, for the repeat rule.
    private var lastCarriedOut: (request: FocusRequest, date: Date)?

    public init(sleeper: Sleeping? = nil, clock: @escaping () -> Date = Date.init) {
        self.sleeper = sleeper ?? TaskSleeping()
        self.clock = clock
    }

    /// The Focus filter was called.
    public func receive(_ request: FocusRequest) {
        lastRequest = request
        generation += 1
        let current = generation
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper.sleep(for: Self.settleInterval)
            } catch {
                return
            }
            guard current == self.generation else { return }
            self.settled(request)
        }
    }

    /// Whether nothing is settling or being carried out (a request may still wait for the app to be
    /// ready).
    public var isIdle: Bool { settleTask == nil && carrying == nil }

    private func settled(_ request: FocusRequest) {
        settleTask = nil
        guard handler != nil else {
            logger.notice("A Focus request arrived before the app was ready: kept")
            waiting = request
            return
        }
        enqueue(request)
    }

    private func enqueue(_ request: FocusRequest) {
        let previous = carrying
        carryingNumber += 1
        let number = carryingNumber
        carrying = Task { @MainActor [weak self] in
            await previous?.value
            await self?.carryOut(request)
            if self?.carryingNumber == number { self?.carrying = nil }
        }
    }

    private func carryOut(_ request: FocusRequest) async {
        guard let handler else {
            waiting = request
            return
        }
        // The group a Focus started, while it's still current and was started by a Focus.
        let focusStarted = startedBy.flatMap { started -> FocusRequest? in
            guard let id = started.groupID, handler.currentGroupID == id, handler.currentGroupStartTrigger == .focus else { return nil }
            return started
        }
        guard let id = request.groupID else {
            startedBy = nil
            if let focusStarted, focusStarted.finishesWhenFocusEnds, let startedID = focusStarted.groupID {
                logger.notice("Focus ended: finishing group \(startedID, privacy: .public)")
                await handler.finishGroup(startedID, trigger: .focus, showsPrevious: true)
            } else {
                logger.debug("Focus ended: nothing to do")
            }
            return
        }
        guard let group = handler.group(withID: id) else {
            logger.error("A Focus asked for group \(id, privacy: .public), which doesn't exist (any more): nothing done")
            return
        }
        if let focusStarted, focusStarted.finishesWhenFocusEnds, let startedID = focusStarted.groupID, startedID != id {
            logger.notice("Focus changed: finishing group \(startedID, privacy: .public) first")
            await handler.finishGroup(startedID, trigger: .focus, showsPrevious: false)
        }
        switch request.action {
        case .start:
            await handler.startGroup(id, trigger: .focus)
            startedBy = handler.currentGroupID == id ? request : nil
        case .openAll, .showPopup:
            if let last = lastCarriedOut, last.request == request, isRepeat(since: last.date) {
                logger.notice("Focus asked again for \(request.action.rawValue, privacy: .public) of group \(id, privacy: .public): just done")
                return
            }
            lastCarriedOut = (request, clock())
            startedBy = nil
            if request.action == .openAll {
                await handler.openAllItems(of: group)
            } else {
                handler.showPopup(of: group)
            }
        }
    }

    /// Whether a request carried out at `date` was carried out just now (`ContextSession.repeatInterval`).
    private func isRepeat(since date: Date) -> Bool {
        let elapsed = clock().timeIntervalSince(date)
        return elapsed >= 0 && elapsed < ContextSession.repeatInterval
    }
}

/// What Settings → Switching → Focus says the current Focus asks of the app (spec §2.10). macOS
/// doesn't tell the app which Focus is on, only its filter's values, so the text never names the
/// Focus.
public enum FocusFilterStatus: Equatable, Sendable {
    /// No Focus with this app's filter is on (or the filter couldn't be read).
    case none
    /// The current Focus's filter names a group that doesn't exist (any more).
    case unknownGroup
    /// The current Focus does `action` with the group of this name.
    case group(name: String, action: FocusGroupAction, finishesWhenFocusEnds: Bool)

    /// The status of `request` — the filter's current values — among `groups`.
    public init(_ request: FocusRequest?, groups: [DockGroup]) {
        guard let request, let id = request.groupID else {
            self = .none
            return
        }
        guard let group = groups.first(where: { $0.id == id }) else {
            self = .unknownGroup
            return
        }
        self = .group(name: group.name, action: request.action, finishesWhenFocusEnds: request.finishesWhenFocusEnds)
    }

    public var text: String {
        switch self {
        case .none:
            return Localization.string("switching.focus.status.none", "No Focus asks Cybokron Dock Groups for anything right now.")
        case .unknownGroup:
            return Localization.string("switching.focus.status.unknownGroup", "The current Focus names a group that no longer exists.")
        case .group(let name, let action, let finishes):
            let sentence: String
            switch action {
            case .start: sentence = Localization.format("switching.focus.status.start", "The current Focus starts “%@”.", name)
            case .openAll: sentence = Localization.format("switching.focus.status.openAll", "The current Focus opens the items of “%@”.", name)
            case .showPopup: sentence = Localization.format("switching.focus.status.showPopup", "The current Focus shows the popup of “%@”.", name)
            }
            guard finishes, action == .start else { return sentence }
            return sentence + " " + Localization.string("switching.focus.status.finishes", "When it turns off, the group is finished: its apps are hidden.")
        }
    }
}
