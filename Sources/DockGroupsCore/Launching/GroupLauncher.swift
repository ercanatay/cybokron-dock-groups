import Foundation
import OSLog

/// What happened to each app when a group was opened.
public struct LaunchReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The app wasn't running and has been started; for a website, it was opened in the browser.
        case launched
        /// The app was already running and has been brought to the front.
        case activated
        /// The app isn't installed on this Mac.
        case notFound
        /// Launching failed with the given reason.
        case failed(reason: String)

        public var isProblem: Bool {
            switch self {
            case .launched, .activated: return false
            case .notFound, .failed: return true
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let app: AppReference
        public let outcome: Outcome
    }

    public let groupName: String
    /// One entry per app, in the group's order.
    public let entries: [Entry]

    public var problems: [Entry] { entries.filter { $0.outcome.isProblem } }
}

/// Opens every app in a group ("Open All"), and its websites in the default browser.
@MainActor
public final class GroupLauncher {
    private let workspace: ApplicationWorkspace
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupLauncher")

    public init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
    }

    public convenience init() {
        self.init(workspace: SystemApplicationWorkspace())
    }

    /// Opens one of the group's apps, as clicking it in the popup does: brings it to the front when
    /// it's running and starts it otherwise. With `restoringWindows`, a running app also gets its
    /// hidden and minimized windows back, as from a click on its Dock icon
    /// (`PopupPreferences.restoresWindowsOfRunningApps`). A website opens in the default browser.
    /// The report has a single entry.
    public func open(_ app: AppReference, inGroup group: DockGroup, restoringWindows: Bool = false) async -> LaunchReport {
        if app.isWebsite {
            let outcome = await openWebsites([app])
            logProblem(outcome, of: app, context: "Open in group \(group.id)")
            return LaunchReport(groupName: group.name, entries: [LaunchReport.Entry(app: app, outcome: outcome)])
        }
        let outcome: LaunchReport.Outcome
        let wasRunning = restoringWindows
            ? workspace.reopenRunningApplication(bundleIdentifier: app.bundleIdentifier)
            : workspace.activateRunningApplication(bundleIdentifier: app.bundleIdentifier)
        if wasRunning {
            outcome = .activated
        } else if let url = workspace.locateApplication(app) {
            do {
                try await workspace.launchApplication(at: url)
                outcome = .launched
            } catch {
                outcome = .failed(reason: error.localizedDescription)
            }
        } else {
            outcome = .notFound
        }
        logProblem(outcome, of: app, context: "Open in group \(group.id)")
        return LaunchReport(groupName: group.name, entries: [LaunchReport.Entry(app: app, outcome: outcome)])
    }

    /// Starts every app in the group that isn't running and brings the running ones to the front.
    /// Apps are launched concurrently; a running app is never launched a second time. The group's
    /// websites open together, in one request to the default browser.
    public func openAll(_ group: DockGroup) async -> LaunchReport {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: group.apps.count)
        var launches: [(index: Int, url: URL)] = []
        var websites: [(index: Int, app: AppReference)] = []

        for (index, app) in group.apps.enumerated() {
            if app.isWebsite {
                websites.append((index, app))
            } else if workspace.activateRunningApplication(bundleIdentifier: app.bundleIdentifier) {
                outcomes[index] = .activated
            } else if let url = workspace.locateApplication(app) {
                launches.append((index, url))
            } else {
                outcomes[index] = .notFound
            }
        }

        let workspace = self.workspace
        await withTaskGroup(of: (Int, LaunchReport.Outcome).self) { taskGroup in
            for launch in launches {
                taskGroup.addTask { @MainActor in
                    do {
                        try await workspace.launchApplication(at: launch.url)
                        return (launch.index, .launched)
                    } catch {
                        return (launch.index, .failed(reason: error.localizedDescription))
                    }
                }
            }
            for await (index, outcome) in taskGroup {
                outcomes[index] = outcome
            }
        }
        if !websites.isEmpty {
            let outcome = await openWebsites(websites.map(\.app))
            for website in websites {
                outcomes[website.index] = outcome
            }
        }

        let entries = zip(group.apps, outcomes).map { app, outcome in
            LaunchReport.Entry(app: app, outcome: outcome ?? .failed(reason: Localization.string("core.launch.notOpened", "The app wasn't opened.")))
        }
        let report = LaunchReport(groupName: group.name, entries: entries)
        for problem in report.problems {
            logProblem(problem.outcome, of: problem.app, context: "Open All in group \(group.id)")
        }
        return report
    }

    /// Opens the websites in the default browser, all in one request.
    private func openWebsites(_ websites: [AppReference]) async -> LaunchReport.Outcome {
        let urls = websites.compactMap(\.websiteURL)
        guard !urls.isEmpty else { return .notFound }
        do {
            try await workspace.openWebsites(urls)
            return .launched
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func logProblem(_ outcome: LaunchReport.Outcome, of app: AppReference, context: String) {
        guard outcome.isProblem else { return }
        logger.error("\(context, privacy: .public): \(app.logIdentity, privacy: .public) -> \(String(describing: outcome), privacy: .public)")
    }
}
