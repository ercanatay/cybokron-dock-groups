import Foundation
import LocalAuthentication
import Testing
@testable import DockGroupsCore

/// Answers every authentication with `result`, recording the reasons; `whileAsking` runs inside
/// the prompt. With `holds`, each prompt waits until `release()`.
@MainActor
final class FakeAuthenticator: ApplicationAuthenticating {
    var result: QuitAuthenticationResult
    var whileAsking: (() -> Void)?
    var holds = false
    private(set) var reasons: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ result: QuitAuthenticationResult = .authenticated) {
        self.result = result
    }

    func authenticate(reason: String) async -> QuitAuthenticationResult {
        reasons.append(reason)
        whileAsking?()
        if holds {
            await withCheckedContinuation { held.append($0) }
        }
        return result
    }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

/// "Ask for authentication before quitting apps" (`QuitAuthentication`): off, nothing changes;
/// on, only the app's own clicks and keyboard shortcuts can quit, after authenticating, and every
/// failure — or a request that can't ask — quits nothing.
@MainActor
@Suite("Quit authentication")
struct QuitAuthenticationTests {
    final class Switch {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    /// Stands in for `GroupTerminator.closeAll`.
    final class FakeTerminator {
        private(set) var calls: [QuitMode] = []

        func closeAll(_ group: DockGroup, mode: QuitMode) -> QuitReport {
            calls.append(mode)
            return QuitReport(groupName: group.name, mode: mode, quit: group.apps, refused: [])
        }
    }

    struct Declined: Error {}

    private let work = DockGroup(name: "Work", apps: [AppReference(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")])

    private func gate(_ isOn: Bool, _ authenticator: FakeAuthenticator?) -> QuitAuthentication {
        let setting = Switch(isOn)
        return QuitAuthentication(isRequired: { setting.isOn }, authenticator: authenticator)
    }

    private func requests(
        on isOn: Bool,
        _ authenticator: FakeAuthenticator,
        prompt: FakeQuitPrompt? = nil,
        _ terminator: FakeTerminator
    ) -> GroupQuitRequests {
        GroupQuitRequests(prompt: prompt ?? FakeQuitPrompt(answer: true), authentication: gate(isOn, authenticator), quitApps: terminator.closeAll)
    }

    // MARK: - The setting

    @Test func theSettingIsOffByDefaultAndSavedOnlyWhileOn() throws {
        #expect(PopupPreferences().asksForAuthenticationBeforeQuitting == false)

        let off = String(decoding: try JSONEncoder().encode(PopupPreferences()), as: UTF8.self)
        #expect(!off.contains("authenticateBeforeQuitting"), "a file that never had it is written as before")

        let on = try JSONEncoder().encode(PopupPreferences(asksForAuthenticationBeforeQuitting: true))
        #expect(String(decoding: on, as: UTF8.self).contains("\"authenticateBeforeQuitting\":true"))
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: on).asksForAuthenticationBeforeQuitting)

        // Another version's file, without the key or with something else there, loads as off.
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: Data("{}".utf8)).asksForAuthenticationBeforeQuitting == false)
        #expect(try JSONDecoder().decode(PopupPreferences.self, from: Data(#"{"authenticateBeforeQuitting":"yes"}"#.utf8)).asksForAuthenticationBeforeQuitting == false)
    }

    @Test func aStandaloneGroupsAppGetsTheSetting() {
        let configuration = AgentConfiguration(group: work, preferences: PopupPreferences(asksForAuthenticationBeforeQuitting: true))
        #expect(configuration.preferences.asksForAuthenticationBeforeQuitting)
    }

    // MARK: - Off: as before

    @Test func offNothingAsksForAuthentication() async throws {
        let authenticator = FakeAuthenticator(.refused(.failed))
        let terminator = FakeTerminator()
        let requests = requests(on: false, authenticator, terminator)

        #expect(!requests.requiresAuthentication)
        #expect(await requests.quit(work, mode: .graceful, from: .userAction).report != nil)
        #expect(await requests.quit(work, mode: .force, from: .userAction).report != nil)
        #expect(requests.request(work, mode: .graceful, from: .link).report != nil)
        _ = try await requests.requestFromIntent(work, mode: .graceful) { _ in }

        #expect(authenticator.reasons.isEmpty)
        #expect(terminator.calls == [.graceful, .force, .graceful, .graceful])
    }

    // MARK: - On: Close All and Force Quit

    @Test(arguments: [QuitMode.graceful, .force])
    func onAClickQuitsOnceAuthenticated(mode: QuitMode) async {
        let authenticator = FakeAuthenticator(.authenticated)
        let terminator = FakeTerminator()

        let outcome = await requests(on: true, authenticator, terminator).quit(work, mode: mode, from: .userAction)

        #expect(authenticator.reasons == ["quit apps"])
        #expect(terminator.calls == [mode])
        #expect(outcome.report?.quit.map(\.name) == ["TextEdit"])
    }

    @Test(arguments: [QuitAuthenticationFailure.cancelled, .failed, .unavailable])
    func onAFailedAuthenticationQuitsNothingAndSaysSo(failure: QuitAuthenticationFailure) async {
        let authenticator = FakeAuthenticator(.refused(failure))
        let terminator = FakeTerminator()

        let outcome = await requests(on: true, authenticator, terminator).quit(work, mode: .force, from: .userAction)

        #expect(outcome == .notAuthenticated(failure))
        #expect(terminator.calls.isEmpty)
        #expect(failure.message(appName: "Cybokron Dock Groups") == "Nothing was quit: authentication was cancelled, failed or isn't available on this Mac.")
    }

    /// LocalAuthentication's errors fail closed: no Touch ID or no password set quits nothing.
    @Test(arguments: [
        (LAError.Code.userCancel.rawValue, QuitAuthenticationFailure.cancelled),
        (LAError.Code.systemCancel.rawValue, .cancelled),
        (LAError.Code.appCancel.rawValue, .cancelled),
        (LAError.Code.userFallback.rawValue, .cancelled),
        (LAError.Code.authenticationFailed.rawValue, .failed),
        (LAError.Code.biometryNotAvailable.rawValue, .unavailable),
        (LAError.Code.biometryNotEnrolled.rawValue, .unavailable),
        (LAError.Code.biometryLockout.rawValue, .unavailable),
        (LAError.Code.passcodeNotSet.rawValue, .unavailable),
        (LAError.Code.notInteractive.rawValue, .unavailable),
        (LAError.Code.invalidContext.rawValue, .unavailable),
    ])
    func localAuthenticationErrorsQuitNothing(code: Int, failure: QuitAuthenticationFailure) async {
        #expect(DeviceOwnerAuthenticator.failure(forErrorCode: code) == failure)

        let authenticator = FakeAuthenticator(.refused(DeviceOwnerAuthenticator.failure(forErrorCode: code)))
        let terminator = FakeTerminator()
        let outcome = await requests(on: true, authenticator, terminator).quit(work, mode: .graceful, from: .userAction)
        #expect(outcome == .notAuthenticated(failure))
        #expect(terminator.calls.isEmpty)
    }

    @Test func unknownOrMissingErrorsFailClosed() {
        #expect(DeviceOwnerAuthenticator.failure(forErrorCode: nil) == .failed)
        #expect([.failed, .unavailable].contains(DeviceOwnerAuthenticator.failure(forErrorCode: -99_999)))
    }

    @Test func withoutAnAuthenticatorNothingIsQuit() async {
        let terminator = FakeTerminator()
        let requests = GroupQuitRequests(
            prompt: FakeQuitPrompt(answer: true),
            authentication: gate(true, nil),
            quitApps: terminator.closeAll
        )
        #expect(await requests.quit(work, mode: .graceful, from: .userAction) == .notAuthenticated(.unavailable))
        // Close All that can't wait can't ask either.
        #expect(requests.request(work, mode: .graceful, from: .userAction) == .notAuthenticated(.unavailable))
        #expect(terminator.calls.isEmpty)
    }

    // MARK: - On: requests that can't ask

    /// A link (the command line sends links too) can't ask: refused before its question, so the
    /// user isn't asked something that can't happen.
    @Test func onALinkQuitsNothingAndAsksNothing() async {
        let authenticator = FakeAuthenticator(.authenticated)
        let prompt = FakeQuitPrompt(answer: true)
        var questions = 0
        prompt.whileAsking = { questions += 1 }
        let terminator = FakeTerminator()
        let requests = requests(on: true, authenticator, prompt: prompt, terminator)

        #expect(requests.request(work, mode: .force, from: .link) == .notAuthenticated(.notInteractive))
        #expect(await requests.quit(work, mode: .graceful, from: .link) == .notAuthenticated(.notInteractive))

        #expect(questions == 0)
        #expect(authenticator.reasons.isEmpty)
        #expect(terminator.calls.isEmpty)
        let message = QuitAuthenticationFailure.notInteractive.message(appName: "Cybokron Dock Groups")
        #expect(message.hasPrefix("Nothing was quit: “Ask for authentication before quitting apps” is on"))
        #expect(message.hasSuffix("Quit the apps from Cybokron Dock Groups itself instead."))
    }

    @Test func onSiriAndShortcutsQuitNothingAndAskNothing() async {
        let authenticator = FakeAuthenticator(.authenticated)
        let terminator = FakeTerminator()
        var asked = false

        await #expect(throws: QuitAuthenticationRefusal(.notInteractive)) {
            _ = try await requests(on: true, authenticator, terminator).requestFromIntent(work, mode: .force) { _ in asked = true }
        }
        #expect(!asked, "Siri's question isn't asked")
        #expect(authenticator.reasons.isEmpty)
        #expect(terminator.calls.isEmpty)
    }

    /// A standalone group's own app has no authenticator and doesn't count as interactive.
    @Test func aStandaloneGroupsAppIsRefusedWithoutAsking() {
        #expect(gate(true, nil).refusalWithoutAsking(interactive: false) == .notInteractive)
        #expect(gate(false, nil).refusalWithoutAsking(interactive: false) == nil)
        #expect(gate(true, nil).refusalWithoutAsking(interactive: true) == nil, "goes on to authenticate")
    }

    @Test func onlyTheAppsOwnClicksAndKeyboardShortcutsCanAsk() {
        #expect(QuitRequestSource.allCases.filter(\.canAuthenticate) == [.userAction])
        #expect(TransitionTrigger.allCases.filter(\.canAuthenticate) == [.userAction, .shortcut])
    }

    // MARK: - One prompt at a time

    @Test func aSecondRequestWhileAPromptShowsIsDropped() async {
        let authenticator = FakeAuthenticator(.authenticated)
        authenticator.holds = true
        let terminator = FakeTerminator()
        let requests = requests(on: true, authenticator, terminator)

        let first = Task { await requests.quit(work, mode: .graceful, from: .userAction) }
        while authenticator.reasons.isEmpty { await Task.yield() }

        #expect(requests.isAsking)
        #expect(await requests.quit(work, mode: .force, from: .userAction) == .dropped)
        authenticator.release()
        #expect(await first.value.report != nil)
        #expect(terminator.calls == [.graceful])
        #expect(!requests.isAsking)
    }

    @Test func theGateItselfAsksOnceAtATime() async {
        let authenticator = FakeAuthenticator(.authenticated)
        authenticator.holds = true
        let gate = gate(true, authenticator)

        let first = Task { await gate.authenticate() }
        while !gate.isAuthenticating { await Task.yield() }
        #expect(await gate.authenticate() == nil)
        authenticator.release()
        #expect(await first.value == .authenticated)
        #expect(authenticator.reasons.count == 1)
    }

    // MARK: - Start and Finish

    private static let design = DockGroup.of("Design", ["com.figma.Desktop", "com.bohemiancoding.sketch3"])
    private static func coding(_ switching: GroupSwitching = GroupSwitching(onStart: .quitPreviousGroup)) -> DockGroup {
        .of("Coding", ["com.apple.dt.Xcode"], switching: switching)
    }

    /// Design (current, its apps running), then Coding with `switching`, with the setting `isOn`.
    private func rig(
        on isOn: Bool,
        _ authenticator: FakeAuthenticator,
        _ switching: GroupSwitching = GroupSwitching(onStart: .quitPreviousGroup),
        answer: TransitionConfirmation.Answer = .quit
    ) async throws -> (SwitchingRig, DockGroup) {
        let coding = Self.coding(switching)
        let rig = SwitchingRig(groups: [Self.design, coding], answer: answer, authentication: gate(isOn, authenticator))
        rig.apps.run("com.figma.Desktop", name: "Figma")
        rig.apps.run("com.bohemiancoding.sketch3", name: "Sketch")
        // Starting Design hides nothing and quits nothing: no authentication.
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
        #expect(authenticator.reasons.isEmpty)
        return (rig, coding)
    }

    @Test func offStartQuitsWithoutAuthentication() async throws {
        let authenticator = FakeAuthenticator(.refused(.failed))
        let (rig, coding) = try await rig(on: false, authenticator)

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        #expect(report.outcome == .done)
        #expect(rig.log.events(withPrefix: "quit:").count == 2)
        #expect(authenticator.reasons.isEmpty)
    }

    @Test func onStartQuitsOnceAuthenticated() async throws {
        let authenticator = FakeAuthenticator(.authenticated)
        let (rig, coding) = try await rig(on: true, authenticator)
        // Nothing is quit or opened before the user authenticated.
        authenticator.whileAsking = {
            #expect(rig.log.events(withPrefix: "quit:").isEmpty)
            #expect(!rig.workspace.launched.contains("com.apple.dt.Xcode"))
        }

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        #expect(authenticator.reasons == ["quit apps"])
        #expect(report.outcome == .done)
        #expect(rig.log.events(withPrefix: "quit:") == ["com.figma.desktop", "com.bohemiancoding.sketch3"])
        #expect(rig.session.current == coding.id)
    }

    @Test(arguments: [QuitAuthenticationFailure.cancelled, .failed, .unavailable])
    func onAFailedAuthenticationDoesNothingAtAll(failure: QuitAuthenticationFailure) async throws {
        let authenticator = FakeAuthenticator(.refused(failure))
        let (rig, coding) = try await rig(on: true, authenticator)
        let before = rig.log.events.count

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)

        #expect(report.outcome == .notAuthenticated(failure))
        #expect(rig.log.events.count == before, "nothing hidden, quit or opened")
        #expect(rig.session.current == Self.design.id)
        #expect(report.summary == "Didn't switch to “Coding”: it would quit apps, and authentication didn't succeed. Nothing was quit.")
    }

    @Test func onFinishThatQuitsAsksToo() async throws {
        let authenticator = FakeAuthenticator(.refused(.cancelled))
        let rig = SwitchingRig(groups: [Self.coding(GroupSwitching(onFinish: .quitApps))], authentication: gate(true, authenticator))
        rig.apps.run("com.apple.dt.Xcode", name: "Xcode")
        let coding = try #require(rig.store.groups.first)

        let report = try await rig.switcher.finish(coding.id, trigger: .userAction)

        #expect(authenticator.reasons.count == 1)
        #expect(report.outcome == .notAuthenticated(.cancelled))
        #expect(rig.log.events.isEmpty)

        authenticator.result = .authenticated
        #expect(try await rig.switcher.finish(coding.id, trigger: .userAction).outcome == .done)
        #expect(rig.log.events(withPrefix: "quit:") == ["com.apple.dt.xcode"])
    }

    @Test func onHidingNeverAsks() async throws {
        let authenticator = FakeAuthenticator(.refused(.failed))
        let (rig, coding) = try await rig(on: true, authenticator, GroupSwitching())

        let report = try await rig.switcher.start(coding.id, trigger: .userAction)
        _ = try await rig.switcher.finish(coding.id, trigger: .shortcut)
        _ = rig.terminator.hideAll(Self.design)

        #expect(report.outcome == .done)
        // Start hid Design's two apps, Finish showed them again, Hide All hid them again.
        #expect(rig.log.events(withPrefix: "hide:").count == 4)
        #expect(rig.log.events(withPrefix: "unhide:").count == 2)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "launch:").contains("com.apple.dt.Xcode"), "opening never asks")
        #expect(authenticator.reasons.isEmpty)
    }

    /// A keyboard shortcut asks with the app's alert first, then for authentication: the user who
    /// cancels or hides instead is never asked to authenticate.
    @Test func onTheQuestionComesFirstThenAuthentication() async throws {
        let authenticator = FakeAuthenticator(.authenticated)
        let (rig, coding) = try await rig(on: true, authenticator)
        var questionsWhenAuthenticating: Int?
        authenticator.whileAsking = { questionsWhenAuthenticating = rig.transitionPrompt.asked.count }

        let report = try await rig.switcher.start(coding.id, trigger: .shortcut)

        #expect(questionsWhenAuthenticating == 1)
        #expect(report.outcome == .done)
        #expect(rig.log.events(withPrefix: "quit:").count == 2)
    }

    @Test(arguments: [TransitionConfirmation.Answer.cancel, .hideInstead])
    func onNoAuthenticationWhenTheQuestionDoesntQuit(answer: TransitionConfirmation.Answer) async throws {
        let authenticator = FakeAuthenticator(.refused(.failed))
        let (rig, coding) = try await rig(on: true, authenticator, answer: answer)

        let report = try await rig.switcher.start(coding.id, trigger: .shortcut)

        #expect(rig.transitionPrompt.asked.count == 1)
        #expect(authenticator.reasons.isEmpty)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(report.outcome == (answer == .cancel ? .declined : .done))
    }

    @Test func onTheQuestionAnsweredThenAFailedAuthenticationQuitsNothing() async throws {
        let authenticator = FakeAuthenticator(.refused(.cancelled))
        let (rig, coding) = try await rig(on: true, authenticator)

        let report = try await rig.switcher.start(coding.id, trigger: .shortcut)

        #expect(rig.transitionPrompt.asked.count == 1)
        #expect(authenticator.reasons.count == 1)
        #expect(report.outcome == .notAuthenticated(.cancelled))
        #expect(rig.log.events(withPrefix: "quit:").isEmpty && rig.log.events(withPrefix: "hide:").isEmpty)
    }

    @Test func onAStartLinkThatWouldQuitDoesNothingAndAsksNothing() async throws {
        let authenticator = FakeAuthenticator(.authenticated)
        let (rig, coding) = try await rig(on: true, authenticator)
        let before = rig.log.events.count

        let report = try await rig.switcher.start(coding.id, trigger: .link)

        #expect(report.outcome == .notAuthenticated(.notInteractive))
        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(authenticator.reasons.isEmpty)
        #expect(rig.log.events.count == before)
        #expect(rig.session.current == Self.design.id)
    }

    @Test func onSiriStartThatWouldQuitDoesNothingAndSaysSo() async throws {
        let authenticator = FakeAuthenticator(.authenticated)
        let (rig, coding) = try await rig(on: true, authenticator)
        let before = rig.log.events.count
        var asked = false

        let report = try await rig.switcher.start(coding.id, trigger: .intent) { _ in asked = true }

        #expect(!asked)
        #expect(authenticator.reasons.isEmpty)
        #expect(report.outcome == .notAuthenticated(.notInteractive))
        #expect(rig.log.events.count == before)
        #expect(report.summary == "Didn't switch to “Coding”: it would quit apps, and quitting apps needs authentication, which Siri and Shortcuts can't ask for. Nothing was quit.")
    }

    /// Triggers and a Focus never quit, so they never need authentication and still work.
    @Test(arguments: [TransitionTrigger.automation, .focus])
    func onTriggersAndFocusStillHideWithoutAsking(trigger: TransitionTrigger) async throws {
        let authenticator = FakeAuthenticator(.refused(.failed))
        let (rig, coding) = try await rig(on: true, authenticator)

        let report = try await rig.switcher.start(coding.id, trigger: trigger)

        #expect(report.outcome == .done)
        #expect(rig.log.events(withPrefix: "quit:").isEmpty)
        #expect(rig.log.events(withPrefix: "hide:").count == 2)
        #expect(authenticator.reasons.isEmpty)
        #expect(rig.session.current == coding.id)
    }

    @Test func onCloseAllInTheRigForceQuitsOnlyOnceAuthenticated() async {
        let authenticator = FakeAuthenticator(.refused(.cancelled))
        let rig = SwitchingRig(groups: [Self.design], authentication: gate(true, authenticator))
        rig.apps.run("com.figma.Desktop", name: "Figma")

        #expect(await rig.quitRequests.quit(Self.design, mode: .force, from: .userAction) == .notAuthenticated(.cancelled))
        #expect(rig.log.events.isEmpty)

        authenticator.result = .authenticated
        _ = await rig.quitRequests.quit(Self.design, mode: .force, from: .userAction)
        #expect(rig.log.events == ["force:com.figma.desktop"])
    }
}
