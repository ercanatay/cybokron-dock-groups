import Foundation

/// Where a request to quit a group's apps came from.
public enum QuitRequestSource: String, Sendable, CaseIterable {
    /// A `cybokrondockgroups://quit/…` link. Any app, script or web page can open one, so it asks
    /// first.
    case link
    /// Close All in a popup or a menu: the user's own click.
    case userAction
    /// Siri or the Shortcuts app, which the user asked.
    case intent

    /// Only links ask before quitting anything.
    public var asksFirst: Bool { self == .link }
}

/// The question a link's quit request asks: the group's name, what happens, and — when the link
/// forces — that unsaved changes are lost.
public struct QuitConfirmation: Equatable, Sendable {
    /// How long the quit button stays disabled after the question appears, so a click meant for
    /// whatever was under the pointer (or a double click that opened the link) can't answer it.
    /// Cancel and Escape work right away.
    public static let confirmButtonDelay: TimeInterval = 0.7

    /// Whether the quit button is enabled `elapsed` seconds after the question appeared.
    public static func isConfirmButtonEnabled(after elapsed: TimeInterval) -> Bool {
        elapsed >= confirmButtonDelay
    }

    public let groupName: String
    public let mode: QuitMode

    public init(groupName: String, mode: QuitMode) {
        self.groupName = groupName
        self.mode = mode
    }

    public var title: String {
        Localization.format("core.quitConfirmation.title", "All apps in “%@” will be quit. Continue?", groupName)
    }

    /// Where the request came from, then a separate line for force quitting.
    public var message: String {
        var lines = [Localization.string(
            "core.quitConfirmation.message",
            "A link opened by another app, a script or a web page asked to quit the running apps of this group."
        )]
        if mode == .force {
            lines.append(Localization.string(
                "core.quitConfirmation.force",
                "Force quit: the apps end right away, and unsaved changes are lost."
            ))
        }
        return lines.joined(separator: "\n\n")
    }

    public var confirmButton: String {
        mode == .force
            ? Localization.string("core.quitConfirmation.forceQuit", "Force Quit Apps")
            : Localization.string("core.quitConfirmation.quit", "Quit Apps")
    }

    public var cancelButton: String {
        Localization.string("core.quitConfirmation.cancel", "Cancel")
    }
}

/// Asks the user whether a link may quit a group's apps; the app shows an alert.
@MainActor
public protocol QuitConfirmationPrompting: AnyObject {
    /// `true` only when the user chose to quit the apps.
    func confirm(_ confirmation: QuitConfirmation) -> Bool
}

/// Quits a group's apps on request — asking first when the request came from a link
/// (`QuitRequestSource.asksFirst`), and dropping links that arrive while a question is showing.
@MainActor
public final class GroupQuitRequests {
    public enum Outcome: Equatable, Sendable {
        /// The apps were asked to quit (or forced).
        case quit(QuitReport)
        /// The user chose not to quit them.
        case declined
        /// Another link's question was showing; this request was dropped without asking.
        case dropped

        public var report: QuitReport? {
            if case .quit(let report) = self { return report }
            return nil
        }
    }

    /// Whether a link's question is showing.
    public private(set) var isAsking = false

    private let prompt: QuitConfirmationPrompting
    private let quitApps: (DockGroup, QuitMode) -> QuitReport

    /// - Parameter quitApps: Quits the group's running apps (`GroupTerminator.closeAll`).
    public init(prompt: QuitConfirmationPrompting, quitApps: @escaping (DockGroup, QuitMode) -> QuitReport) {
        self.prompt = prompt
        self.quitApps = quitApps
    }

    public func request(_ group: DockGroup, mode: QuitMode, from source: QuitRequestSource) -> Outcome {
        if source.asksFirst {
            guard !isAsking else { return .dropped }
            isAsking = true
            defer { isAsking = false }
            guard prompt.confirm(QuitConfirmation(groupName: group.name, mode: mode)) else { return .declined }
        }
        return .quit(quitApps(group, mode))
    }
}
