import AppKit
import DockGroupsCore

/// Tells the user about items (apps, websites, files and folders) that opening a group or one of
/// its items couldn't open, by the names they're shown with (an alias, when they have one). Stays
/// silent when everything worked.
@MainActor
enum LaunchReportPresenter {
    static func presentProblems(in report: LaunchReport) {
        let problems = report.problems
        guard !problems.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problems.count == report.entries.count
            ? L10n.Item.noneOpened(report.groupName)
            : L10n.Item.someNotOpened(report.groupName)
        alert.informativeText = problems
            .map { L10n.Problems.launchItem($0.app.displayName, reason: description(of: $0.outcome)) }
            .joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    /// Tells the user about running apps that Close All couldn't quit.
    static func presentProblems(in report: QuitReport) {
        guard !report.refused.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.mode == .force
            ? L10n.Problems.notForceQuit(report.groupName)
            : L10n.Problems.notAskedToQuit(report.groupName)
        alert.informativeText = report.refused.map { "• \($0.displayName)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    /// Tells the user about running apps that Hide All couldn't hide.
    static func presentProblems(in report: HideReport) {
        guard !report.refused.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Problems.notHidden(report.groupName)
        alert.informativeText = report.refused.map { "• \($0.displayName)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    /// Tells the user what starting or finishing a group couldn't do: items that didn't open (as
    /// Open All does), then — in one alert — apps that couldn't be hidden, asked to quit or shown
    /// again. Apps left alone on purpose (protected, shared, this app) aren't problems.
    static func presentProblems(in report: TransitionReport) {
        guard report.outcome == .done else { return }
        if let launch = report.launch {
            presentProblems(in: launch)
        }
        let lines = report.hidden.refused.map { L10n.Switching.Problems.notHidden($0.name) }
            + report.quit.refused.map { L10n.Switching.Problems.notQuit($0.name) }
            + report.shown.refused.map { L10n.Switching.Problems.notShown($0.name) }
        guard !lines.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if case .start = report.plan.kind {
            alert.messageText = L10n.Switching.Problems.start(report.plan.groupName)
        } else {
            alert.messageText = L10n.Switching.Problems.finish(report.plan.groupName)
        }
        alert.informativeText = lines.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    private static func description(of outcome: LaunchReport.Outcome) -> String {
        switch outcome {
        case .notFound: return L10n.Problems.notFound
        case .failed(let reason): return reason
        case .launched, .activated, .scheduled: return L10n.Problems.opened
        }
    }
}
