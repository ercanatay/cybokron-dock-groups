import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Instance handoff")
struct InstanceHandoffTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func copy(_ pid: Int32, launchedAfter seconds: TimeInterval?) -> InstanceHandoff.Instance {
        InstanceHandoff.Instance(processIdentifier: pid, launchDate: seconds.map { start.addingTimeInterval($0) })
    }

    @Test func aloneTheCopyKeepsRunning() {
        #expect(InstanceHandoff.primary(among: [], current: copy(10, launchedAfter: 0)) == nil)
        // The list of running copies may include the current one.
        #expect(InstanceHandoff.primary(among: [copy(10, launchedAfter: 0)], current: copy(10, launchedAfter: 0)) == nil)
    }

    @Test func laterCopyHandsOverToTheOlderOne() {
        let older = copy(50, launchedAfter: 0)
        let later = copy(20, launchedAfter: 5)
        #expect(InstanceHandoff.primary(among: [older], current: later) == older)
        #expect(InstanceHandoff.primary(among: [later], current: older) == nil)
    }

    @Test func handsOverToTheOldestOfSeveralCopies() {
        let oldest = copy(30, launchedAfter: 0)
        let middle = copy(40, launchedAfter: 2)
        let current = copy(50, launchedAfter: 4)
        #expect(InstanceHandoff.primary(among: [middle, oldest], current: current) == oldest)
        #expect(InstanceHandoff.primary(among: [current, oldest], current: middle) == oldest)
        #expect(InstanceHandoff.primary(among: [middle, current], current: oldest) == nil)
    }

    @Test func sameLaunchDateGoesByProcessIdentifier() {
        let first = copy(30, launchedAfter: 1)
        let second = copy(31, launchedAfter: 1)
        #expect(InstanceHandoff.primary(among: [first], current: second) == first)
        #expect(InstanceHandoff.primary(among: [second], current: first) == nil)
    }

    @Test func copyWithoutLaunchDateCountsAsTheOldest() {
        let undated = copy(90, launchedAfter: nil)
        let dated = copy(10, launchedAfter: 0)
        #expect(InstanceHandoff.primary(among: [undated], current: dated) == undated)
        #expect(InstanceHandoff.primary(among: [dated], current: undated) == nil)
        let otherUndated = copy(91, launchedAfter: nil)
        #expect(InstanceHandoff.primary(among: [undated], current: otherUndated) == undated)
    }

    /// Copies starting together each decide on their own: exactly one of them keeps running, and
    /// every other one hands over to that one.
    @Test func exactlyOneOfSimultaneousCopiesKeepsRunning() {
        let copies = [
            copy(70, launchedAfter: 1), copy(71, launchedAfter: 0), copy(72, launchedAfter: nil),
            copy(73, launchedAfter: 0), copy(74, launchedAfter: nil),
        ]
        let decisions = copies.map { current in
            InstanceHandoff.primary(among: copies, current: current)
        }
        let staying = zip(copies, decisions).filter { $0.1 == nil }.map(\.0)
        #expect(staying == [copy(72, launchedAfter: nil)])
        #expect(decisions.compactMap { $0 }.allSatisfy { $0 == staying.first })
    }
}
