import Foundation
import OSLog

/// What happened to each app when a group was opened.
public struct LaunchReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The app wasn't running and has been started.
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

/// Opens every app in a group ("Open All").
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

    /// Starts every app in the group that isn't running and brings the running ones to the front.
    /// Apps are launched concurrently; a running app is never launched a second time.
    public func openAll(_ group: DockGroup) async -> LaunchReport {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: group.apps.count)
        var launches: [(index: Int, url: URL)] = []

        for (index, app) in group.apps.enumerated() {
            if workspace.activateRunningApplication(bundleIdentifier: app.bundleIdentifier) {
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

        let entries = zip(group.apps, outcomes).map { app, outcome in
            LaunchReport.Entry(app: app, outcome: outcome ?? .failed(reason: "The app wasn't opened."))
        }
        let report = LaunchReport(groupName: group.name, entries: entries)
        for problem in report.problems {
            logger.error("Open All in group \(group.id, privacy: .public): \(problem.app.bundleIdentifier, privacy: .public) -> \(String(describing: problem.outcome), privacy: .public)")
        }
        return report
    }
}
