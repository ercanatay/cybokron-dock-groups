import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Switching: the current group")
@MainActor
struct ContextSessionTests {
    private let work = UUID()
    private let design = UUID()
    private let home = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func startingMakesAGroupCurrentAndRemembersThePreviousOne() {
        let session = ContextSession()
        #expect(session.current == nil && session.previous == nil && session.history.isEmpty)

        session.didStart(design, at: start, by: .userAction)
        session.didStart(work, at: start, by: .link)

        #expect(session.current == work)
        #expect(session.previous == design)
        #expect(session.history == [work, design])
        #expect(session.startTrigger == .link)
        #expect(session.startedAt == start)

        // Starting a group again moves it to the front; each group is listed once.
        session.didStart(design, at: start, by: .focus)
        #expect(session.history == [design, work])
        #expect(session.previous == work)
    }

    @Test func theHistoryKeepsEightGroups() {
        let session = ContextSession()
        let ids = (0..<12).map { _ in UUID() }
        for id in ids {
            session.didStart(id, at: start, by: .userAction)
        }
        #expect(session.history == Array(ids.reversed().prefix(ContextSession.maximumHistoryCount)))
    }

    @Test func finishingGoesBackToTheGroupShownAgain() {
        let session = ContextSession()
        session.didStart(home, at: start, by: .userAction)
        session.didStart(design, at: start, by: .userAction)
        session.didStart(work, at: start, by: .userAction)

        session.didFinish(work, showing: design)
        #expect(session.current == design)
        #expect(session.history == [design, home])
        #expect(session.previous == home)
        #expect(session.startedAt == nil, "it was shown again, not started")

        session.didFinish(design, showing: nil)
        #expect(session.current == nil)
        #expect(session.previous == nil)
        #expect(session.history == [home])
    }

    @Test func finishingAnotherGroupLeavesTheCurrentOne() {
        let session = ContextSession()
        session.didStart(design, at: start, by: .userAction)
        session.didStart(work, at: start, by: .userAction)

        session.didFinish(design, showing: nil)

        #expect(session.current == work)
        #expect(session.history == [work])
        #expect(session.startedAt == start)
    }

    @Test func deletedGroupsAreForgotten() {
        let session = ContextSession()
        session.didStart(design, at: start, by: .userAction)
        session.didStart(work, at: start, by: .userAction)

        session.prune(keeping: [work])
        #expect(session.history == [work] && session.current == work)

        session.prune(keeping: [design])
        #expect(session.current == nil && session.history.isEmpty && session.startTrigger == nil)
    }

    @Test func aStartRightAfterTheSameStartIsARepeat() {
        let session = ContextSession()
        session.didStart(work, at: start, by: .focus)

        #expect(session.isRepeatedStart(of: work, at: start))
        #expect(session.isRepeatedStart(of: work, at: start.addingTimeInterval(2.9)))
        #expect(!session.isRepeatedStart(of: work, at: start.addingTimeInterval(ContextSession.repeatInterval)))
        #expect(!session.isRepeatedStart(of: design, at: start), "another group isn't a repeat")
        // A clock that went backwards doesn't hold a Start back.
        #expect(!session.isRepeatedStart(of: work, at: start.addingTimeInterval(-1)))
        // A group that became current by Finish going back to it was never started just now.
        session.didStart(design, at: start, by: .userAction)
        session.didFinish(design, showing: work)
        #expect(!session.isRepeatedStart(of: work, at: start))
    }

    @Test func aNewSessionRemembersNothing() {
        let first = ContextSession()
        first.didStart(work, at: start, by: .userAction)
        #expect(ContextSession().current == nil)
    }
}
