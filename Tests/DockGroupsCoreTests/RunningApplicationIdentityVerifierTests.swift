import Foundation
import os
import Testing
@testable import DockGroupsCore

// MARK: - Fakes

/// What the fake Security comparison answers for each PID (`.unknown` when not set). Thread-safe:
/// the comparison runs on another thread.
final class FakeComparisons: Sendable {
    private let table = OSAllocatedUnfairLock<[Int32: ApplicationRunningCodeVerifier.Comparison]>(initialState: [:])
    private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

    subscript(pid: Int32) -> ApplicationRunningCodeVerifier.Comparison {
        get { table.withLock { $0[pid] ?? .unknown } }
        set { table.withLock { $0[pid] = newValue } }
    }

    var callCount: Int { calls.withLock { $0 } }

    func compare(_ pid: Int32) -> ApplicationRunningCodeVerifier.Comparison {
        calls.withLock { $0 += 1 }
        return self[pid]
    }
}

/// Holds whatever waits on it until `open()`.
final class FakeGate: Sendable {
    private let isOpen = OSAllocatedUnfairLock(initialState: false)
    private let semaphore = DispatchSemaphore(value: 0)

    func open() {
        isOpen.withLock { $0 = true }
        semaphore.signal()
    }

    /// Blocks the calling thread (a stand-in for a Security call that doesn't return).
    func block() {
        semaphore.wait()
        semaphore.signal()
    }

    /// Waits without blocking a thread.
    func wait() async throws {
        while !isOpen.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A process watch whose next poll a test sets; terminal events latch, and a closed watch only
/// answers `.unknown`, like the real one.
final class FakeProcessWatch: ApplicationProcessWatching {
    var event: ExperimentalProcessEventWatchPollResult = .idle
    private(set) var isClosed = false
    private var latched = false

    func poll() -> ExperimentalProcessEventWatchPollResult {
        guard !isClosed, !latched else { return .unknown }
        if event != .idle { latched = true }
        return event
    }

    func close() { isClosed = true }
}

/// Waits (in real time, the checks run on other threads) until `condition` holds.
@MainActor
func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A real verifier over fake instances, watches and Security answers; with a coordinator whose
/// rules come from a `TriggerStore` (so a saved re-approval can be read back).
@MainActor
final class VerifierRig {
    nonisolated static let bundle = "com.example.app"
    nonisolated static let work = DockGroup.of("Work", ["com.apple.mail"])
    nonisolated static let binding = ApplicationIdentityBinding.fixture(bundle)

    var instances: [Int32]? = []
    private(set) var instanceReads = 0
    private(set) var watches: [FakeProcessWatch] = []
    var watchFor: [Int32: FakeProcessWatch] = [:]
    var failsToWatch: Set<Int32> = []
    let comparisons = FakeComparisons()
    let blocker = FakeGate()
    let retryGate = FakeGate()
    let persistence: MemoryTriggerPersistence
    let store: TriggerStore
    let sleeper = FakeSleeper()
    let clock = TestClock()
    let handler = FakePresenceHandler(groups: [VerifierRig.work])
    let presenter = FakeNoticePresenter()
    let verifier: RunningApplicationIdentityVerifier
    let coordinator: TriggerCoordinator
    private(set) var restartRequests = 0
    private(set) var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    /// - Parameters:
    ///   - blocksSecurity: The fake Security call doesn't return until the rig is torn down.
    ///   - checkTimeout: The check's time bound.
    ///   - coordinated: Whether the coordinator uses the verifier (it then forgets bindings no rule
    ///     has); `false` tests the verifier alone.
    init(_ triggers: [GroupTrigger], blocksSecurity: Bool = false, checkTimeout: Duration = .seconds(30), coordinated: Bool = true) {
        persistence = MemoryTriggerPersistence(triggers)
        store = TriggerStore(persistence: persistence, saveDelay: .zero)
        weak var box: VerifierRig?
        let comparisons = comparisons, blocker = blocker, retryGate = retryGate
        verifier = RunningApplicationIdentityVerifier(
            instances: { _ in box?.readInstances() },
            makeWatch: { pid in box?.makeWatch(pid) },
            check: ApplicationRunningCodeCheck(timeout: checkTimeout, compare: { pid, _, _ in
                if blocksSecurity { blocker.block() }
                return comparisons.compare(pid)
            }),
            retryInterval: .milliseconds(1),
            sleep: { _ in try await retryGate.wait() }
        )
        clock.now = TriggerTime.date(2026, 10, 28, 8, 0)
        let clock = clock
        coordinator = TriggerCoordinator(
            state: TriggerState(),
            rules: { [store] in store.triggers },
            activeGroups: { [VerifierRig.work.id] },
            sleeper: sleeper,
            clock: { clock.now },
            calendar: { TriggerTime.calendar() }
        )
        box = self
        if coordinated {
            coordinator.applicationIdentityVerifier = verifier
        }
        coordinator.onApplicationIdentityCodeChanged = { [store] ids in store.requireApplicationReapproval(for: ids) }
        coordinator.onApplicationObservationsNeedRestart = { box?.restartRequests += 1 }
        coordinator.handler = handler
        coordinator.noticePresenter = presenter
        coordinator.start()
    }

    func tearDown() {
        blocker.open()
        retryGate.open()
        verifier.retainOnly([])
    }

    private func readInstances() -> [Int32]? {
        instanceReads += 1
        return instances
    }

    private func makeWatch(_ pid: Int32) -> (any ApplicationProcessWatching)? {
        guard !failsToWatch.contains(pid) else { return nil }
        let watch = watchFor[pid] ?? FakeProcessWatch()
        watchFor[pid] = nil
        watches.append(watch)
        return watch
    }

    var allWatchesClosed: Bool { watches.allSatisfy { $0.isClosed } }

    /// The latest watch registered (the one a check relies on).
    func latestWatch() -> FakeProcessWatch? { watches.last }

    func begin() -> Bool {
        generation += 1
        sequence = 0
        return coordinator.beginApplicationObservations(generation: generation)
    }

    @discardableResult
    func observe(_ count: Int) -> TriggerCoordinator.ApplicationObservationOutcome {
        sequence += 1
        return coordinator.observeApplications(generation: generation, sequence: sequence, counts: [Self.bundle: count])
    }

    var verdict: ApplicationIdentityVerdict? { verifier.displayedVerdict(for: Self.binding) }

    func outcome(_ trigger: GroupTrigger) -> TriggerOutcome? {
        coordinator.state.entry(for: trigger.id).lastOutcome
    }

    /// Ends the settle that's sleeping and waits for what follows.
    func endSettle() async -> Bool {
        guard await eventually({ sleeper.sleepingCount > 0 }) else { return false }
        sleeper.wakeAll()
        return true
    }

    static func trigger(_ action: TriggerAction, runMode: TriggerRunMode = .immediately, edge: TriggerEdge = .starts, identity: ApplicationIdentityAuthorization = .authorize(binding)) -> GroupTrigger {
        var trigger = GroupTrigger(groupID: work.id, event: .applicationPresence(bundleIdentifier: bundle, edge: edge), action: action, runMode: runMode)
        trigger.applicationIdentity = identity
        return trigger
    }
}

/// Records actions like `FakeAutomationHandler`, under another name so the rig doesn't depend on
/// the coordinator tests' rig.
@MainActor
final class FakePresenceHandler: AutomationHandling {
    let groups: [DockGroup]
    private(set) var calls: [String] = []
    init(groups: [DockGroup]) { self.groups = groups }
    func group(withID id: DockGroup.ID) -> DockGroup? { groups.first { $0.id == id } }
    var currentGroupID: DockGroup.ID? { nil }
    var currentGroupStartTrigger: TransitionTrigger? { nil }
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport? {
        calls.append("start")
        return nil
    }
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport? {
        calls.append("finish")
        return nil
    }
    func openAllItems(of group: DockGroup) async -> LaunchReport {
        calls.append("openAll")
        return LaunchReport(groupName: group.name, entries: [])
    }
    func showPopup(of group: DockGroup) { calls.append("popup") }
}

// MARK: - One check

@Suite("Application identity: one running-code check")
struct ApplicationRunningCodeCheckTests {
    private static let identifier = "com.example.app"
    private static let hash = ApplicationIdentityBinding.fixtureHash

    private func check(_ comparison: ApplicationRunningCodeVerifier.Comparison) async -> ApplicationCodeCheckResult {
        await ApplicationRunningCodeCheck(compare: { _, _, _ in comparison }).check(pid: 42, identifier: Self.identifier, codeHash: Self.hash)
    }

    @Test func mapsTheSecurityAnswer() async {
        #expect(await check(.matching) == .verified)
        #expect(await check(.different) == .codeChanged)
        #expect(await check(.unknown) == .unavailable(.securityUnavailable))
    }

    @Test func invalidInputIsNeverChecked() async {
        let comparisons = FakeComparisons()
        comparisons[0] = .matching
        let check = ApplicationRunningCodeCheck(compare: { pid, _, _ in comparisons.compare(pid) })
        #expect(await check.check(pid: 0, identifier: Self.identifier, codeHash: Self.hash) == .unavailable(.invalidInput))
        #expect(await check.check(pid: -1, identifier: Self.identifier, codeHash: Self.hash) == .unavailable(.invalidInput))
        #expect(await check.check(pid: 42, identifier: "x\" or anchor apple", codeHash: Self.hash) == .unavailable(.invalidInput))
        #expect(await ApplicationRunningCodeCheck(timeout: .zero, compare: { _, _, _ in .matching }).check(pid: 42, identifier: Self.identifier, codeHash: Self.hash) == .unavailable(.invalidInput))
        #expect(comparisons.callCount == 0)
    }

    @Test func aTimeOutIsUnavailableEvenIfSecurityLaterMatches() async {
        let gate = FakeGate()
        defer { gate.open() }
        // The time bound passes at once; the Security call is still blocked.
        let check = ApplicationRunningCodeCheck(timeout: .seconds(2), compare: { _, _, _ in
            gate.block()
            return .matching
        }, sleep: { _ in })
        #expect(await check.check(pid: 42, identifier: Self.identifier, codeHash: Self.hash) == .unavailable(.timedOut))
    }

    @Test func cancellationIsUnavailableNeverVerified() async {
        let gate = FakeGate()
        defer { gate.open() }
        let check = ApplicationRunningCodeCheck(timeout: .seconds(60), compare: { _, _, _ in
            gate.block()
            return .matching
        })
        let task = Task { await check.check(pid: 42, identifier: Self.identifier, codeHash: Self.hash) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(await task.value == .unavailable(.cancelled))
        // Already cancelled: not even started.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await check.check(pid: 42, identifier: Self.identifier, codeHash: Self.hash)
        }
        #expect(await early.value == .unavailable(.cancelled))
    }

    @Test func realSecurityDistinguishesTheAuthorizedCodeFromALookAlike() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cybokron-identity-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.app", isDirectory: true)
        let other = root.appendingPathComponent("Other.app", isDirectory: true)
        try SignedFixture.make(at: selected, name: "Selected")
        try SignedFixture.make(at: other, name: "Other")
        let expected = try #require(ApplicationStaticCodeVerifier.codeHashes(for: selected)?.first)
        var children: [Process] = []
        defer {
            for process in children {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
        }
        let genuine = try SignedFixture.run(selected); children.append(genuine)
        let lookAlike = try SignedFixture.run(other); children.append(lookAlike)
        let check = ApplicationRunningCodeCheck()
        #expect(await check.check(pid: genuine.processIdentifier, identifier: SignedFixture.identifier, codeHash: expected) == .verified)
        #expect(await check.check(pid: lookAlike.processIdentifier, identifier: SignedFixture.identifier, codeHash: expected) == .codeChanged)
        #expect(await check.check(pid: Int32.max, identifier: SignedFixture.identifier, codeHash: expected) == .unavailable(.securityUnavailable))
    }
}

/// Two thin, ad hoc signed copies of `/bin/sleep` with the same identifier and different code.
enum SignedFixture {
    static let identifier = "com.cybokron.fixture.running"

    static func make(at url: URL, name: String) throws {
        let dir = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let thin = Process()
        thin.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        #if arch(arm64)
        let architecture = "arm64e"
        #else
        let architecture = "x86_64"
        #endif
        thin.arguments = ["-thin", architecture, "/bin/sleep", "-output", dir.appendingPathComponent("Fixture").path]
        thin.standardOutput = Pipe(); thin.standardError = Pipe()
        try thin.run(); thin.waitUntilExit()
        try #require(thin.terminationStatus == 0)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "-r", "=designated => identifier \"\(identifier)\"", url.path]
        signing.standardOutput = Pipe(); signing.standardError = Pipe()
        try signing.run(); signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)
    }

    static func run(_ url: URL) throws -> Process {
        let process = Process()
        process.executableURL = url.appendingPathComponent("Contents/MacOS/Fixture")
        process.arguments = ["20"]
        try process.run()
        return process
    }
}

// MARK: - The verifier

@Suite("Application identity: running-code verifier")
@MainActor
struct RunningApplicationIdentityVerifierTests {
    private let binding = VerifierRig.binding

    @Test func nothingRunningIsVerifiedWithoutAnyCheck() {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        #expect(rig.verifier.verdict(for: binding) == .verified)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.comparisons.callCount == 0)
    }

    @Test func aNewInstanceIsPendingThenVerifiedAndMayLeave() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        #expect(rig.verifier.watchCount == 1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(changes == 1)
        #expect(rig.verifier.verdict(for: binding) == .verified)
        // The verified instance quits: still verified, and its watch is closed.
        rig.latestWatch()?.event = .exit
        rig.instances = []
        #expect(rig.verifier.verdict(for: binding) == .verified)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func differentCodeIsCodeChangedAndClosesTheWatches() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42, 43]
        rig.comparisons[42] = .matching
        rig.comparisons[43] = .different
        #expect(rig.verifier.verdict(for: binding) == .pending)
        #expect(await eventually { rig.verdict == .codeChanged })
        #expect(rig.verifier.verdict(for: binding) == .codeChanged)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
    }

    @Test func aSecurityFailureIsUnavailable() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .unknown
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(rig.verifier.lastFailure == .securityUnavailable)
        #expect(rig.verifier.watchCount == 0)
    }

    @Test func aTimedOutCheckIsUnavailableNeverVerified() async {
        let rig = VerifierRig([], blocksSecurity: true, checkTimeout: .milliseconds(50), coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(rig.verifier.lastFailure == .timedOut)
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
    }

    @Test func watchProblemsAreUnavailableWithoutACheck() {
        // Registration fails (the process may be gone).
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.failsToWatch = [42]
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .watchUnavailable)
        // Something was already pending at registration.
        let raced = VerifierRig([], coordinated: false)
        defer { raced.tearDown() }
        let watch = FakeProcessWatch()
        watch.event = .exec
        raced.watchFor[42] = watch
        raced.instances = [42]
        #expect(raced.verifier.verdict(for: binding) == .unavailable)
        #expect(raced.verifier.lastFailure == .processChanged)
        #expect(watch.isClosed)
        // The instances can't be listed, or there are too many.
        let unknown = VerifierRig([], coordinated: false)
        defer { unknown.tearDown() }
        unknown.instances = nil
        #expect(unknown.verifier.verdict(for: binding) == .unavailable)
        #expect(unknown.verifier.lastFailure == .instancesUnknown)
        let many = VerifierRig([], coordinated: false)
        defer { many.tearDown() }
        many.instances = Array(1...Int32(RunningApplicationIdentityVerifier.maximumInstancesPerApplication + 1))
        #expect(many.verifier.verdict(for: binding) == .unavailable)
        #expect(many.verifier.lastFailure == .tooManyInstances)
        #expect(many.verifier.watchCount == 0)
        for rig in [rig, raced, unknown, many] {
            #expect(rig.comparisons.callCount == 0)
        }
    }

    @Test func anExecAfterVerificationIsUnavailable() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        rig.latestWatch()?.event = .exec
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        #expect(rig.verifier.watchCount == 0)
    }

    @Test func anInstanceLeavingBeforeItsCheckFinishedIsUnavailable() async {
        let rig = VerifierRig([], blocksSecurity: true, coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.verifier.verdict(for: binding) == .pending)
        rig.instances = []
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        #expect(rig.verifier.lastFailure == .processChanged)
        // The blocked check's late answer changes nothing.
        rig.blocker.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
    }

    @Test func aFailedBindingIsRetriedAndOnlyThenVerified() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        var changes = 0
        rig.verifier.setVerdictsChangedHandler { changes += 1 }
        rig.instances = [42]
        rig.comparisons[42] = .unknown
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .unavailable })
        #expect(changes == 1)
        rig.comparisons[42] = .matching
        // Still unavailable until the retry has confirmed it.
        #expect(rig.verifier.verdict(for: binding) == .unavailable)
        rig.retryGate.open()
        #expect(await eventually { rig.verdict == .verified })
        #expect(changes == 2)
    }

    @Test func forgottenBindingsCloseTheirWatches() async {
        let rig = VerifierRig([], coordinated: false)
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .matching
        _ = rig.verifier.verdict(for: binding)
        #expect(await eventually { rig.verdict == .verified })
        rig.verifier.retainOnly([])
        #expect(rig.verdict == nil)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.allWatchesClosed)
    }
}

// MARK: - The coordinator with the verifier

@Suite("Application identity: the coordinator with the running-code verifier")
@MainActor
struct ApplicationIdentityVerifierCoordinatorTests {
    private let binding = VerifierRig.binding

    @Test func codeChangeIsSavedAsNeedingReapprovalAndCancelsTheNotice() async {
        let trigger = VerifierRig.trigger(.start, runMode: .notice)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        rig.presenter.holds = true
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        #expect(rig.observe(1) == .accepted(isUncertain: false))
        #expect(await eventually { rig.verdict == .verified })
        #expect(await rig.endSettle())
        #expect(await eventually { rig.presenter.isShowing })
        // Another instance under the identifier is different code.
        rig.instances = [42, 43]
        rig.comparisons[43] = .different
        rig.observe(2)
        #expect(await eventually { rig.store.triggers.first?.applicationIdentityStatus == .needsReapproval })
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.presenter.dismissCount == 1)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.anotherTrigger))
        // Saved, and read back as waiting: it can't run and isn't observed.
        #expect(rig.persistence.saved.first?.applicationIdentity == .needsReapproval(binding))
        let reloaded = TriggerStore(persistence: rig.persistence, saveDelay: .zero)
        #expect(reloaded.triggers.first?.applicationIdentity == .needsReapproval(binding))
        #expect(reloaded.triggers.first?.isRunnable == false)
        #expect(!rig.begin())
        #expect(rig.verifier.watchCount == 0)
    }

    @Test func codeChangeDropsAPendingFiringAndNothingRuns() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .different
        rig.observe(1)
        #expect(await eventually { rig.persistence.saved.first?.applicationIdentityStatus == .needsReapproval })
        #expect(await eventually { rig.coordinator.isIdle || rig.sleeper.sleepingCount > 0 })
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.waitingFirings.isEmpty)
        #expect(rig.store.triggers.first?.isEnabled == true)
        #expect(rig.store.triggers.first?.canRun == false)
    }

    @Test func authorizedButUnverifiableIsRecordedAndRunsNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .unknown
        rig.observe(1)
        #expect(await eventually { rig.outcome(trigger) == .skipped(.applicationNotConfirmed) })
        #expect(await eventually { rig.coordinator.isIdle || rig.sleeper.sleepingCount > 0 })
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        // It isn't a code change: the approval stays, and the app is asked to restart observations.
        #expect(rig.store.triggers.first?.applicationIdentityStatus == .authorized)
        #expect(await eventually { rig.restartRequests == 1 })
        #expect(rig.coordinator.applicationIdentityIsUnconfirmed(rig.store.triggers[0]))
        let line = TriggerDescriptions.lastRun(rig.coordinator.state.entry(for: trigger.id), groupName: "Work", now: rig.clock.now, calendar: TriggerTime.calendar(), locale: Locale(identifier: "en_US"))
        #expect(line.hasSuffix(": the app's running code couldn't be confirmed, so nothing ran."))
    }

    @Test func aCheckStillRunningAtTheSettleWaitsOnceThenIsRecorded() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger], blocksSecurity: true)
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(rig.verdict == .pending)
        #expect(await rig.endSettle())
        // Put off once for the check …
        #expect(await rig.endSettle())
        // … then skipped and recorded.
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func aConfirmedFiringRuns() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["openAll"])
        #expect(rig.outcome(trigger) == .ran(.openAll))
    }

    @Test func verdictChangesRestartObservationsAndOldGenerationsProduceNothing() async {
        let trigger = VerifierRig.trigger(.showPopup, edge: .ends)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        rig.instances = [42]
        rig.comparisons[42] = .unknown
        // Being checked: observed.
        #expect(rig.begin())
        let first = rig.generation
        rig.observe(1)
        // The check fails: the tracker stops and a restart is asked for.
        #expect(await eventually { rig.restartRequests == 1 })
        #expect(rig.verdict == .unavailable)
        // The app restarts: the rule isn't observed while it can't be confirmed.
        #expect(!rig.begin())
        #expect(rig.coordinator.observeApplications(generation: first, sequence: 2, counts: [VerifierRig.bundle: 0]) == .stopped)
        // The retry confirms it: observed again, under a new generation.
        rig.comparisons[42] = .matching
        rig.retryGate.open()
        #expect(await eventually { rig.restartRequests == 2 })
        #expect(rig.verdict == .verified)
        let second = rig.generation
        #expect(rig.begin())
        #expect(rig.coordinator.observeApplications(generation: first, sequence: 3, counts: [VerifierRig.bundle: 0]) == .rejected)
        #expect(rig.coordinator.observeApplications(generation: second, sequence: 1, counts: [VerifierRig.bundle: 0]) == .rejected)
        // Only the new generation's own close runs, once.
        rig.observe(1)
        rig.instances = []
        rig.observe(0)
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["popup"])
    }

    @Test func anExecBeforeTheActionIsRecordedAndRunsNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await eventually { rig.verdict == .verified })
        rig.latestWatch()?.event = .exec
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.applicationNotConfirmed))
    }

    @Test func aSnapshotTheVerifiersOwnListDisagreesWithConfirmsNothing() async {
        let trigger = VerifierRig.trigger(.openAll)
        let rig = VerifierRig([trigger])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        // The snapshot counts an instance the verifier can't find: never a vacuous "verified".
        rig.observe(1)
        #expect(rig.verdict == .unavailable)
        #expect(rig.verifier.lastFailure == .instancesUnknown)
        #expect(await eventually { rig.coordinator.isIdle || rig.sleeper.sleepingCount > 0 })
        rig.sleeper.wakeAll()
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.comparisons.callCount == 0)
    }

    @Test func unverifiedRulesStillOnlyShowThePopupAndAreNeverChecked() async {
        let popup = VerifierRig.trigger(.showPopup, identity: .unverified)
        let start = VerifierRig.trigger(.start, runMode: .notice, identity: .unverified)
        let rig = VerifierRig([popup, start])
        defer { rig.tearDown() }
        #expect(rig.begin())
        rig.observe(0)
        rig.instances = [42]
        rig.comparisons[42] = .matching
        rig.observe(1)
        #expect(await rig.endSettle())
        #expect(await eventually { rig.coordinator.isIdle })
        #expect(rig.handler.calls == ["popup"])
        #expect(rig.outcome(start) == .skipped(.applicationNotVerified))
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.instanceReads == 0)
        #expect(rig.verifier.watchCount == 0)
        #expect(rig.comparisons.callCount == 0)
    }

    @Test func theDefaultVerifierStillNeverConfirms() {
        let coordinator = TriggerCoordinator(state: TriggerState(), rules: { [] }, activeGroups: { [] })
        #expect(coordinator.applicationIdentityVerifier is UnavailableApplicationIdentityVerifier)
        coordinator.verifyRunningApplicationIdentities()
        #expect(coordinator.applicationIdentityVerifier is RunningApplicationIdentityVerifier)
        // Never checked: not confirmed.
        #expect(coordinator.applicationIdentityIsUnconfirmed(VerifierRig.trigger(.openAll)))
        #expect(!coordinator.applicationIdentityIsUnconfirmed(VerifierRig.trigger(.showPopup, identity: .unverified)))
    }

    @Test func theStoreOnlyEverNarrowsTrust() {
        let authorized = VerifierRig.trigger(.openAll)
        let unverified = VerifierRig.trigger(.showPopup, identity: .unverified)
        let persistence = MemoryTriggerPersistence([authorized, unverified])
        let store = TriggerStore(persistence: persistence, saveDelay: .zero)
        #expect(store.requireApplicationReapproval(for: [authorized.id, unverified.id, UUID()]) == [authorized.id])
        #expect(store.trigger(withID: authorized.id)?.applicationIdentity == .needsReapproval(binding))
        #expect(store.trigger(withID: unverified.id)?.applicationIdentity == .unverified)
        #expect(persistence.saved.first?.applicationIdentity == .needsReapproval(binding))
        // Again: nothing more changes, nothing is written.
        let saves = persistence.saveCount
        #expect(store.requireApplicationReapproval(for: [authorized.id]).isEmpty)
        #expect(persistence.saveCount == saves)
    }
}
