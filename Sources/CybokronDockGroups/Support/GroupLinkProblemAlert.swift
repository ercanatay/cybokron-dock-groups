import AppKit
import DockGroupsCore
import OSLog

/// Tells the user, in an alert, that a `cybokrondockgroups://` link opened no group: none has the
/// link's identifier or name, or more than one has its name (`GroupResolution.problemMessage`).
/// Nothing is done then, so the link is never silently ignored or carried out on another group.
///
/// Any app or page can open links, so one alert shows at a time, and none for
/// `CommandThrottle.urlCooldown` seconds after it closes: links in a burst can't stack alerts.
/// Those are only logged.
@MainActor
enum GroupLinkProblemAlert {
    private static var isShowing = false
    private static var lastClosed: Date?
    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "URLScheme")

    static func present(_ resolution: GroupResolution, now: Date = Date()) {
        guard let message = resolution.problemMessage else { return }
        if isShowing {
            logger.notice("Not showing another link problem while one is showing")
            return
        }
        if let lastClosed, now.timeIntervalSince(lastClosed) >= 0, now.timeIntervalSince(lastClosed) < CommandThrottle.urlCooldown {
            logger.notice("Not showing another link problem within \(Int(CommandThrottle.urlCooldown)) seconds of the last one")
            return
        }
        isShowing = true
        defer {
            isShowing = false
            lastClosed = Date()
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        NSApp.activate()
        alert.runModal()
    }
}
