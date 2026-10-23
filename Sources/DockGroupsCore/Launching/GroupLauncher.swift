import Foundation
import OSLog

/// What happened to each item when a group was opened.
public struct LaunchReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The app wasn't running and has been started; a website, file or folder was opened (in
        /// the browser, its default app or the file viewer).
        case launched
        /// The app was already running and has been brought to the front.
        case activated
        /// The app isn't installed on this Mac, or the file or folder isn't where it was.
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

/// Opens every app in a group ("Open All"), its websites in the default browser, and its files
/// and folders with their default apps.
///
/// A file or folder is opened only after it's checked, every time, whatever the groups file or
/// backup it came from says: its location must be valid, it must be there and still of its kind,
/// and neither its name nor its type (symbolic links followed) may be a program, script,
/// installer, app or location file (`FileItemPolicy`). Otherwise the workspace isn't asked to open
/// it at all. An app is only ever started from an app bundle.
@MainActor
public final class GroupLauncher {
    private let workspace: ApplicationWorkspace
    private let locator: ItemLocating
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupLauncher")

    /// - Parameter locator: Checks files and folders before they're opened; by default a
    ///   `WorkspaceItemLocator`.
    public init(workspace: ApplicationWorkspace, locator: ItemLocating? = nil) {
        self.workspace = workspace
        self.locator = locator ?? WorkspaceItemLocator()
    }

    public convenience init() {
        self.init(workspace: SystemApplicationWorkspace())
    }

    /// Opens one of the group's apps, as clicking it in the popup does: brings it to the front when
    /// it's running and starts it otherwise. With `restoringWindows`, a running app also gets its
    /// hidden and minimized windows back, as from a click on its Dock icon
    /// (`PopupPreferences.restoresWindowsOfRunningApps`). A website opens in the default browser,
    /// and a file or folder (once checked) with its default app. The report has a single entry.
    public func open(_ app: AppReference, inGroup group: DockGroup, restoringWindows: Bool = false) async -> LaunchReport {
        let outcome: LaunchReport.Outcome
        switch app.kind {
        case .website:
            outcome = await openWebsites([app])
        case .file, .folder:
            outcome = await openFileItems([app])[0]
        case .application:
            let wasRunning = restoringWindows
                ? workspace.reopenRunningApplication(bundleIdentifier: app.bundleIdentifier)
                : workspace.activateRunningApplication(bundleIdentifier: app.bundleIdentifier)
            if wasRunning {
                outcome = .activated
            } else if let url = locateApplicationBundle(app) {
                do {
                    try await workspace.launchApplication(at: url)
                    outcome = .launched
                } catch {
                    outcome = .failed(reason: error.localizedDescription)
                }
            } else {
                outcome = .notFound
            }
        }
        logProblem(outcome, of: app, context: "Open in group \(group.id)")
        return LaunchReport(groupName: group.name, entries: [LaunchReport.Entry(app: app, outcome: outcome)])
    }

    /// Starts every app in the group that isn't running and brings the running ones to the front.
    /// Apps are launched concurrently; a running app is never launched a second time. Then the
    /// group's files and folders open (one request per default app), and its websites together,
    /// in one request to the default browser. The report keeps the group's order.
    public func openAll(_ group: DockGroup) async -> LaunchReport {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: group.apps.count)
        var launches: [(index: Int, url: URL)] = []
        var fileItems: [(index: Int, item: GroupItem)] = []
        var websites: [(index: Int, app: AppReference)] = []

        for (index, app) in group.apps.enumerated() {
            switch app.kind {
            case .website:
                websites.append((index, app))
            case .file, .folder:
                fileItems.append((index, app))
            case .application:
                if workspace.activateRunningApplication(bundleIdentifier: app.bundleIdentifier) {
                    outcomes[index] = .activated
                } else if let url = locateApplicationBundle(app) {
                    launches.append((index, url))
                } else {
                    outcomes[index] = .notFound
                }
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
        if !fileItems.isEmpty {
            let fileOutcomes = await openFileItems(fileItems.map(\.item))
            for (fileItem, outcome) in zip(fileItems, fileOutcomes) {
                outcomes[fileItem.index] = outcome
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

    /// Where the app's bundle is. A location that isn't an app bundle — a crafted groups file can
    /// point an app at a script — counts as not found, so it's never started.
    private func locateApplicationBundle(_ app: AppReference) -> URL? {
        guard let url = workspace.locateApplication(app) else { return nil }
        guard url.isFileURL, FileLocation.isAppBundlePath(url.path) else {
            logger.error("Not an app bundle, not started: \(app.logIdentity, privacy: .public)")
            return nil
        }
        return url
    }

    /// Checks the files and folders and opens those that pass, in one call to the workspace.
    /// The outcomes are in the order of `items`.
    private func openFileItems(_ items: [GroupItem]) async -> [LaunchReport.Outcome] {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: items.count)
        var checked: [(index: Int, url: URL)] = []
        for (index, item) in items.enumerated() {
            switch check(item) {
            case .open(let url): checked.append((index, url))
            case .skip(let outcome): outcomes[index] = outcome
            }
        }
        if !checked.isEmpty {
            let failures = await workspace.openFileItems(checked.map(\.url))
            for (index, url) in checked {
                outcomes[index] = failures[url].map { .failed(reason: $0.localizedDescription) } ?? .launched
            }
        }
        return outcomes.map { $0 ?? .notFound }
    }

    /// What to do with a file or folder item.
    private enum FileItemCheck {
        /// Open this location: the item's, symbolic links resolved.
        case open(URL)
        /// Don't open it; this is why.
        case skip(LaunchReport.Outcome)
    }

    /// Checks, in this order: a valid location of the item's kind whose name isn't refused; the
    /// item is there, on a connected volume, readable and still of its kind; neither the name nor
    /// the type of what it resolves to is refused.
    private func check(_ item: GroupItem) -> FileItemCheck {
        let refused = FileItemCheck.skip(.failed(reason: FileItemOpeningError.refused.localizedDescription))
        let unchecked = FileItemCheck.skip(.failed(reason: FileItemOpeningError.unchecked.localizedDescription))
        guard let url = item.fileURL, FileLocation.isValidIdentity(item.bundleIdentifier, kind: item.kind) else { return .skip(.notFound) }
        guard FileItemPolicy.refusal(byName: url) == nil else { return refused }
        switch locator.presence(of: item) {
        case .available(let resolved):
            guard FileItemPolicy.refusal(byName: resolved) == nil else { return refused }
            guard let info = locator.typeInfo(at: resolved) else { return unchecked }
            guard FileItemPolicy.refusal(for: info, name: item.name) == nil else { return refused }
            guard info.itemKind == item.kind else { return .skip(.notFound) }
            return .open(resolved)
        case .volumeUnavailable(let name):
            return .skip(.failed(reason: FileItemOpeningError.volumeUnavailable(name: name).localizedDescription))
        case .unverified:
            return unchecked
        case .missing, .online:
            return .skip(.notFound)
        }
    }

    private func logProblem(_ outcome: LaunchReport.Outcome, of app: AppReference, context: String) {
        guard outcome.isProblem else { return }
        // A file's failure reason may name it, or its location; the log gets its kind only.
        let description: String
        if app.kind.isFileSystemItem, case .failed = outcome {
            description = "failed"
        } else {
            description = String(describing: outcome)
        }
        logger.error("\(context, privacy: .public): \(app.logIdentity, privacy: .public) -> \(description, privacy: .public)")
    }
}
