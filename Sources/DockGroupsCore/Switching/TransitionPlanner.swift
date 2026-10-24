import Foundation

/// Who asked for a transition; it decides whether apps may be quit, and whether the user is asked
/// first (spec §2.5).
public enum TransitionTrigger: String, Sendable, CaseIterable {
    /// The user's click: in the popup, the menu bar menu or the group window.
    case userAction
    /// A `cybokrondockgroups://start/…`, `switch/…` or `finish/…` link, which any app, script or
    /// web page can open.
    case link
    /// Siri or the Shortcuts app.
    case intent
    /// A Focus that turned on or off: an automatic trigger nobody watches.
    case focus

    /// A Focus never quits apps: its quitting settings act as hiding.
    public var mayQuit: Bool { self != .focus }

    /// A link, Siri and Shortcuts ask before a transition quits anything; the user's own click
    /// doesn't (the user chose the setting and clicked, as with Close All).
    public var asksBeforeQuitting: Bool { self == .link || self == .intent }
}

/// What a transition will do, app by app, and why: planned before anything happens
/// (`TransitionPlanner`), so it can be asked about, tested and reported.
public struct TransitionPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case start(DockGroup.ID)
        case finish(DockGroup.ID)
    }

    /// Why an app is in one of the plan's lists.
    public enum Reason: Equatable, Sendable {
        /// Hidden or quit: it's in the group that was current, and Start puts that group away.
        case inPreviousGroup
        /// Hidden: it's not in the group being started ("Hide all other apps").
        case notInStartedGroup
        /// Hidden or quit: it's in the group being finished.
        case inFinishedGroup
        /// Shown again: it's in the group Finish goes back to.
        case inNextGroup
        /// Left alone: the user protected it (`ProtectedApps`).
        case protected
        /// Left alone: it's this app, one of its groups' own apps, or Finder (never quit).
        case alwaysProtected
        /// Left alone: the group brought forward uses it too.
        case shared
    }

    public struct Entry: Equatable, Sendable {
        public let app: RunningAppSnapshot
        public let reason: Reason

        public init(app: RunningAppSnapshot, reason: Reason) {
            self.app = app
            self.reason = reason
        }
    }

    public let kind: Kind
    public let trigger: TransitionTrigger
    /// The group being started or finished.
    public let groupName: String
    /// The group put away by Start, or brought back by Finish; `nil` when there's none.
    public let otherGroupName: String?
    public internal(set) var hide: [Entry] = []
    /// Asked to quit, gracefully: apps can still ask to save changes. Never forced.
    public internal(set) var quit: [Entry] = []
    /// Shown again (Finish, the group it goes back to). Nothing is launched.
    public internal(set) var unhide: [Entry] = []
    /// Brought to the front after showing the group Finish goes back to.
    public internal(set) var front: RunningAppSnapshot?
    /// Apps the settings would have hidden or quit but that are left alone, and why.
    public internal(set) var kept: [Entry] = []
    /// Start: the group whose items open, as Open All opens them.
    public internal(set) var open: DockGroup?
    /// The group that's current once the transition is done; `nil` when none is.
    public internal(set) var next: DockGroup.ID?

    public var quitsAnything: Bool { !quit.isEmpty }

    /// Whether the user is asked before the plan is carried out: it quits apps, and a link, Siri or
    /// Shortcuts asked for it.
    public var requiresConfirmation: Bool { quitsAnything && trigger.asksBeforeQuitting }

    /// Whether carrying the plan out changes nothing but the current group.
    public var changesNoApps: Bool { hide.isEmpty && quit.isEmpty && unhide.isEmpty && front == nil && open == nil }
}

/// Plans Start and Finish (spec §2.2, §2.3, §3.3). Pure: it gets the running apps as a snapshot,
/// reads nothing and changes nothing, so every safety rule is a property of the plan:
///
/// 1. Only regular apps are considered (no agents, helpers or background processes).
/// 2. An app is in a group when one of the group's app items has its identity (case-insensitive,
///    apps without a bundle identifier by their location); websites, files and folders have no
///    process.
/// 3. Never hidden or quit: this app and its groups' own apps, protected apps, and apps the group
///    brought forward uses too. Never quit: Finder.
/// 4. A trigger that may not quit (a Focus) turns quitting into hiding.
/// 5. An app that's already hidden isn't hidden again; only hidden apps are shown again.
/// 6. Lists follow the group's item order ("Hide all other apps": the running order).
public enum TransitionPlanner {
    /// Starting `target` while `previous` is current (`nil`: no group is, or it's `target` itself).
    public static func start(
        _ target: DockGroup,
        previous: DockGroup?,
        running: [RunningAppSnapshot],
        protected: ProtectedApps,
        trigger: TransitionTrigger
    ) -> TransitionPlan {
        let previous = previous?.id == target.id ? nil : previous
        let settings = trigger.mayQuit ? target.switching : target.switching.withoutQuitting
        var plan = TransitionPlan(kind: .start(target.id), trigger: trigger, groupName: target.name, otherGroupName: previous?.name)
        plan.open = target
        plan.next = target.id
        let candidates = considered(running)
        let targetIdentities = identities(of: target)

        switch settings.onStart {
        case .leaveOthers:
            break
        case .hidePreviousGroup, .quitPreviousGroup:
            guard let previous else { break }
            let action: Action = settings.onStart == .quitPreviousGroup ? .quit : .hide
            for app in instances(of: previous, in: candidates) {
                if targetIdentities.contains(app.identity) {
                    plan.kept.append(.init(app: app, reason: .shared))
                } else {
                    place(app, action: action, reason: .inPreviousGroup, protected: protected, in: &plan)
                }
            }
        case .hideAllOtherApps:
            for app in candidates where !targetIdentities.contains(app.identity) {
                place(app, action: .hide, reason: .notInStartedGroup, protected: protected, in: &plan)
            }
        }
        return plan
    }

    /// Finishing `group`, going back to `next` (`nil`: to no group).
    public static func finish(
        _ group: DockGroup,
        next: DockGroup?,
        running: [RunningAppSnapshot],
        protected: ProtectedApps,
        trigger: TransitionTrigger
    ) -> TransitionPlan {
        let next = next?.id == group.id ? nil : next
        let settings = trigger.mayQuit ? group.switching : group.switching.withoutQuitting
        var plan = TransitionPlan(kind: .finish(group.id), trigger: trigger, groupName: group.name, otherGroupName: next?.name)
        plan.next = next?.id
        let candidates = considered(running)
        let nextIdentities = next.map(identities(of:)) ?? []

        let action: Action?
        switch settings.onFinish {
        case .hideApps: action = .hide
        case .quitApps: action = .quit
        case .leaveApps: action = nil
        }
        if let action {
            for app in instances(of: group, in: candidates) {
                if nextIdentities.contains(app.identity) {
                    plan.kept.append(.init(app: app, reason: .shared))
                } else {
                    place(app, action: action, reason: .inFinishedGroup, protected: protected, in: &plan)
                }
            }
        }
        if let next {
            let shown = instances(of: next, in: candidates).filter {
                !ProtectedApps.isAlwaysProtected(identity: $0.identity, action: .hiding)
            }
            plan.unhide = shown.filter(\.isHidden).map { .init(app: $0, reason: .inNextGroup) }
            plan.front = shown.first
        }
        return plan
    }

    /// The same plan with every quit turned into hiding ("Hide Instead"); apps that are already
    /// hidden are left as they are.
    public static func hidingInsteadOfQuitting(_ plan: TransitionPlan) -> TransitionPlan {
        var plan = plan
        plan.hide += plan.quit.filter { !$0.app.isHidden }
        plan.quit = []
        return plan
    }

    // MARK: - Helpers

    private enum Action {
        case hide, quit
    }

    /// Puts `app` in the plan's list for `action`, or keeps it when it's protected from it.
    private static func place(_ app: RunningAppSnapshot, action: Action, reason: TransitionPlan.Reason, protected: ProtectedApps, in plan: inout TransitionPlan) {
        let protectedAction: ProtectedApps.Action = action == .quit ? .quitting : .hiding
        switch protected.reason(forIdentity: app.identity, action: protectedAction) {
        case .always:
            plan.kept.append(.init(app: app, reason: .alwaysProtected))
        case .listed:
            plan.kept.append(.init(app: app, reason: .protected))
        case nil:
            switch action {
            case .hide:
                if !app.isHidden { plan.hide.append(.init(app: app, reason: reason)) }
            case .quit:
                plan.quit.append(.init(app: app, reason: reason))
            }
        }
    }

    /// The running regular apps, each process once.
    private static func considered(_ running: [RunningAppSnapshot]) -> [RunningAppSnapshot] {
        var seen = Set<pid_t>()
        return running.filter { $0.isRegular && seen.insert($0.processIdentifier).inserted }
    }

    /// The identities of the group's app items: only apps have processes.
    private static func identities(of group: DockGroup) -> Set<String> {
        Set(group.apps.filter { $0.kind.hasProcess }.map(\.normalizedBundleIdentifier))
    }

    /// The running instances of the group's apps, in the group's item order (instances of one app
    /// in the running order).
    private static func instances(of group: DockGroup, in running: [RunningAppSnapshot]) -> [RunningAppSnapshot] {
        var listed = Set<String>()
        var result: [RunningAppSnapshot] = []
        for item in group.apps where item.kind.hasProcess && listed.insert(item.normalizedBundleIdentifier).inserted {
            result += running.filter { $0.identity == item.normalizedBundleIdentifier }
        }
        return result
    }
}
