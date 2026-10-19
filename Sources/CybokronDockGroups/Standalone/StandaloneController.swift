import AppKit
import Combine
import DockGroupsCore
import OSLog

/// Keeps the standalone groups' agents — each group's own small app with its own Dock icon — in
/// step with the groups.
///
/// - Turning Standalone on builds the agent in `Application Support/…/Agents`, registers it with
///   LaunchServices, adds its tile at the end of the Dock and restarts the Dock to show it.
/// - Changes to a standalone group (or to the popup preferences it falls back to) rebuild its agent
///   shortly afterwards and tell a running agent to reload; a rename also moves the agent to its new
///   folder and updates its Dock tile. The Dock caches tile icons, so after an icon change in place
///   the group is listed in `staleDockIcons` until `refreshDockIcons()` clears that cache.
/// - Turning Standalone off or deleting the group quits a running agent (normally, forced after a
///   few seconds), removes its Dock tile and deletes the agent.
/// - At launch, agents of no standalone group are removed unless they're running ("stranded"
///   agents), and groups whose tile was dragged out of the Dock have Standalone turned off; the
///   latter is checked again whenever the group window opens.
/// - The Dock's app list is only edited through `AgentDockTiles`: when it can't be read nothing is
///   decided from it (no group is turned off, no tile removed), and it's copied aside before every
///   change.
/// - Standalone groups restored or merged from a backup get their tiles added
///   (`adoptRestoredGroups`) rather than being turned off for lacking one.
///
/// All of this runs one step at a time, in order.
@MainActor
final class StandaloneController: ObservableObject {
    enum Status: Equatable {
        case working
        case failed(String)
    }

    /// Delay after the last change to a group before its agent is rebuilt; coalesces typing and
    /// color picker drags into one rebuild and one Dock restart.
    private static let rebuildDelay: DispatchQueue.SchedulerTimeType.Stride = .seconds(1.5)
    /// How long a running agent gets to quit before it's forced to.
    private static let quitTimeout: Duration = .seconds(3)

    /// Work in progress, or the last failure, per group; idle groups have no entry.
    @Published private(set) var statuses: [DockGroup.ID: Status] = [:]
    /// Groups whose agent got a new icon that the Dock doesn't show yet.
    @Published private(set) var staleDockIcons: Set<DockGroup.ID> = []

    private let store: GroupStore
    private let preferences: PreferencesStore
    private let icons: AppIconProviding
    private let installer: AgentInstaller
    private let dockTiles: AgentDockTiles
    private let dockRestarter: DockRestarter
    private var host: AgentHost?
    private var queueTail: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    /// The standalone groups as of the last pass. A group that drops out was turned off or deleted,
    /// so its agent is quit even while running.
    private var knownStandaloneIDs: Set<DockGroup.ID> = []
    /// Groups whose status shows that writing the Dock's list failed; cleared once it works.
    private var dockSaveFailures: Set<DockGroup.ID> = []
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Standalone")

    init(
        store: GroupStore,
        preferences: PreferencesStore,
        icons: AppIconProviding,
        installer: AgentInstaller = AgentInstaller(),
        dock: DockTileStoring = SystemDockTileStore(),
        dockRestarter: DockRestarter = DockRestarter()
    ) {
        self.store = store
        self.preferences = preferences
        self.icons = icons
        self.installer = installer
        dockTiles = AgentDockTiles(store: dock)
        self.dockRestarter = dockRestarter
    }

    func status(for id: DockGroup.ID) -> Status? {
        statuses[id]
    }

    /// The agent bundle of a standalone group, when it exists.
    func agentURL(for id: DockGroup.ID) -> URL? {
        let standalone = store.groups.filter(\.isStandalone)
        guard let folderName = AgentIdentity.folderNames(for: standalone)[id] else { return nil }
        let url = installer.bundleURL(folderName: folderName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Cleans up and brings the agents up to date, then follows the groups.
    func start() {
        knownStandaloneIDs = Set(store.groups.filter(\.isStandalone).map(\.id))
        enqueue { [weak self] in
            guard let self else { return }
            self.installer.removeStagingLeftovers()
            self.turnOffGroupsRemovedFromDock()
            _ = await self.synchronize()
        }
        // @Published fires before the change; the debounce reads the new values afterwards. The
        // current values were just handled by the pass above.
        store.$groups.dropFirst().map { _ in () }
            .merge(with: preferences.$preferences.dropFirst().map { _ in () })
            .debounce(for: Self.rebuildDelay, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.enqueue { [weak self] in _ = await self?.synchronize() }
            }
            .store(in: &subscriptions)
    }

    /// Turns a group's standalone agent on or off (the toggle in the group window).
    func setStandalone(_ isOn: Bool, for id: DockGroup.ID) {
        guard let group = store.group(withID: id), group.isStandalone != isOn else { return }
        if isOn {
            dockTiles.requestAddition(of: id)
        } else {
            dockTiles.cancelAddition(of: id)
        }
        statuses[id] = .working
        store.updateGroup(id) { $0.isStandalone = isOn }
        enqueue { [weak self] in
            guard let self else { return }
            let failures = await self.synchronize()
            guard isOn, let error = failures[id] else { return }
            // Nothing was installed; the group goes back to normal.
            self.store.updateGroup(id) { $0.isStandalone = false }
            self.knownStandaloneIDs.remove(id)
            self.statuses[id] = .failed(error.localizedDescription)
            self.presentFailure(error, groupName: group.name)
        }
    }

    /// Groups just restored or merged from a backup: standalone ones whose tile isn't in the Dock
    /// get it on the next pass (which follows the store's change), instead of being turned off
    /// because it's missing. Call right after the store took the groups.
    func adoptRestoredGroups(_ groups: [DockGroup]) {
        dockTiles.adoptRestored(groups)
        let pending = groups.filter { dockTiles.pendingAdditions.contains($0.id) }
        if !pending.isEmpty {
            logger.notice("Restored standalone groups get their Dock tiles: \(pending.map(\.id.uuidString).joined(separator: ", "), privacy: .public)")
        }
    }

    /// Notices tiles dragged out of the Dock (called when the group window opens).
    func checkDockTiles() {
        enqueue { [weak self] in
            guard let self, self.turnOffGroupsRemovedFromDock() else { return }
            _ = await self.synchronize()
        }
    }

    func revealAgent(for id: DockGroup.ID) {
        guard let url = agentURL(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Clears the Dock's icon cache and restarts the Dock, so the agents' tiles show their current
    /// icons.
    func refreshDockIcons() {
        enqueue { [weak self] in
            guard let self else { return }
            self.logger.notice("Refreshing the Dock's icons")
            await self.restartDock(clearingIconCache: true)
            self.staleDockIcons.removeAll()
        }
    }

    // MARK: - Passes

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queueTail
        queueTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Turns Standalone off for groups whose agent tile isn't in the Dock any more. Returns whether
    /// it did for any group. Does nothing when the Dock's list can't be read.
    @discardableResult
    private func turnOffGroupsRemovedFromDock() -> Bool {
        guard let removed = dockTiles.groupsRemovedFromDock(among: store.groups) else {
            logger.error("The Dock's app list couldn't be read; not checking for removed group tiles")
            return false
        }
        for id in removed {
            logger.notice("The Dock tile of group \(id, privacy: .public) was removed; turning Standalone off")
            store.updateGroup(id) { $0.isStandalone = false }
        }
        return !removed.isEmpty
    }

    /// Builds, moves and removes agents and Dock tiles so they match the standalone groups.
    /// Returns the groups whose agent couldn't be built.
    private func synchronize() async -> [DockGroup.ID: Error] {
        var failures: [DockGroup.ID: Error] = [:]
        defer { finishStatuses(failures: failures) }

        let standalone = store.groups.filter(\.isStandalone)
        let currentIDs = Set(standalone.map(\.id))
        let quitting = knownStandaloneIDs.subtracting(currentIDs)
        knownStandaloneIDs = currentIDs
        staleDockIcons.formIntersection(currentIDs)
        let installed = AgentDirectory.scan(installer.directory)
        guard !standalone.isEmpty || !installed.isEmpty || !quitting.isEmpty || hasAgentTilesInDock() else {
            return failures
        }

        let host: AgentHost
        do {
            host = try currentHost()
        } catch {
            logger.error("Agents can't be built: \(String(describing: error), privacy: .public)")
            for group in standalone { failures[group.id] = error }
            return failures
        }
        let folderNames = AgentIdentity.folderNames(for: standalone)
        let snapshot = preferences.preferences
        let desired = standalone.compactMap { group in
            folderNames[group.id].map {
                DesiredAgent(
                    configuration: AgentConfiguration(group: group, preferences: snapshot),
                    folderName: $0,
                    sourceDigest: host.executableDigest
                )
            }
        }
        let running = runningAgentBundleIdentifiers()
        let plan = AgentPlanner.plan(
            desired: desired,
            installed: installed,
            runningBundleIdentifiers: running,
            quittingGroupIDs: quitting
        )

        for removal in plan.deferred {
            logger.notice("Keeping stranded agent \(removal.agent.folderName, privacy: .public) while it's running")
        }
        for removal in plan.removals {
            await remove(removal, running: running, quitting: quitting)
        }

        let installedByGroup = Dictionary(installed.compactMap { agent in agent.groupID.map { ($0, agent) } }, uniquingKeysWith: { first, _ in first })
        let tilesInDock = dockTiles.agentBundleIdentifiersInDock() ?? []
        for build in plan.builds {
            let id = build.agent.groupID
            statuses[id] = .working
            do {
                try await install(build, host: host)
                // Rebuilt in place: the Dock shows its cached icon for that file until refreshed.
                if build.replacing == nil,
                   let previous = installedByGroup[id]?.configuration?.group,
                   AgentIcon.differs(previous, from: build.agent.configuration.group),
                   tilesInDock.contains(build.agent.bundleIdentifier.lowercased()) {
                    staleDockIcons.insert(id)
                }
            } catch {
                logger.error("Building the agent of group \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failures[id] = error
            }
        }

        if updateDock(desired: desired, failed: Set(failures.keys), standaloneIDs: currentIDs) {
            await restartDock()
        }
        return failures
    }

    private func install(_ build: AgentSyncPlan.Build, host: AgentHost) async throws {
        let group = build.agent.configuration.group
        logger.notice("Building the agent of group \(group.id, privacy: .public) (\(build.reason.rawValue, privacy: .public)) as \(build.agent.folderName, privacy: .public)")
        let tileIcons = group.apps.prefix(TileGridGeometry.maximumIconCount).map { icons.icon(for: $0) }
        let icns = try AgentIcon.icnsData(for: group, icons: tileIcons)
        let url = try await installer.install(AgentInstaller.Input(
            configuration: build.agent.configuration,
            folderName: build.agent.folderName,
            host: host,
            icns: icns
        ))
        try await installer.register(url)
        if let previous = build.replacing, previous.standardizedFileURL != url.standardizedFileURL {
            await installer.unregister(previous)
            try? installer.remove(previous)
        }
        DistributedNotificationCenter.default().postNotificationName(
            AgentNotification.configurationChanged,
            object: group.id.uuidString,
            userInfo: [AgentNotification.bundlePathKey: url.path],
            deliverImmediately: true
        )
    }

    /// - Parameter quitting: Groups the user turned Standalone off for or deleted; other agents
    ///   without a group are strays.
    private func remove(_ removal: AgentSyncPlan.Removal, running: Set<String>, quitting: Set<DockGroup.ID>) async {
        let agent = removal.agent
        if let bundleIdentifier = agent.runningBundleIdentifier, running.contains(bundleIdentifier.lowercased()) {
            await quitAgent(bundleIdentifier: bundleIdentifier)
        }
        switch removal.reason {
        case .noGroup where agent.groupID.map(quitting.contains) == true:
            logger.notice("Removing agent \(agent.folderName, privacy: .public): its group was deleted or isn't standalone any more")
        case .noGroup, .unreadable:
            logger.notice("Removing stranded agent \(agent.folderName, privacy: .public)")
        case .duplicate:
            logger.notice("Removing duplicate agent \(agent.folderName, privacy: .public)")
        }
        await installer.unregister(agent.bundleURL)
        do {
            try installer.remove(agent.bundleURL)
        } catch {
            logger.error("Removing agent \(agent.folderName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        if removal.reason != .duplicate, let bundleIdentifier = agent.runningBundleIdentifier {
            installer.removeSystemLeftovers(bundleIdentifier: bundleIdentifier)
        }
    }

    /// Adds tiles for groups just turned on, updates moved and renamed ones, and removes those of
    /// agents that are gone (see `AgentDockTiles.apply`). Returns whether the Dock's list changed
    /// (and the Dock needs a restart). When the list can't be read nothing happens; when it can't be
    /// written the affected groups show the failure and their tiles are tried again next time.
    private func updateDock(desired: [DesiredAgent], failed: Set<DockGroup.ID>, standaloneIDs: Set<DockGroup.ID>) -> Bool {
        let tiles = desired.filter { !failed.contains($0.groupID) }.map { agent -> AgentTile in
            let url = installer.bundleURL(folderName: agent.folderName)
            return AgentTile(
                groupID: agent.groupID,
                bundleIdentifier: agent.bundleIdentifier,
                label: agent.configuration.group.name,
                bundleURL: FileManager.default.fileExists(atPath: url.path) ? url : nil
            )
        }
        switch dockTiles.apply(tiles, standaloneGroupIDs: standaloneIDs) {
        case .unreadable:
            logger.error("The Dock's app list couldn't be read; leaving the Dock as it is")
            return false
        case .unchanged:
            clearDockSaveFailures()
            return false
        case .saved(let previousCount, let count):
            clearDockSaveFailures()
            logger.notice("Dock tiles changed (\(previousCount, privacy: .public) → \(count, privacy: .public) apps); restarting the Dock")
            return true
        case .saveFailed(let message, let groupIDs):
            logger.error("Updating the Dock failed: \(message, privacy: .public)")
            for id in groupIDs where standaloneIDs.contains(id) {
                statuses[id] = .failed(message)
                dockSaveFailures.insert(id)
            }
            return false
        }
    }

    private func clearDockSaveFailures() {
        for id in dockSaveFailures where statuses[id] != .working {
            statuses[id] = nil
        }
        dockSaveFailures.removeAll()
    }

    /// `killall Dock`, logging whether it worked.
    private func restartDock(clearingIconCache: Bool = false) async {
        if await dockRestarter.restart(clearingIconCache: clearingIconCache) {
            logger.notice("The Dock restarted")
        } else {
            logger.error("Restarting the Dock (killall Dock) failed")
        }
    }

    // MARK: - Helpers

    private func finishStatuses(failures: [DockGroup.ID: Error]) {
        for (id, status) in statuses where status == .working {
            statuses[id] = nil
        }
        for (id, error) in failures {
            statuses[id] = .failed(error.localizedDescription)
        }
    }

    private func currentHost() throws -> AgentHost {
        if let host {
            return host
        }
        let current = try AgentHost.current()
        host = current
        return current
    }

    private func hasAgentTilesInDock() -> Bool {
        !(dockTiles.agentBundleIdentifiersInDock() ?? []).isEmpty
    }

    private func runningAgentBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .compactMap { $0.bundleIdentifier?.lowercased() }
            .filter(AgentIdentity.isAgent(bundleIdentifier:)))
    }

    /// Asks the agent to quit and waits for it; forces it after `quitTimeout`.
    private func quitAgent(bundleIdentifier: String) async {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !instances.isEmpty else { return }
        logger.notice("Quitting agent \(bundleIdentifier, privacy: .public)")
        instances.forEach { _ = $0.terminate() }
        if await waitUntilTerminated(instances, timeout: Self.quitTimeout) { return }
        logger.notice("Agent \(bundleIdentifier, privacy: .public) didn't quit in time; forcing it")
        instances.filter { !$0.isTerminated }.forEach { _ = $0.forceTerminate() }
        _ = await waitUntilTerminated(instances, timeout: .seconds(1))
    }

    private func waitUntilTerminated(_ instances: [NSRunningApplication], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if instances.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return instances.allSatisfy(\.isTerminated)
    }

    private func presentFailure(_ error: Error, groupName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Problems.noDockIcon(groupName)
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
