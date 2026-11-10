import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

/// A scripted, read-only Accessibility source. Elements are integers; every call is counted.
final class FakeAccessibilityReader: LayoutAccessibilityReading {
    var trusted = true
    /// Window list per process identifier; a missing entry is a failed read.
    var windowLists: [pid_t: LayoutAccessibilityRead<[Int?]>] = [:]
    /// Attribute values per window element; a missing attribute reads as `.missing`.
    var attributes: [Int: [String: LayoutAccessibilityRead<AnyObject>]] = [:]
    /// Called before every attribute read, e.g. to advance a clock.
    var onAttributeRead: () -> Void = {}

    private(set) var trustChecks = 0
    private(set) var applicationCalls: [pid_t] = []
    private(set) var windowListCalls = 0
    private(set) var attributeCalls: [(window: Int, name: String)] = []

    var accessibilityCallCount: Int { applicationCalls.count + windowListCalls + attributeCalls.count }

    func isProcessTrusted() -> Bool {
        trustChecks += 1
        return trusted
    }

    func application(processIdentifier: pid_t) -> Int {
        applicationCalls.append(processIdentifier)
        return Int(processIdentifier)
    }

    func windows(of application: Int) -> LayoutAccessibilityRead<[Int?]> {
        windowListCalls += 1
        return windowLists[pid_t(application)] ?? .failure(.failed)
    }

    func attribute(_ name: String, of window: Int) -> LayoutAccessibilityRead<AnyObject> {
        attributeCalls.append((window, name))
        onAttributeRead()
        return attributes[window]?[name] ?? .failure(.missing)
    }

    /// A standard, unminimized window at `frame` (Accessibility coordinates).
    func addStandardWindow(_ element: Int, frame: CGRect = CGRect(x: 100, y: 200, width: 800, height: 600)) {
        attributes[element] = [
            kAXRoleAttribute: .value(kAXWindowRole as CFString),
            kAXSubroleAttribute: .value(kAXStandardWindowSubrole as CFString),
            kAXMinimizedAttribute: .value(kCFBooleanFalse),
            kAXPositionAttribute: .value(Self.point(frame.origin)),
            kAXSizeAttribute: .value(Self.size(frame.size)),
        ]
    }

    static func point(_ point: CGPoint) -> AnyObject {
        var point = point
        return AXValueCreate(.cgPoint, &point)!
    }

    static func size(_ size: CGSize) -> AnyObject {
        var size = size
        return AXValueCreate(.cgSize, &size)!
    }
}

struct LayoutAccessibilityObserverTests {
    typealias Observer = LayoutAccessibilityObserver<FakeAccessibilityReader>

    private static let bundle = "com.example.editor"
    private static let other = "com.example.viewer"

    private static func observer(
        _ reader: FakeAccessibilityReader,
        instances: [String: Observer.RunningInstances] = [bundle: .one(10), other: .one(20)],
        protection: @escaping (String) -> WindowObservations.TriState = { _ in .no },
        budget: TimeInterval = 2,
        now: @escaping () -> TimeInterval = { 0 }
    ) -> Observer {
        Observer(
            reader: reader,
            runningInstances: { instances[$0] ?? .none },
            protection: protection,
            appReadBudget: budget,
            now: now
        )
    }

    // MARK: - Permission

    @Test func permissionIsTheTrustCheck() {
        let reader = FakeAccessibilityReader()
        #expect(Self.observer(reader).accessibilityPermission() == .granted)
        reader.trusted = false
        #expect(Self.observer(reader).accessibilityPermission() == .denied)
        #expect(reader.accessibilityCallCount == 0)
    }

    @Test func deniedPermissionMakesNoAccessibilityCall() {
        let reader = FakeAccessibilityReader()
        reader.trusted = false
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        var lookups = 0
        let observer = Observer(
            reader: reader,
            runningInstances: { _ in lookups += 1; return .one(10) },
            protection: { _ in .no }
        )
        let observations = observer.observeWindows(bundleIdentifiers: [Self.bundle, Self.other])
        #expect(reader.accessibilityCallCount == 0)
        #expect(lookups == 0)
        #expect(observations.map(\.bundleIdentifier) == [Self.bundle, Self.other])
        for observation in observations {
            #expect(observation.appRunningUnprotected == .unknown)
            #expect(observation.reportedWindowCount == nil)
            #expect(observation.windows.isEmpty)
            #expect(observation.completeSnapshot == .unknown)
        }
    }

    @Test func tooManyAppsMakeNoAccessibilityCall() {
        let reader = FakeAccessibilityReader()
        let identifiers = Array(repeating: Self.bundle, count: LayoutCapturePlanner.maximumObservationCount + 1)
        let observations = Self.observer(reader).observeWindows(bundleIdentifiers: identifiers)
        #expect(observations.count == identifiers.count)
        #expect(reader.accessibilityCallCount == 0)
        #expect(observations.allSatisfy { $0.reportedWindowCount == nil && $0.appRunningUnprotected == .unknown })
    }

    // MARK: - Reading

    @Test func readsOneStandardWindowAndLeavesUnprovableFactsUnknown() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.appRunningUnprotected == .yes)
        #expect(observation.reportedWindowCount == 1)
        #expect(observation.completeSnapshot == .yes)
        let window = try #require(observation.windows.first)
        #expect(window.topLeftFrame == CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(window.role == .window)
        #expect(window.subrole == .standardWindow)
        #expect(window.minimized == .no)
        #expect(window.visible == .unknown)
        #expect(window.onCurrentSpace == .unknown)
        #expect(window.fullScreen == .unknown)
        #expect(window.identifiable == .unknown)
        #expect(reader.applicationCalls == [10])
        #expect(Set(reader.attributeCalls.map(\.name)) == Set(Observer.attributeNames))
    }

    @Test func readsOnlyTheFiveGeometryAndKindAttributes() {
        #expect(Observer.attributeNames == [
            kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ])
        #expect(!Observer.attributeNames.contains(kAXTitleAttribute))
        #expect(!Observer.attributeNames.contains(kAXDocumentAttribute))
    }

    @Test func missingAttributesStayUnknownAndKeepTheWindow() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        reader.attributes[1]?[kAXSubroleAttribute] = nil
        reader.attributes[1]?[kAXMinimizedAttribute] = .failure(.missing)
        reader.attributes[1]?[kAXSizeAttribute] = nil
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.completeSnapshot == .yes)
        let window = try #require(observation.windows.first)
        #expect(window.role == .window)
        #expect(window.subrole == .unknown)
        #expect(window.minimized == .unknown)
        #expect(window.topLeftFrame == nil)
        #expect(window.standard == .unknown)
    }

    @Test func mismatchedTypesStayUnknown() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.attributes[1] = [
            kAXRoleAttribute: .value(NSNumber(value: 1)),
            kAXSubroleAttribute: .value(kCFBooleanTrue),
            // A number is not a boolean, even 0 or 1.
            kAXMinimizedAttribute: .value(NSNumber(value: 0)),
            // Position and size swapped.
            kAXPositionAttribute: .value(FakeAccessibilityReader.size(CGSize(width: 10, height: 10))),
            kAXSizeAttribute: .value(FakeAccessibilityReader.point(CGPoint(x: 10, y: 10))),
        ]
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        let window = try #require(observation.windows.first)
        #expect(window.role == .unknown)
        #expect(window.subrole == .unknown)
        #expect(window.minimized == .unknown)
        #expect(window.topLeftFrame == nil)
    }

    @Test(arguments: [
        CGSize(width: CGFloat.infinity, height: 10),
        CGSize(width: 10, height: CGFloat.nan),
        CGSize(width: -1, height: 10),
    ])
    func unusableSizesLeaveTheFrameUnknown(size: CGSize) throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        reader.attributes[1]?[kAXSizeAttribute] = .value(FakeAccessibilityReader.size(size))
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.windows.first?.topLeftFrame == nil)
    }

    @Test func nonFinitePositionLeavesTheFrameUnknown() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        reader.attributes[1]?[kAXPositionAttribute] = .value(FakeAccessibilityReader.point(CGPoint(x: CGFloat.nan, y: 0)))
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.windows.first?.topLeftFrame == nil)
    }

    @Test(arguments: [
        (kAXDialogSubrole, LayoutWindowObservation.Subrole.dialog),
        (kAXSystemDialogSubrole, .dialog),
        (kAXFloatingWindowSubrole, .other),
        (kAXStandardWindowSubrole, .standardWindow),
    ])
    func subrolesMap(subrole: String, expected: LayoutWindowObservation.Subrole) {
        #expect(Observer.subrole(subrole as CFString) == expected)
    }

    @Test func rolesAndBooleansMap() {
        #expect(Observer.role(kAXWindowRole as CFString) == .window)
        #expect(Observer.role(kAXSheetRole as CFString) == .other)
        #expect(Observer.role(nil) == .unknown)
        #expect(Observer.boolean(kCFBooleanTrue) == .yes)
        #expect(Observer.boolean(kCFBooleanFalse) == .no)
        #expect(Observer.boolean(NSNumber(value: 1)) == .unknown)
        #expect(Observer.boolean("true" as CFString) == .unknown)
    }

    @Test func nonElementEntriesMakeTheSnapshotIncomplete() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, nil, 2])
        reader.addStandardWindow(1)
        reader.addStandardWindow(2)
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.reportedWindowCount == 3)
        #expect(observation.windows.count == 2)
        #expect(observation.completeSnapshot == .no)
    }

    @Test(arguments: [LayoutAccessibilityReadFailure.elementGone, .failed])
    func oneUnreadableWindowIsLeftOutAndTheSnapshotIsIncomplete(failure: LayoutAccessibilityReadFailure) throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2, 3])
        reader.addStandardWindow(1)
        reader.addStandardWindow(2)
        reader.addStandardWindow(3, frame: CGRect(x: 5, y: 6, width: 7, height: 8))
        reader.attributes[2]?[kAXPositionAttribute] = .failure(failure)
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.reportedWindowCount == 3)
        #expect(observation.windows.count == 2)
        #expect(observation.windows.last?.topLeftFrame == CGRect(x: 5, y: 6, width: 7, height: 8))
        #expect(observation.completeSnapshot == .no)
    }

    @Test func unresponsiveAppIsNotAskedFurtherButOtherAppsAreRead() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2])
        reader.windowLists[20] = .value([3])
        reader.addStandardWindow(1)
        reader.addStandardWindow(2)
        reader.addStandardWindow(3)
        reader.attributes[1]?[kAXRoleAttribute] = .failure(.unresponsive)
        let observations = Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle, Self.other])
        #expect(observations[0].reportedWindowCount == 2)
        #expect(observations[0].windows.isEmpty)
        #expect(observations[0].completeSnapshot == .no)
        #expect(!reader.attributeCalls.contains { $0.window == 2 })
        #expect(observations[1].completeSnapshot == .yes)
        #expect(observations[1].windows.count == 1)
    }

    @Test func unreadableWindowListLeavesTheCountUnknown() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .failure(.unresponsive)
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.appRunningUnprotected == .yes)
        #expect(observation.reportedWindowCount == nil)
        #expect(observation.windows.isEmpty)
        #expect(observation.completeSnapshot == .unknown)
        #expect(reader.attributeCalls.isEmpty)
    }

    @Test func zeroWindowsIsACompleteEmptySnapshot() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([])
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.reportedWindowCount == 0)
        #expect(observation.completeSnapshot == .yes)
    }

    @Test func accessLostMidwayStopsAllReading() {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2])
        reader.windowLists[20] = .value([3])
        reader.addStandardWindow(1)
        reader.addStandardWindow(2)
        reader.addStandardWindow(3)
        reader.attributes[2]?[kAXRoleAttribute] = .failure(.accessDenied)
        let observations = Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle, Self.other])
        #expect(observations.allSatisfy { $0.reportedWindowCount == nil && $0.windows.isEmpty })
        #expect(observations[0].appRunningUnprotected == .yes)
        #expect(observations[1].appRunningUnprotected == .unknown)
        #expect(reader.applicationCalls == [10])
        #expect(!reader.attributeCalls.contains { $0.window == 3 })
    }

    @Test func accessLostOnTheWindowListStopsAllReading() {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .failure(.accessDenied)
        reader.windowLists[20] = .value([3])
        reader.addStandardWindow(3)
        let observations = Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle, Self.other])
        #expect(observations.allSatisfy { $0.reportedWindowCount == nil })
        #expect(reader.applicationCalls == [10])
    }

    @Test func readingStopsAtTheAppBudget() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1, 2, 3])
        reader.windowLists[20] = .value([4])
        for element in 1...4 { reader.addStandardWindow(element) }
        var clock: TimeInterval = 0
        // Every attribute read takes 0.3 s: one window takes 1.5 s, past a 1 s budget after it.
        reader.onAttributeRead = { clock += 0.3 }
        let observer = Self.observer(reader, budget: 1, now: { clock })
        let observations = observer.observeWindows(bundleIdentifiers: [Self.bundle, Self.other])
        #expect(observations[0].reportedWindowCount == 3)
        #expect(observations[0].windows.count == 1)
        #expect(observations[0].completeSnapshot == .no)
        // The next app has its own budget.
        #expect(observations[1].completeSnapshot == .yes)
    }

    @Test func readsAtMostTheWindowLimit() throws {
        let reader = FakeAccessibilityReader()
        let count = Observer.maximumWindowCount + 6
        reader.windowLists[10] = .value(Array(1...count))
        for element in 1...count { reader.addStandardWindow(element) }
        let observation = try #require(Self.observer(reader).observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.reportedWindowCount == count)
        #expect(observation.windows.count == Observer.maximumWindowCount)
        #expect(observation.completeSnapshot == .no)
        #expect(Set(reader.attributeCalls.map(\.window)).count == Observer.maximumWindowCount)
    }

    // MARK: - Running instances and protection

    @Test(arguments: [
        (Observer.RunningInstances.none, WindowObservations.TriState.no, WindowObservations.TriState.no, false),
        (.none, .unknown, .no, false),
        (.several, .no, .unknown, false),
        (.unknown, .no, .unknown, false),
        (.one(10), .yes, .no, false),
        (.one(10), .unknown, .unknown, true),
        (.one(10), .no, .yes, true),
    ])
    func runningAndProtectionDecideWhatIsRead(
        instances: Observer.RunningInstances,
        protection: WindowObservations.TriState,
        expected: WindowObservations.TriState,
        reads: Bool
    ) throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let observer = Self.observer(reader, instances: [Self.bundle: instances], protection: { _ in protection })
        let observation = try #require(observer.observeWindows(bundleIdentifiers: [Self.bundle]).first)
        #expect(observation.appRunningUnprotected == expected)
        #expect((reader.accessibilityCallCount > 0) == reads)
        if !reads {
            #expect(observation.reportedWindowCount == nil)
            #expect(observation.windows.isEmpty)
        }
    }

    @Test func defaultProtectionIsUnknown() throws {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let observer = Observer(reader: reader, runningInstances: { _ in .one(10) })
        #expect(observer.observeWindows(bundleIdentifiers: [Self.bundle]).first?.appRunningUnprotected == .unknown)
    }

    // MARK: - Error mapping

    @Test(arguments: [
        (AXError.attributeUnsupported, LayoutAccessibilityReadFailure.missing),
        (.noValue, .missing),
        (.invalidUIElement, .elementGone),
        (.cannotComplete, .unresponsive),
        (.apiDisabled, .accessDenied),
        (.failure, .failed),
        (.illegalArgument, .failed),
        (.notImplemented, .failed),
    ])
    func accessibilityErrorsMap(error: AXError, expected: LayoutAccessibilityReadFailure) {
        #expect(LayoutAccessibilityReadFailure(error) == expected)
    }

    // MARK: - With the planner

    /// Visibility, Space, full screen and identity are always unknown, so even a perfectly read
    /// standard window is never eligible: the observer cannot make the planner capture anything.
    @Test func observedWindowsAreNotEligibleWhileVisibilityIsUnknown() {
        let reader = FakeAccessibilityReader()
        reader.windowLists[10] = .value([1])
        reader.addStandardWindow(1)
        let observer = Self.observer(reader)
        let plan = LayoutCapturePlanner.plan(
            groupID: UUID(),
            permission: observer.accessibilityPermission(),
            observations: observer.observeWindows(bundleIdentifiers: [Self.bundle]),
            displays: [LayoutPlannerFixtures.primary]
        )
        #expect(plan == .notCaptured(.noEligibleWindows, apps: [.skipped(.ineligible(.windowVisibleUnknown))]))
    }
}

/// Reads the real system, only when this test process already has Accessibility access. Never asks
/// for access, writes nothing and moves nothing; skipped (not failed) without access.
struct LayoutAccessibilityObserverSystemTests {
    static let trusted = AXIsProcessTrusted()

    @Test(.enabled(if: !trusted, "Runs only without Accessibility access"))
    func withoutAccessTheSystemObserverReportsDenied() {
        let observer = LayoutAccessibilityObserver(protection: { _ in .no })
        #expect(observer.accessibilityPermission() == .denied)
        let observation = observer.observeWindows(bundleIdentifiers: [ProtectedApps.finderBundleIdentifier]).first
        #expect(observation?.reportedWindowCount == nil)
        #expect(observation?.appRunningUnprotected == .unknown)
    }

    @Test(.enabled(if: trusted, "Live read-only Accessibility read; needs access already granted"))
    func liveReadOnlyObservationOfFinder() throws {
        let observer = LayoutAccessibilityObserver(protection: { _ in .no })
        #expect(observer.accessibilityPermission() == .granted)
        let started = ProcessInfo.processInfo.systemUptime
        let observation = try #require(
            observer.observeWindows(bundleIdentifiers: [ProtectedApps.finderBundleIdentifier]).first
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // One messaging timeout for the list plus the app budget, with slack.
        #expect(elapsed < 5)
        if let count = observation.reportedWindowCount {
            #expect(observation.windows.count <= count)
        }
        for window in observation.windows {
            #expect(window.visible == .unknown)
            #expect(window.onCurrentSpace == .unknown)
            #expect(window.fullScreen == .unknown)
            #expect(window.identifiable == .unknown)
        }
    }

    @Test(.enabled(if: trusted, "Live read-only Accessibility read; needs access already granted"))
    func pathAndWebsiteIdentitiesAreNotLookedUp() {
        let observer = LayoutAccessibilityObserver(protection: { _ in .no })
        let observations = observer.observeWindows(bundleIdentifiers: ["/Applications/Safari.app", "https://example.com", ""])
        #expect(observations.allSatisfy { $0.appRunningUnprotected == .unknown && $0.reportedWindowCount == nil })
    }

    @Test(.enabled(if: trusted, "Live read-only Accessibility read; needs access already granted"))
    func appThatIsNotRunningIsNotRead() {
        let observer = LayoutAccessibilityObserver(protection: { _ in .no })
        let observation = observer.observeWindows(bundleIdentifiers: ["com.cybokron.dockgroups.tests.not-running"]).first
        #expect(observation?.appRunningUnprotected == .no)
        #expect(observation?.reportedWindowCount == nil)
    }
}
