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
            ? "The apps in “\(report.groupName)” couldn't be opened."
            : "Some apps in “\(report.groupName)” couldn't be opened."
        alert.informativeText = problems
            .map { "• \($0.app.name): \(description(of: $0.outcome))" }
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
            ? "Some apps in “\(report.groupName)” couldn't be force quit."
            : "Some apps in “\(report.groupName)” couldn't be asked to quit."
        alert.informativeText = report.refused.map { "• \($0.name)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    /// Tells the user about running apps that Hide All couldn't hide.
    static func presentProblems(in report: HideReport) {
        guard !report.refused.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some apps in “\(report.groupName)” couldn't be hidden."
        alert.informativeText = report.refused.map { "• \($0.name)" }.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }

    private static func description(of outcome: LaunchReport.Outcome) -> String {
        switch outcome {
        case .notFound: return "not found on this Mac."
        case .failed(let reason): return reason
        case .launched, .activated: return "opened."
        }
    }
}
