import Foundation
import OSLog

/// What happened to each item when a group was opened.
public struct LaunchReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The app wasn't running and has been started; a website, file or folder was opened (in
        /// the browser, its default app, the app chosen for it, or the file viewer).
        case launched
        /// The app was already running and has been brought to the front.
        case activated
        /// The app isn't installed on this Mac, or the file or folder isn't where it was.
        case notFound
        /// Launching failed with the given reason.
        case failed(reason: String)
        /// The item opens after its launch delay, this many seconds after Open All started
        /// (`DelayedLaunches`); what that does is reported then.
        case scheduled(seconds: Int)

        public var isProblem: Bool {
            switch self {
            case .launched, .activated, .scheduled: return false
            case .notFound, .failed: return true
            }
        }

        /// Whether the item opens later, after its launch delay.
        public var isScheduled: Bool {
            if case .scheduled = self { return true }
            return false
        }
    }

    public struct Entry: Equatable, Sendable {
        public let app: AppReference
        public let outcome: Outcome
        /// Why the item's launch action kept it from opening; `nil` for items without one and for
        /// those opened with it. Internal: the report shows `outcome`'s existing text.
        var launchActionRefusal: LaunchActionItemRefusal? = nil
    }

    public let groupName: String
    /// One entry per item, in the group's order.
    public let entries: [Entry]

    public var problems: [Entry] { entries.filter { $0.outcome.isProblem } }

    /// The items that open later, after their launch delays.
    public var scheduled: [Entry] { entries.filter { $0.outcome.isScheduled } }
}

/// Opens every app in a group ("Open All"), its websites in the default browser, and its files
/// and folders with their default apps — or each with the app chosen for it.
///
/// A file or folder is opened only after it's checked, every time, whatever the groups file or
/// backup it came from says: its location must be valid, it must be there and still of its kind,
/// and neither its name nor its type (symbolic links followed) may be a program, script,
/// installer, app or location file (`FileItemPolicy`). Otherwise the workspace isn't asked to open
/// it at all. An app is only ever started from an app bundle.
///
/// An item opened with a chosen app is checked as above first; then the app is
/// (`ItemOpenerPolicy`): an app that could run the item, or that isn't one that opens it, means
/// the item isn't opened at all. Open All leaves the items with a launch delay to
/// `DelayedLaunches`, which opens them later through these same checks; clicking an item opens it
/// right away.
///
/// An item with a launch action (docs/design/launch-action-runner-slice.md) opens only through
/// `LaunchActionRunner`, and only when the user opened it in the app or a standalone group's app
/// (`LaunchSource`), its action is enabled and valid, this Mac's approval file has its digest
/// (launch-action-approvals.md), and its browser is installed and not running. Otherwise it isn't
/// opened at all — not plainly, not in another browser — and the report says it wasn't opened.
@MainActor
public final class GroupLauncher {
    private let workspace: ApplicationWorkspace
    private let locator: ItemLocating
    private let catalog: ApplicationCatalog
    /// Opens Open All's items that have a launch delay; `nil` when delays are ignored.
    public let pendingLaunches: DelayedLaunches?
    /// The approvals an item's launch action must have to run; without them none runs.
    private let approvals: LaunchActionApprovalStore?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "GroupLauncher")

    /// - Parameters:
    ///   - locator: Checks files and folders before they're opened; by default a
    ///     `WorkspaceItemLocator`.
    ///   - catalog: Finds and checks the apps chosen to open items; by default a
    ///     `SystemApplicationCatalog`.
    ///   - pendingLaunches: Opens Open All's items that have a launch delay after it. Without it
    ///     the delays are ignored and every item opens right away, as in versions without them.
    ///   - approvals: This Mac's approvals, read again for every item with an action. Without
    ///     them no item with an action is opened.
    public init(
        workspace: ApplicationWorkspace,
        locator: ItemLocating? = nil,
        catalog: ApplicationCatalog? = nil,
        pendingLaunches: DelayedLaunches? = nil,
        approvals: LaunchActionApprovalStore? = nil
    ) {
        self.workspace = workspace
        self.locator = locator ?? WorkspaceItemLocator()
        self.catalog = catalog ?? SystemApplicationCatalog()
        self.pendingLaunches = pendingLaunches
        self.approvals = approvals
    }

    public convenience init() {
        self.init(workspace: SystemApplicationWorkspace())
    }

    /// Opens one of the group's items, as clicking it in the popup does — right away, whatever its
    /// launch delay: brings an app to the front when it's running and starts it otherwise. With
    /// `restoringWindows`, a running app also gets its hidden and minimized windows back, as from a
    /// click on its Dock icon (`PopupPreferences.restoresWindowsOfRunningApps`). A website opens in
    /// the default browser, and a file or folder (once checked) with its default app — or with the
    /// app chosen for it. The report has a single entry.
    /// - Parameter source: Who asked (`LaunchSource`); an item with a launch action opens only for
    ///   the user's own click.
    public func open(_ app: AppReference, inGroup group: DockGroup, restoringWindows: Bool = false, source: LaunchSource = .unspecified) async -> LaunchReport {
        if app.launchActionSetting != nil {
            let entry = await openWithLaunchAction(app, source: source)
            return LaunchReport(groupName: group.name, entries: [entry])
        }
        let outcome: LaunchReport.Outcome
        switch app.kind {
        case .website:
            outcome = await openWebsites([app])[0]
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
    /// group's files and folders open (one request per app that opens them), and its websites
    /// together, in one request to the default browser (or to the browser chosen for them). The
    /// report keeps the group's order.
    ///
    /// Items with a launch delay are left to `pendingLaunches` and reported as `.scheduled`; they
    /// open later, and that is reported through `DelayedLaunches.onFinished`.
    /// - Parameter source: Who asked (`LaunchSource`), for the delayed items too; items with a launch
    ///   action open only for the user's own click.
    public func openAll(_ group: DockGroup, source: LaunchSource = .unspecified) async -> LaunchReport {
        let isDelayed = group.apps.map { pendingLaunches != nil && $0.launch.delay > 0 }
        let delayed = zip(group.apps, isDelayed).filter(\.1).map(\.0)
        if let pendingLaunches, !delayed.isEmpty {
            // Scheduled first: the delays count from now.
            pendingLaunches.schedule(delayed, of: group) { [weak self] items, current in
                await self?.openRightAway(items, inGroup: current, context: "Delayed Open All in group \(current.id)", source: source)
                    ?? LaunchReport(groupName: current.name, entries: [])
            }
        }
        let immediate = zip(group.apps, isDelayed).filter { !$0.1 }.map(\.0)
        var opened = await openRightAway(immediate, inGroup: group, context: "Open All in group \(group.id)", source: source).entries.makeIterator()
        let entries = zip(group.apps, isDelayed).map { item, isDelayed in
            isDelayed ? LaunchReport.Entry(app: item, outcome: .scheduled(seconds: item.launch.delay)) : (opened.next() ?? LaunchReport.Entry(app: item, outcome: .notFound))
        }
        return LaunchReport(groupName: group.name, entries: entries)
    }

    /// Opens `items` now, as Open All opens the items without a launch delay; the report lists
    /// them in the order given. Items with a launch action open last, one at a time, through
    /// `openWithLaunchAction`.
    func openRightAway(_ items: [GroupItem], inGroup group: DockGroup, context: String, source: LaunchSource = .unspecified) async -> LaunchReport {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: items.count)
        var launches: [(index: Int, url: URL)] = []
        var fileItems: [(index: Int, item: GroupItem)] = []
        var websites: [(index: Int, app: AppReference)] = []
        var withActions: [(index: Int, item: GroupItem)] = []
        var actionEntries: [Int: LaunchReport.Entry] = [:]

        for (index, app) in items.enumerated() {
            if app.launchActionSetting != nil {
                withActions.append((index, app))
                continue
            }
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

        await withTaskGroup(of: (Int, LaunchReport.Outcome).self) { taskGroup in
            for launch in launches {
                // Runs on the main actor, as before. Captures the launcher (main actor, so Sendable)
                // rather than its non-Sendable workspace; a typed closure, because the
                // region-based isolation checker can't check an `@MainActor in` literal here.
                let launchApp: @MainActor @Sendable () async -> (Int, LaunchReport.Outcome) = {
                    await (launch.index, self.launchOutcome(at: launch.url))
                }
                taskGroup.addTask(operation: launchApp)
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
            let websiteOutcomes = await openWebsites(websites.map(\.app))
            for (website, outcome) in zip(websites, websiteOutcomes) {
                outcomes[website.index] = outcome
            }
        }
        for withAction in withActions {
            actionEntries[withAction.index] = await openWithLaunchAction(withAction.item, source: source)
        }

        let entries = zip(items, outcomes).enumerated().map { index, pair in
            actionEntries[index] ?? LaunchReport.Entry(app: pair.0, outcome: pair.1 ?? .failed(reason: Localization.string("core.launch.notOpened", "The app wasn't opened.")))
        }
        let report = LaunchReport(groupName: group.name, entries: entries)
        for problem in report.problems {
            logProblem(problem.outcome, of: problem.app, context: context)
        }
        return report
    }

    /// Launches the app at `url`: `launched` once it has started, or why it couldn't be.
    private func launchOutcome(at url: URL) async -> LaunchReport.Outcome {
        do {
            try await workspace.launchApplication(at: url)
            return .launched
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Opens the websites: those without a chosen browser (or whose browser isn't on this Mac) in
    /// the default browser, all in one request; the others with their browser, one request per
    /// browser. The outcomes are in the order of `websites`.
    private func openWebsites(_ websites: [AppReference]) async -> [LaunchReport.Outcome] {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: websites.count)
        var inDefaultBrowser: [(index: Int, url: URL)] = []
        var withApps: [(app: URL, items: [(index: Int, url: URL)])] = []
        for (index, website) in websites.enumerated() {
            guard let url = website.websiteURL else {
                outcomes[index] = .notFound
                continue
            }
            switch openerDecision(for: website, target: url) {
            case .defaultApp:
                inDefaultBrowser.append((index, url))
            case .openWith(let app):
                Self.add((index, url), to: &withApps, app: app)
            case .refused(let name):
                outcomes[index] = .failed(reason: ItemOpeningError.openerRefused(name: name).localizedDescription)
            }
        }
        if !inDefaultBrowser.isEmpty {
            let outcome: LaunchReport.Outcome
            do {
                try await workspace.openWebsites(inDefaultBrowser.map(\.url))
                outcome = .launched
            } catch {
                outcome = .failed(reason: error.localizedDescription)
            }
            for item in inDefaultBrowser {
                outcomes[item.index] = outcome
            }
        }
        await open(withApps, into: &outcomes)
        return outcomes.map { $0 ?? .notFound }
    }

    /// Opens an item that has a launch action, only through `LaunchActionRunner`: when the user
    /// asked (`source`), the workspace can start apps with launch actions, a plan can be made (the
    /// action enabled and valid for the item, its address and browser accepted, the browser
    /// installed), the approval file has the digest of exactly this action for this item (read
    /// now), and the runner starts the browser (it refuses a running one). Anything else opens
    /// nothing. Only a fixed code is logged, never the profile name, arguments or address.
    private func openWithLaunchAction(_ item: GroupItem, source: LaunchSource) async -> LaunchReport.Entry {
        let refusal: LaunchActionItemRefusal
        if !source.isUserPresent {
            refusal = .unattendedSource(source)
        } else if let actions = workspace as? LaunchActionWorkspace {
            let browser = item.launch.opener?.bundleIdentifier ?? item.launchAction?.preferredBrowserBundleIdentifier ?? ""
            let planned = LaunchActionArgumentPlan.make(for: item, browserBundleIdentifier: browser) { identifier in
                actions.applicationLocation(bundleIdentifier: identifier) != nil
            }
            switch planned {
            case .success(let plan):
                if let unapproved = approvalRefusal(for: item) {
                    refusal = .approval(unapproved)
                } else {
                    switch await LaunchActionRunner(workspace: actions).run(plan) {
                    case .launched:
                        logger.notice("Opened a \(String(describing: item.kind), privacy: .public) item with its launch action")
                        return LaunchReport.Entry(app: item, outcome: .launched)
                    case .refused(let reason):
                        refusal = .run(reason)
                    }
                }
            case .failure(let reason):
                refusal = .plan(reason)
            case nil:
                // The item has a setting, so this doesn't happen; it opens nothing all the same.
                refusal = .plan(.actionNeedsReview)
            }
        } else {
            refusal = .noRunner
        }
        logger.error("Not opened, launch action \(refusal.code, privacy: .public): a \(String(describing: item.kind), privacy: .public) item")
        return LaunchReport.Entry(app: item, outcome: refusal.outcome, launchActionRefusal: refusal)
    }

    /// Why the approval file doesn't let `item`'s action run, read now; `nil` when it does. Without
    /// approvals, or with a file that's missing or can't be read, nothing is approved.
    private func approvalRefusal(for item: GroupItem) -> LaunchActionApprovalRefusal? {
        switch approvals?.check(item) ?? .missing {
        case .approved: return nil
        case .mismatch: return .mismatch
        case .missing, .noAction: return .missing
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

    /// Checks the files and folders and opens those that pass: with their default apps in one call
    /// to the workspace, and with their chosen apps in one call per app. The outcomes are in the
    /// order of `items`.
    private func openFileItems(_ items: [GroupItem]) async -> [LaunchReport.Outcome] {
        var outcomes = [LaunchReport.Outcome?](repeating: nil, count: items.count)
        var withDefaultApps: [(index: Int, url: URL)] = []
        var withApps: [(app: URL, items: [(index: Int, url: URL)])] = []
        for (index, item) in items.enumerated() {
            switch check(item) {
            case .skip(let outcome):
                outcomes[index] = outcome
            case .open(let url):
                switch openerDecision(for: item, target: url) {
                case .defaultApp:
                    withDefaultApps.append((index, url))
                case .openWith(let app):
                    Self.add((index, url), to: &withApps, app: app)
                case .refused(let name):
                    outcomes[index] = .failed(reason: ItemOpeningError.openerRefused(name: name).localizedDescription)
                }
            }
        }
        if !withDefaultApps.isEmpty {
            let failures = await workspace.openFileItems(withDefaultApps.map(\.url))
            for (index, url) in withDefaultApps {
                outcomes[index] = failures[url].map { .failed(reason: $0.localizedDescription) } ?? .launched
            }
        }
        await open(withApps, into: &outcomes)
        return outcomes.map { $0 ?? .notFound }
    }

    /// Whether and with which app `item` opens, given what opening it opens (`target`).
    private func openerDecision(for item: GroupItem, target: URL) -> ItemOpenerDecision {
        let decision = ItemOpenerPolicy.decide(item.launch.opener, for: item, target: target, catalog: catalog)
        if case .refused = decision, let opener = item.launch.opener {
            // The app, not the user's data: the item by its kind only.
            logger.error("Not opened with \(opener.bundleIdentifier, privacy: .public): \(item.logIdentity, privacy: .public)")
        }
        return decision
    }

    /// Opens each app's items with it, one request per app, and records the outcomes.
    private func open(_ withApps: [(app: URL, items: [(index: Int, url: URL)])], into outcomes: inout [LaunchReport.Outcome?]) async {
        for request in withApps {
            let outcome: LaunchReport.Outcome
            do {
                try await workspace.open(request.items.map(\.url), withApplicationAt: request.app)
                outcome = .launched
            } catch {
                outcome = .failed(reason: error.localizedDescription)
            }
            for item in request.items {
                outcomes[item.index] = outcome
            }
        }
    }

    private static func add(_ item: (index: Int, url: URL), to requests: inout [(app: URL, items: [(index: Int, url: URL)])], app: URL) {
        if let position = requests.firstIndex(where: { $0.app == app }) {
            requests[position].items.append(item)
        } else {
            requests.append((app, [item]))
        }
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
        // An item with a launch action was logged by its fixed code, without its address.
        guard outcome.isProblem, app.launchActionSetting == nil else { return }
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
