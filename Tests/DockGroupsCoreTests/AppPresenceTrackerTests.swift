import Foundation
import Testing
@testable import DockGroupsCore

@Suite("App presence tracker")
struct AppPresenceTrackerTests {
    @Test func nonASCIIIdentityCannotMatchASCIIApplicationKey() {
        let result = ApplicationSnapshotCounter.counts(keys: ["com.exampke.app"], identifiers: ["com.exampKe.app"])
        #expect(result["com.exampke.app"] == 0)
    }
    @Test func snapshotCountsEmptyIdentifierReturnsUnknown() {
        let result = ApplicationSnapshotCounter.counts(keys: ["com.example.app"], identifiers: ["com.example.app", ""])
        #expect(result.isEmpty)
    }
    @Test func initialValidCountSetsBaselineWithNoEdge() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
    }

    @Test func zeroToPositiveProducesOpened() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 0, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == .opened)
    }

    @Test func positiveToZeroProducesClosed() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 2, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 0, generation: tracker.generation) == .closed)
    }

    @Test func oneToTwoProducesNone() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 2, generation: tracker.generation) == nil)
    }

    @Test func twoToOneProducesNone() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 2, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
    }

    @Test func duplicateCountProducesNone() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 4, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 4, generation: tracker.generation) == nil)
    }

    @Test func unknownCountInvalidatesBaseline() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: nil, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 0, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == .opened)
    }

    @Test func negativeCountInvalidatesBaseline() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 2, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: -3, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 0, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == .opened)
    }

    @Test func invalidateClearsBaselineWithoutChangingGeneration() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 3, generation: tracker.generation) == nil)
        tracker.invalidate()
        #expect(tracker.observe(count: 3, generation: tracker.generation) == nil)
        #expect(tracker.generation == 1)
    }

    @Test func beginGenerationReturnsNewGenerationAndInvalidatesBaseline() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 5, generation: tracker.generation) == nil)
        let next = tracker.beginGeneration()
        #expect(next == 2)
        #expect(tracker.generation == 2)
        #expect(tracker.observe(count: 5, generation: tracker.generation) == nil)
    }

    @Test func staleObservationDoesNotAlterBaseline() {
        var tracker = AppPresenceTracker()
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
        let oldGen = tracker.generation
        _ = tracker.beginGeneration()
        #expect(tracker.observe(count: 0, generation: oldGen) == nil)
        #expect(tracker.observe(count: 0, generation: tracker.generation) == nil)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == .opened)
    }

    @Test func beginGenerationOverflowReturnsNilWithoutWrapping() {
        var tracker = AppPresenceTracker(generation: UInt64.max - 1)
        #expect(tracker.beginGeneration() == UInt64.max)
        #expect(tracker.generation == UInt64.max)
        #expect(tracker.beginGeneration() == nil)
        #expect(tracker.generation == UInt64.max)
        #expect(tracker.observe(count: 1, generation: tracker.generation) == nil)
    }

    @Test func exhaustedGenerationRejectsAllCallbacks() {
        var tracker = AppPresenceTracker(generation: UInt64.max - 1)
        let generation = tracker.beginGeneration()!
        #expect(tracker.observe(count: 0, generation: generation) == nil)
        #expect(tracker.beginGeneration() == nil)
        #expect(tracker.observe(count: 1, generation: generation) == nil)
        #expect(tracker.observe(count: 0, generation: generation) == nil)
    }

    @Test func snapshotCountsNilAnywhereReturnsEmpty() {
        #expect(ApplicationSnapshotCounter.counts(keys: ["a"], identifiers: ["b", nil, "c"]) == [:])
    }

    @Test func snapshotCountsEmptyKeysReturnsEmpty() {
        #expect(ApplicationSnapshotCounter.counts(keys: [], identifiers: ["a", "b"]) == [:])
    }

    @Test func snapshotCountsCaseInsensitiveDuplicates() {
        let result = ApplicationSnapshotCounter.counts(keys: ["A"], identifiers: ["a", "A", "a", "A"])
        #expect(result == ["a": 4])
    }

    @Test func snapshotCountsUnrelatedIdReturnsZero() {
        let result = ApplicationSnapshotCounter.counts(keys: ["x"], identifiers: ["y", "z"])
        #expect(result == ["x": 0])
    }

    @Test func snapshotCountsNoSelectedIdsReturnsZero() {
        let result = ApplicationSnapshotCounter.counts(keys: ["x", "y"], identifiers: [])
        #expect(result == ["x": 0, "y": 0])
    }
}
