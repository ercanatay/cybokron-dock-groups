import AppKit
@testable import DockGroupsCore

/// What the fakes of the switching tests did, in order: "hide:<identity>", "quit:<identity>",
/// "force:<identity>", "unhide:<identity>", "front:<identity>", "launch:<bundle id>",
/// "files", "websites".
@MainActor
final class SwitchingLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func events(withPrefix prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// A running app of `FakeRunningApps`: records what's done to it in the shared log. Its methods
/// are called on the main actor, as `NSRunningApplication`'s are.
final class FakeRunningApp: SwitchableApplication {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
    let identity: String
    let name: String
    var isTerminated = false
    var isHidden: Bool
    var isRegular: Bool
    /// Says no to every request.
    var refuses = false
    private let log: SwitchingLog

    init(pid: pid_t, bundleIdentifier: String?, bundleURL: URL? = nil, name: String, isHidden: Bool, isRegular: Bool, log: SwitchingLog) {
        processIdentifier = pid
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        identity = RunningAppSnapshot.identity(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL) ?? ""
        self.name = name
        self.isHidden = isHidden
        self.isRegular = isRegular
        self.log = log
    }

    var snapshot: RunningAppSnapshot {
        RunningAppSnapshot(processIdentifier: processIdentifier, identity: identity, name: name, isHidden: isHidden, isRegular: isRegular)
    }

    func hide() -> Bool {
        MainActor.assumeIsolated {
            log.record("hide:\(identity)")
            guard !refuses else { return false }
            isHidden = true
            return true
        }
    }

    func unhide() -> Bool {
        MainActor.assumeIsolated {
            log.record("unhide:\(identity)")
            guard !refuses else { return false }
            isHidden = false
            return true
        }
    }

    func terminate() -> Bool {
        MainActor.assumeIsolated {
            log.record("quit:\(identity)")
            guard !refuses else { return false }
            isTerminated = true
            return true
        }
    }

    func forceTerminate() -> Bool {
        MainActor.assumeIsolated {
            log.record("force:\(identity)")
            isTerminated = true
            return true
        }
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        MainActor.assumeIsolated {
            log.record("front:\(identity)")
            return !refuses
        }
    }
}

/// The running apps, for both `RunningApplicationsListing` (transitions) and
/// `RunningApplicationsProviding` (Close All and Hide All).
@MainActor
final class FakeRunningApps: RunningApplicationsListing, RunningApplicationsProviding {
    let log: SwitchingLog
    private(set) var apps: [FakeRunningApp] = []
    private var nextPID: pid_t = 100

    init(log: SwitchingLog? = nil) {
        self.log = log ?? SwitchingLog()
    }

    /// Adds a running app with this bundle identifier; returns it.
    @discardableResult
    func run(_ bundleIdentifier: String, name: String? = nil, hidden: Bool = false, regular: Bool = true, pid: pid_t? = nil) -> FakeRunningApp {
        let pid = pid ?? { nextPID += 1; return nextPID }()
        let app = FakeRunningApp(pid: pid, bundleIdentifier: bundleIdentifier, name: name ?? bundleIdentifier, isHidden: hidden, isRegular: regular, log: log)
        apps.append(app)
        return app
    }

    /// Replaces the app with process identifier `pid` by another app: as if it quit and macOS
    /// gave its identifier to a new process.
    func reuse(pid: pid_t, for bundleIdentifier: String) {
        apps.removeAll { $0.processIdentifier == pid }
        run(bundleIdentifier, pid: pid)
    }

    func app(_ bundleIdentifier: String) -> FakeRunningApp? {
        apps.first { $0.identity == bundleIdentifier.lowercased() }
    }

    func runningApplications() -> [RunningAppSnapshot] {
        apps.filter { !$0.isTerminated }.map(\.snapshot)
    }

    func application(withProcessIdentifier processIdentifier: pid_t) -> (any SwitchableApplication)? {
        apps.first { $0.processIdentifier == processIdentifier && !$0.isTerminated }
    }

    func runningApplications(bundleIdentifier: String) -> [any QuittableApplication] {
        apps.filter { $0.identity == bundleIdentifier.lowercased() && !$0.isTerminated }
    }
}

/// Opens nothing for real: every app is installed and launches; records launches in the log.
/// With `holdsLaunches`, each launch waits until `releaseLaunches()`.
@MainActor
final class SwitchingWorkspace: ApplicationWorkspace {
    private let log: SwitchingLog
    var holdsLaunches = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var launched: [String] = []

    init(log: SwitchingLog) {
        self.log = log
    }

    var heldLaunchCount: Int { held.count }

    func releaseLaunches() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func activateRunningApplication(bundleIdentifier: String) -> Bool { false }

    func locateApplication(_ app: AppReference) -> URL? {
        URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app")
    }

    func launchApplication(at url: URL) async throws {
        let bundleIdentifier = url.deletingPathExtension().lastPathComponent
        if holdsLaunches {
            await withCheckedContinuation { held.append($0) }
        }
        launched.append(bundleIdentifier)
        log.record("launch:\(bundleIdentifier)")
    }

    func openWebsites(_ urls: [URL]) async throws {
        log.record("websites")
    }

    func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        log.record("files")
        return [:]
    }

    func revealFileItems(_ urls: [URL]) {}
}

/// Answers a link's transition question with `answer`, recording the questions.
@MainActor
final class FakeTransitionPrompt: TransitionConfirmationPrompting {
    var answer: TransitionConfirmation.Answer
    private(set) var asked: [TransitionConfirmation] = []

    init(answer: TransitionConfirmation.Answer) {
        self.answer = answer
    }

    func confirm(_ confirmation: TransitionConfirmation) -> TransitionConfirmation.Answer {
        asked.append(confirmation)
        return answer
    }
}

/// Answers Close All's question with `answer`; `whileAsking` runs inside the question.
@MainActor
final class FakeQuitPrompt: QuitConfirmationPrompting {
    var answer: Bool
    var whileAsking: (() -> Void)?

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ confirmation: QuitConfirmation) -> Bool {
        whileAsking?()
        return answer
    }
}

/// Preferences kept in memory.
final class MemoryPreferencesPersistence: PreferencesPersisting {
    private var saved: PopupPreferences?

    init(_ preferences: PopupPreferences? = nil) {
        saved = preferences
    }

    func loadPreferences() throws -> PopupPreferences? { saved }
    func savePreferences(_ preferences: PopupPreferences) throws { saved = preferences }
    func preserveUnreadableData() throws -> URL? { nil }
}

/// A clock the tests move by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Everything a `ContextSwitcher` needs, with fakes, around the given groups.
@MainActor
struct SwitchingRig {
    let log = SwitchingLog()
    let apps: FakeRunningApps
    let workspace: SwitchingWorkspace
    let store: GroupStore
    let preferences: PreferencesStore
    let session = ContextSession()
    let terminator: GroupTerminator
    let transitionPrompt: FakeTransitionPrompt
    let quitPrompt = FakeQuitPrompt(answer: true)
    let quitRequests: GroupQuitRequests
    let clock = TestClock()
    let switcher: ContextSwitcher
    static let ownPID: pid_t = 1

    init(groups: [DockGroup], protected: [GroupItem] = [], answer: TransitionConfirmation.Answer = .quit) {
        apps = FakeRunningApps(log: log)
        workspace = SwitchingWorkspace(log: log)
        let persistence = MemoryGroupPersistence()
        try? persistence.saveGroups(groups)
        store = GroupStore(persistence: persistence, saveDelay: .zero)
        let preferences = PreferencesStore(persistence: MemoryPreferencesPersistence(PopupPreferences(protectedApps: ProtectedApps(protected))), saveDelay: .zero)
        self.preferences = preferences
        let apps = self.apps
        terminator = GroupTerminator(
            applications: apps,
            ownProcessIdentifier: Self.ownPID,
            listing: apps,
            protectedApps: { preferences.preferences.protectedApps }
        )
        transitionPrompt = FakeTransitionPrompt(answer: answer)
        let terminator = self.terminator
        quitRequests = GroupQuitRequests(prompt: quitPrompt, transitionPrompt: transitionPrompt) { group, mode in
            terminator.closeAll(group, mode: mode)
        }
        let clock = self.clock
        switcher = ContextSwitcher(
            store: store,
            preferences: preferences,
            session: session,
            launcher: GroupLauncher(workspace: workspace, locator: ScriptedLocator()),
            terminator: terminator,
            applications: apps,
            questions: quitRequests,
            clock: { clock.now }
        )
    }
}

extension DockGroup {
    /// A group of apps with these bundle identifiers (named after them), with `switching`.
    static func of(_ name: String, _ bundleIdentifiers: [String], switching: GroupSwitching = GroupSwitching()) -> DockGroup {
        DockGroup(
            name: name,
            apps: bundleIdentifiers.map { AppReference(bundleIdentifier: $0, name: $0) },
            switching: switching
        )
    }
}
