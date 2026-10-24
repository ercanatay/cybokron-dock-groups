import Foundation

/// The question a link, Siri or Shortcuts asks before a transition quits apps (spec §2.5): which
/// group, which apps, and what else stays open. A link's question (the app's alert) can also hide
/// the apps instead; Siri and Shortcuts ask yes or no (`intentDialog`).
public struct TransitionConfirmation: Equatable, Sendable {
    /// What the user chose.
    public enum Answer: Equatable, Sendable {
        /// Quit the apps, as planned.
        case quit
        /// Hide them instead of quitting them (`TransitionPlanner.hidingInsteadOfQuitting`).
        case hideInstead
        /// Do nothing.
        case cancel
    }

    public enum Kind: Equatable, Sendable {
        /// Starting `group`, which quits apps of `previousGroup`.
        case start(group: String, previousGroup: String)
        /// Finishing `group`, going back to `nextGroup` (if any).
        case finish(group: String, nextGroup: String?)
    }

    /// How long the quit button stays disabled after the question appears, as for Close All's
    /// question (`QuitConfirmation.confirmButtonDelay`).
    public static let confirmButtonDelay = QuitConfirmation.confirmButtonDelay

    public let kind: Kind
    /// The apps it would quit, by the names they're shown with.
    public let appNames: [String]

    public init(kind: Kind, appNames: [String]) {
        self.kind = kind
        self.appNames = appNames
    }

    /// The question for `plan`; `nil` when it doesn't quit anything.
    public init?(plan: TransitionPlan) {
        guard plan.quitsAnything else { return nil }
        let names = plan.quit.map(\.app.name)
        switch plan.kind {
        case .start:
            self.init(kind: .start(group: plan.groupName, previousGroup: plan.otherGroupName ?? ""), appNames: names)
        case .finish:
            self.init(kind: .finish(group: plan.groupName, nextGroup: plan.otherGroupName), appNames: names)
        }
    }

    public var title: String {
        let count = appNames.count
        switch kind {
        case .start(let group, _):
            return count == 1
                ? Localization.format("core.switching.start.title.one", "Switch to “%@” and quit 1 app?", group)
                : Localization.format("core.switching.start.title.other", "Switch to “%1$@” and quit %2$ld apps?", group, count)
        case .finish(let group, _):
            return count == 1
                ? Localization.format("core.switching.finish.title.one", "Finish “%@” and quit 1 app?", group)
                : Localization.format("core.switching.finish.title.other", "Finish “%1$@” and quit %2$ld apps?", group, count)
        }
    }

    /// Which apps quit, and what stays open.
    public var detail: String {
        let names = appNames.joined(separator: ", ")
        switch kind {
        case .start(let group, let previousGroup):
            return Localization.format(
                "core.switching.start.detail",
                "“%1$@” is set to quit the apps of “%2$@” it doesn't use: %3$@.",
                group, previousGroup, names
            )
        case .finish(let group, let nextGroup):
            guard let nextGroup else {
                return Localization.format("core.switching.finish.detail", "Finishing “%1$@” quits %2$@. Protected apps stay open.", group, names)
            }
            return Localization.format(
                "core.switching.finish.detailWithNext",
                "Finishing “%1$@” quits %2$@. Protected apps and apps “%3$@” uses stay open.",
                group, names, nextGroup
            )
        }
    }

    /// The app's alert for a link: the detail, where the request came from, and that apps can
    /// still ask to save changes.
    public var message: String {
        [
            detail,
            Localization.string("core.switching.confirmation.link", "A link opened by another app, a script or a web page asked for this."),
            Localization.string("core.switching.confirmation.save", "Apps can still ask to save changes."),
        ].joined(separator: "\n\n")
    }

    /// What Siri or Shortcuts asks: the title and the detail. Not where the request came from:
    /// the user asked.
    public var intentDialog: String {
        "\(title)\n\n\(detail)"
    }

    public var confirmButton: String {
        switch kind {
        case .start: return Localization.string("core.switching.confirmation.quitAndSwitch", "Quit and Switch")
        case .finish: return Localization.string("core.quitConfirmation.quit", "Quit Apps")
        }
    }

    public var hideInsteadButton: String {
        Localization.string("core.switching.confirmation.hideInstead", "Hide Instead")
    }

    public var cancelButton: String {
        Localization.string("core.quitConfirmation.cancel", "Cancel")
    }
}

/// Asks the user a link's question before a transition quits apps; the app shows an alert.
@MainActor
public protocol TransitionConfirmationPrompting: AnyObject {
    func confirm(_ confirmation: TransitionConfirmation) -> TransitionConfirmation.Answer
}

/// Asks a link's question before a transition, one at a time with the other questions links ask:
/// `GroupQuitRequests` does, so a link can't stack a transition question on a quit question.
@MainActor
public protocol TransitionQuestioning: AnyObject {
    /// The user's answer; `nil` when the question was dropped because another link's question is
    /// showing.
    func askBeforeTransition(_ confirmation: TransitionConfirmation) -> TransitionConfirmation.Answer?
}
