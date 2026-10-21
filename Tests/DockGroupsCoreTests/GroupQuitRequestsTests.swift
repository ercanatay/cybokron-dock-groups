import Foundation
import Testing
@testable import DockGroupsCore

/// `GroupQuitRequests`: links ask before quitting a group's apps, other sources don't.
@MainActor
@Suite("Group quit requests")
struct GroupQuitRequestsTests {
    /// Answers every question with `answer` and records it; `whileAsking` runs inside the question.
    final class FakePrompt: QuitConfirmationPrompting {
        var answer: Bool
        var whileAsking: (() -> Void)?
        private(set) var asked: [QuitConfirmation] = []

        init(answer: Bool) {
            self.answer = answer
        }

        func confirm(_ confirmation: QuitConfirmation) -> Bool {
            asked.append(confirmation)
            whileAsking?()
            return answer
        }
    }

    /// Stands in for `GroupTerminator.closeAll`.
    final class FakeTerminator {
        private(set) var calls: [(group: String, mode: QuitMode)] = []

        func closeAll(_ group: DockGroup, mode: QuitMode) -> QuitReport {
            calls.append((group.name, mode))
            return QuitReport(groupName: group.name, mode: mode, quit: group.apps, refused: [])
        }
    }

    private let work = DockGroup(name: "Work", apps: [AppReference(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")])

    private func requests(_ prompt: FakePrompt, _ terminator: FakeTerminator) -> GroupQuitRequests {
        GroupQuitRequests(prompt: prompt, quitApps: terminator.closeAll)
    }

    @Test func aConfirmedLinkQuitsTheApps() {
        let prompt = FakePrompt(answer: true)
        let terminator = FakeTerminator()

        let outcome = requests(prompt, terminator).request(work, mode: .graceful, from: .link)

        #expect(prompt.asked == [QuitConfirmation(groupName: "Work", mode: .graceful)])
        #expect(terminator.calls.map(\.mode) == [.graceful])
        #expect(outcome.report?.quit.map(\.name) == ["TextEdit"])
    }

    @Test func aCancelledLinkQuitsNothing() {
        let prompt = FakePrompt(answer: false)
        let terminator = FakeTerminator()

        #expect(requests(prompt, terminator).request(work, mode: .force, from: .link) == .declined)
        #expect(prompt.asked.count == 1)
        #expect(terminator.calls.isEmpty)
    }

    @Test func aForcingLinkSaysSoAndForces() throws {
        let prompt = FakePrompt(answer: true)
        let terminator = FakeTerminator()

        _ = requests(prompt, terminator).request(work, mode: .force, from: .link)

        let question = try #require(prompt.asked.first)
        #expect(question.mode == .force)
        #expect(question.message.contains("Force quit: the apps end right away, and unsaved changes are lost."))
        #expect(question.confirmButton == "Force Quit Apps")
        #expect(terminator.calls.map(\.mode) == [.force])
    }

    @Test func theQuestionNamesTheGroup() {
        let graceful = QuitConfirmation(groupName: "Çalışma", mode: .graceful)
        #expect(graceful.title == "All apps in “Çalışma” will be quit. Continue?")
        #expect(!graceful.message.contains("Force quit"))
        #expect(graceful.confirmButton == "Quit Apps")
        #expect(graceful.cancelButton == "Cancel")
    }

    @Test(arguments: [QuitRequestSource.userAction, .intent])
    func clicksSiriAndShortcutsDontAsk(source: QuitRequestSource) {
        let prompt = FakePrompt(answer: false)
        let terminator = FakeTerminator()

        let outcome = requests(prompt, terminator).request(work, mode: .force, from: source)

        #expect(prompt.asked.isEmpty)
        #expect(terminator.calls.map(\.mode) == [.force])
        #expect(outcome.report != nil)
    }

    @Test func onlyLinksAskFirst() {
        #expect(QuitRequestSource.allCases.filter(\.asksFirst) == [.link])
    }

    // MARK: - Quit Group in Siri and Shortcuts

    /// The user declining the intent's confirmation.
    struct Declined: Error {}

    @Test(arguments: [QuitMode.graceful, .force])
    func quitGroupAsksInSiriOrShortcutsBeforeQuitting(mode: QuitMode) async throws {
        let prompt = FakePrompt(answer: false)
        let terminator = FakeTerminator()
        var asked: [QuitConfirmation] = []

        let report = try await requests(prompt, terminator).requestFromIntent(work, mode: mode) { confirmation in
            #expect(terminator.calls.isEmpty, "nothing is quit before the user agrees")
            asked.append(confirmation)
        }

        #expect(asked == [QuitConfirmation(groupName: "Work", mode: mode)])
        #expect(terminator.calls.map(\.mode) == [mode])
        #expect(report.quit.map(\.name) == ["TextEdit"])
        #expect(prompt.asked.isEmpty, "not the app's alert as well")
    }

    @Test(arguments: [QuitMode.graceful, .force])
    func declinedQuitGroupQuitsNothing(mode: QuitMode) async {
        let prompt = FakePrompt(answer: true)
        let terminator = FakeTerminator()

        await #expect(throws: Declined.self) {
            try await requests(prompt, terminator).requestFromIntent(work, mode: mode) { _ in throw Declined() }
        }

        #expect(terminator.calls.isEmpty)
        #expect(prompt.asked.isEmpty)
    }

    @Test func quitGroupsQuestionWarnsOfForceQuitting() {
        let graceful = QuitConfirmation(groupName: "Work", mode: .graceful)
        let force = QuitConfirmation(groupName: "Work", mode: .force)

        #expect(graceful.intentDialog == "All apps in “Work” will be quit. Continue?")
        #expect(force.intentDialog == "All apps in “Work” will be quit. Continue?\n\nForce quit: the apps end right away, and unsaved changes are lost.")
        // The user asked: unlike a link's alert, it doesn't blame a link.
        #expect(!force.intentDialog.contains("link"))
        #expect(force.confirmButton == "Force Quit Apps")
        #expect(graceful.confirmButton == "Quit Apps")
    }

    @Test func linksArrivingWhileTheQuestionShowsAreDropped() {
        let prompt = FakePrompt(answer: true)
        let terminator = FakeTerminator()
        let requests = requests(prompt, terminator)
        var nested: [GroupQuitRequests.Outcome] = []
        prompt.whileAsking = {
            nested.append(requests.request(self.work, mode: .force, from: .link))
            // The user's own Close All still works while a link's question shows.
            nested.append(requests.request(self.work, mode: .graceful, from: .userAction))
        }

        let outcome = requests.request(work, mode: .graceful, from: .link)

        #expect(nested.first == .dropped)
        #expect(nested.last?.report != nil)
        #expect(outcome.report != nil)
        #expect(prompt.asked.count == 1)
        #expect(terminator.calls.map(\.mode) == [.graceful, .graceful])
        #expect(!requests.isAsking)
    }

    @Test func theCooldownStartsAgainOnceTheQuestionIsAnswered() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var throttle = CommandThrottle(interval: 5)
        let key = URLCommand.quitGroup("work", .graceful).throttleKey

        let first = throttle.accept(key, at: start)
        // The question stayed up for 8 seconds; a repeat queued meanwhile arrives right after.
        throttle.restartCooldown(for: key, at: start.addingTimeInterval(8))
        let queued = throttle.accept(key, at: start.addingTimeInterval(8.5))
        let soonAfter = throttle.accept(key, at: start.addingTimeInterval(12.9))
        let later = throttle.accept(key, at: start.addingTimeInterval(13.1))

        #expect(first)
        #expect(!queued && !soonAfter)
        #expect(later)
    }
}
