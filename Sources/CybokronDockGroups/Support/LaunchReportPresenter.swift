import AppKit
import DockGroupsCore

/// Tells the user about apps that Open All couldn't open. Stays silent when everything worked.
@MainActor
enum LaunchReportPresenter {
    static func presentProblems(in report: LaunchReport) {
        let problems = report.problems
        guard !problems.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problems.count == report.entries.count
            ? L10n.Problems.noneOpened(report.groupName)
            : L10n.Problems.someNotOpened(report.groupName)
        alert.informativeText = problems
            .map { L10n.Problems.launchItem($0.app.name, reason: description(of: $0.outcome)) }
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
        alert.informativeText = report.refused.map { "• \($0.name)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    /// Tells the user about running apps that Hide All couldn't hide.
    static func presentProblems(in report: HideReport) {
        guard !report.refused.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Problems.notHidden(report.groupName)
        alert.informativeText = report.refused.map { "• \($0.name)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    private static func description(of outcome: LaunchReport.Outcome) -> String {
        switch outcome {
        case .notFound: return L10n.Problems.notFound
        case .failed(let reason): return reason
        case .launched, .activated: return L10n.Problems.opened
        }
    }
}
