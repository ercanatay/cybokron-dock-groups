import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Following Accessibility access")
@MainActor
struct AccessibilityTrustTrackerTests {
    /// Stands in for `AXIsProcessTrusted()`, counting the reads.
    private final class Access {
        var granted: Bool
        private(set) var reads = 0

        init(granted: Bool) {
            self.granted = granted
        }

        func read() -> Bool {
            reads += 1
            return granted
        }
    }

    private func tracker(_ access: Access) -> (AccessibilityTrustTracker, Recorder) {
        let tracker = AccessibilityTrustTracker(check: access.read)
        let recorder = Recorder()
        tracker.onChange = { recorder.changes.append($0) }
        tracker.onPollingChange = { recorder.polling.append($0) }
        return (tracker, recorder)
    }

    private final class Recorder {
        var changes: [Bool] = []
        var polling: [Bool] = []
    }

    @Test func startsWithTheCurrentAccess() {
        #expect(AccessibilityTrustTracker(check: { true }).isTrusted)
        #expect(!AccessibilityTrustTracker(check: { false }).isTrusted)
    }

    @Test func pollsOnlyWhileAccessIsMissingAndWatched() {
        let access = Access(granted: false)
        let (tracker, recorder) = tracker(access)
        #expect(!tracker.isPolling, "nobody watches yet")

        tracker.beginObserving()
        #expect(tracker.isPolling)
        tracker.endObserving()
        #expect(!tracker.isPolling)
        #expect(recorder.polling == [true, false])
    }

    @Test func appearingReadsAccessAtOnce() {
        let access = Access(granted: false)
        let (tracker, _) = tracker(access)
        access.granted = true
        let readsBefore = access.reads

        tracker.beginObserving()

        #expect(access.reads == readsBefore + 1)
        #expect(tracker.isTrusted)
        #expect(!tracker.isPolling, "already granted: nothing to poll for")
    }

    @Test func grantingTurnsTheStatusGreenAndStopsPolling() {
        let access = Access(granted: false)
        let (tracker, recorder) = tracker(access)
        tracker.beginObserving()

        #expect(!tracker.refresh(), "a poll tick without a change")
        access.granted = true
        #expect(tracker.refresh(), "the next tick (or the app becoming active) sees the grant")

        #expect(tracker.isTrusted)
        #expect(!tracker.isPolling)
        #expect(recorder.changes == [true])
        #expect(recorder.polling == [true, false])
    }

    @Test func revokingResumesPolling() {
        let access = Access(granted: true)
        let (tracker, recorder) = tracker(access)
        tracker.beginObserving()
        #expect(!tracker.isPolling)

        access.granted = false
        tracker.refresh()

        #expect(!tracker.isTrusted)
        #expect(tracker.isPolling)
        #expect(recorder.changes == [false])
    }

    @Test func pollingLastsUntilTheLastObserverLeaves() {
        let access = Access(granted: false)
        let (tracker, recorder) = tracker(access)
        tracker.beginObserving()
        tracker.beginObserving()

        tracker.endObserving()
        #expect(tracker.isPolling)
        tracker.endObserving()
        tracker.endObserving()  // unbalanced: ignored
        #expect(!tracker.isPolling)
        tracker.beginObserving()
        #expect(tracker.isPolling)
        #expect(recorder.polling == [true, false, true])
    }

    @Test func refreshNeverCaches() {
        let access = Access(granted: false)
        let (tracker, _) = tracker(access)
        let readsBefore = access.reads

        for _ in 0..<3 {
            tracker.refresh()
        }

        #expect(access.reads == readsBefore + 3)
    }

    @Test func pollIntervalIsShort() {
        #expect((1...2).contains(AccessibilityTrustTracker.pollInterval))
    }
}
