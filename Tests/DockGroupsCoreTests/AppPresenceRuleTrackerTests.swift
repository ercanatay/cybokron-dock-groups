import Foundation
import Testing
@testable import DockGroupsCore

@Suite("App presence rule tracker")
struct AppPresenceRuleTrackerTests {
    private func makeRule(_ id: UUID = UUID(), identifier: TriggerApplicationIdentifier? = nil, edge: TriggerEdge) -> AppPresenceRuleTracker.Rule {
        AppPresenceRuleTracker.Rule(
            id: id,
            identifier: identifier ?? TriggerApplicationIdentifier("com.example.app")!,
            edge: edge
        )
    }

    @Test func initialBaselineNoEmission() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        let rule = makeRule(id, edge: .starts)
        #expect(tracker.configure([rule]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 1]) == [])
    }

    @Test func openCloseCycleStartsRule() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 1]) == [id])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 0]) == [])
    }

    @Test func openCloseCycleEndsRule() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .ends)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 0]) == [id])
    }

    @Test func oneToTwoToOneNoEmission() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 2]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 1]) == [])
    }

    @Test func sameIdentifierMultipleRulesAreIndependent() {
        var tracker = AppPresenceRuleTracker()
        let id1 = UUID()
        let id2 = UUID()
        #expect(tracker.configure([
            makeRule(id1, edge: .starts),
            makeRule(id2, edge: .ends),
        ]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 0]) == [id2])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 1]) == [id1])
    }

    @Test func missingCountClearsBaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 2]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: [:]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 4, counts: ["com.example.app": 1]) == [id])
    }

    @Test func negativeCountClearsBaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 3]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": -1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 4, counts: ["com.example.app": 1]) == [id])
    }

    @Test func configureRemovalForgetsBaseline() {
        var tracker = AppPresenceRuleTracker()
        let id1 = UUID()
        let id2 = UUID()
        #expect(tracker.configure([makeRule(id1, edge: .starts), makeRule(id2, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1, "other.app": 1]) == [])
        #expect(tracker.configure([makeRule(id1, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.app": 1]) == [id1])
    }

    @Test func configureReaddResetsThenSetsBaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 2]) == [])
        #expect(tracker.configure([]) == true)
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 3]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 3, counts: ["com.example.app": 1]) == [id])
    }

    @Test func configureUnchangedKeepsBaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 1]) == [id])
    }

    @Test func configureChangeIdentifierResetsRule() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        let idA = TriggerApplicationIdentifier("com.a.app")!
        let idB = TriggerApplicationIdentifier("com.b.app")!
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: idA, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.a.app": 1]) == [])
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: idB, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.b.app": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.b.app": 1]) == [id])
    }

    @Test func configureChangeRawSpellingResetsRule() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        let raw1 = TriggerApplicationIdentifier("COM.Example.App")!
        let raw2 = TriggerApplicationIdentifier("com.example.app")!
        #expect(raw1.rawValue != raw2.rawValue)
        #expect(raw1.matchKey == raw2.matchKey)
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: raw1, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: raw2, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.app": 1]) == [id])
    }

    @Test func duplicateRuleIdsFailClosed() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([
            makeRule(id, edge: .starts),
            makeRule(id, edge: .ends),
        ]) == false)
        #expect(tracker.configure([makeRule(UUID(), edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
    }

    @Test func over100RulesFailClosed() {
        var tracker = AppPresenceRuleTracker()
        let rules = (1...101).map { AppPresenceRuleTracker.Rule(id: UUID(), identifier: TriggerApplicationIdentifier("com.\($0).app")!, edge: .starts) }
        #expect(tracker.configure(rules) == false)
        #expect(tracker.configure([]) == true)
    }

    @Test func sourceGenerationStopRestartStale() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(10) == true)
        #expect(tracker.observe(generation: 10, sequence: 1, counts: ["com.example.app": 1]) == [])
        tracker.stop()
        #expect(tracker.observe(generation: 10, sequence: 2, counts: ["com.example.app": 0]) == [])
        #expect(tracker.beginGeneration(5) == false)
        #expect(tracker.beginGeneration(10) == false)
        #expect(tracker.beginGeneration(11) == true)
        #expect(tracker.observe(generation: 11, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 11, sequence: 2, counts: ["com.example.app": 1]) == [id])
        #expect(tracker.observe(generation: 10, sequence: 2, counts: ["com.example.app": 0]) == [])
    }

    @Test func reorderedDuplicateSequenceRebaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 5, counts: ["com.example.app": 2]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 0]) == [])
    }

    @Test func skippedSequenceRebaseline() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 4, counts: ["com.example.app": 0]) == [])
    }

    @Test func skippedSequenceRebaselineBeforeProcessing() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 0]) == [])
    }

    @Test func uint64MaxBoundarySequence() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(UInt64.max) == true)
        #expect(tracker.observe(generation: UInt64.max, sequence: UInt64.max - 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: UInt64.max, sequence: UInt64.max, counts: ["com.example.app": 1]) == [id])
    }

    @Test func firstSequenceAnyValue() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(5) == true)
        #expect(tracker.observe(generation: 5, sequence: 100, counts: ["com.example.app": 2]) == [])
    }

    @Test func beginGenerationFirstCanBeAny() {
        var tracker = AppPresenceRuleTracker()
        #expect(tracker.beginGeneration(0) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.beginGeneration(0) == false)
    }

    @Test func observeWrongGenerationRejected() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 1]) == [])
    }

    @Test func observeRepeatedSequenceRejected() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == [])
    }

    @Test func observeLowerSequenceRejected() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 2]) == [])
    }

    @Test func emitOnlyUuidNeverNameOrValue() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == [])
        let emitted = tracker.observe(generation: 1, sequence: 2, counts: ["com.example.app": 1])
        #expect(emitted == [id])
    }

    @Test func configurationChangeRejectsQueuedOldGeneration() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        let original = makeRule(id, identifier: TriggerApplicationIdentifier("com.example.old"), edge: .starts)
        let changed = makeRule(id, identifier: TriggerApplicationIdentifier("com.example.new"), edge: .starts)
        #expect(tracker.configure([original]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.old": 0]) == [])
        #expect(tracker.configure([changed]) == true)
        #expect(tracker.observe(generation: 1, sequence: 2, counts: ["com.example.new": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.new": 1]) == [])
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.new": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.new": 1]) == [id])
    }

    @Test func unknownThenKnownRebaselinesWithoutFiring() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 2, counts: [:]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 4, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 5, counts: ["com.example.app": 1]) == [id])
    }

    @Test func configureChangeEdgeResetsRule() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: TriggerApplicationIdentifier("com.example.app")!, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.configure([AppPresenceRuleTracker.Rule(id: id, identifier: TriggerApplicationIdentifier("com.example.app")!, edge: .ends)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.app": 0]) == [id])
    }

    @Test func configureReorderingResetsAndRequiresNewGeneration() {
        var tracker = AppPresenceRuleTracker()
        let idA = UUID()
        let idB = UUID()
        #expect(tracker.configure([makeRule(idA, edge: .starts), makeRule(idB, edge: .ends)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.configure([makeRule(idB, edge: .ends), makeRule(idA, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(2) == true)
        #expect(tracker.observe(generation: 2, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 2, sequence: 2, counts: ["com.example.app": 1]) == [idA])
    }

    @Test func staleTokenAfterStopRejectedAndAllowsStrictlyGreater() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(10) == true)
        tracker.stop()
        #expect(tracker.beginGeneration(5) == false)
        #expect(tracker.beginGeneration(10) == false)
        #expect(tracker.beginGeneration(11) == true)
        #expect(tracker.observe(generation: 11, sequence: 1, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 11, sequence: 2, counts: ["com.example.app": 1]) == [id])
    }

    @Test func skipSequenceRebaselineBeforeProcessingCorrected() {
        var tracker = AppPresenceRuleTracker()
        let id = UUID()
        #expect(tracker.configure([makeRule(id, edge: .starts)]) == true)
        #expect(tracker.beginGeneration(1) == true)
        #expect(tracker.observe(generation: 1, sequence: 1, counts: ["com.example.app": 1]) == [])
        #expect(tracker.observe(generation: 1, sequence: 3, counts: ["com.example.app": 0]) == [])
        #expect(tracker.observe(generation: 1, sequence: 4, counts: ["com.example.app": 1]) == [id])
    }
}
