import Foundation
import LocalAuthentication
import Testing
@testable import DockGroupsCore

/// The gaps around "Ask for authentication before quitting apps" (`docs/design/quit-authentication.md`):
/// turning it off asks too — without locking out a Mac that can't authenticate —, refused links
/// get one alert per window, the diagnostics report and the older-version warning mention it.
@MainActor
@Suite("Quit authentication: the setting")
struct QuitAuthenticationSettingTests {
    /// The saved setting, with what `apply` was called with.
    final class Setting {
        var isOn: Bool
        private(set) var applied: [Bool] = []
        init(_ isOn: Bool) { self.isOn = isOn }
        func apply(_ value: Bool) {
            applied.append(value)
            isOn = value
        }
    }

    /// Answers the "turn it off anyway?" question, counting how often it was asked.
    final class Confirmation {
        let answer: Bool
        private(set) var asked = 0
        init(_ answer: Bool) { self.answer = answer }
        func confirm() -> Bool {
            asked += 1
            return answer
        }
    }

    private func change(
        _ setting: Setting,
        to isOn: Bool,
        _ authenticator: FakeAuthenticator?,
        confirmation: Confirmation = Confirmation(false)
    ) async -> QuitAuthenticationChange {
        let gate = QuitAuthentication(isRequired: { setting.isOn }, authenticator: authenticator)
        return await gate.change(to: isOn, confirmWithoutAuthentication: confirmation.confirm, apply: setting.apply)
    }

    // MARK: - Turning it off asks

    @Test func turningOffAsksAndTurnsOffOnceAuthenticated() async {
        let setting = Setting(true)
        let authenticator = FakeAuthenticator(.authenticated)
        let confirmation = Confirmation(false)

        #expect(await change(setting, to: false, authenticator, confirmation: confirmation) == .turnedOff)
        #expect(!setting.isOn)
        #expect(setting.applied == [false])
        #expect(authenticator.reasons == [QuitAuthentication.turnOffReason])
        #expect(QuitAuthentication.turnOffReason == "turn off authentication before quitting apps")
        #expect(confirmation.asked == 0)
    }

    @Test(arguments: [QuitAuthenticationFailure.cancelled, .failed])
    func aCancelledOrFailedAuthenticationKeepsItOnAndSaysSo(failure: QuitAuthenticationFailure) async {
        let setting = Setting(true)
        let confirmation = Confirmation(true)

        let result = await change(setting, to: false, FakeAuthenticator(.refused(failure)), confirmation: confirmation)
        #expect(result == .keptOn(failure))
        #expect(!result.turnsOff)
        #expect(setting.isOn)
        #expect(setting.applied.isEmpty)
        // Not offered "anyway": the Mac could authenticate, the user didn't.
        #expect(confirmation.asked == 0)
        #expect(QuitAuthenticationChange.turnOffRefusalMessage
            == "“Ask for authentication before quitting apps” stays on: authentication was cancelled or failed.")
    }

    /// No password, no Touch ID, no window for the prompt …: the user isn't locked into a setting
    /// that quits nothing — they're asked whether to turn it off anyway.
    @Test(arguments: [
        LAError.Code.passcodeNotSet.rawValue,
        LAError.Code.biometryNotAvailable.rawValue,
        LAError.Code.biometryNotEnrolled.rawValue,
        LAError.Code.biometryLockout.rawValue,
        LAError.Code.notInteractive.rawValue,
        LAError.Code.invalidContext.rawValue,
    ])
    func unavailableAuthenticationTurnsOffOnlyOnceConfirmed(code: Int) async {
        let failure = DeviceOwnerAuthenticator.failure(forErrorCode: code)

        let confirmed = Setting(true)
        let yes = Confirmation(true)
        #expect(await change(confirmed, to: false, FakeAuthenticator(.refused(failure)), confirmation: yes) == .turnedOffWithoutAuthentication)
        #expect(!confirmed.isOn)
        #expect(yes.asked == 1)

        let declined = Setting(true)
        let no = Confirmation(false)
        #expect(await change(declined, to: false, FakeAuthenticator(.refused(failure)), confirmation: no) == .declined)
        #expect(declined.isOn)
        #expect(declined.applied.isEmpty)
        #expect(no.asked == 1)
    }

    @Test func notInteractiveAndNoAuthenticatorCountAsUnavailable() async {
        let refused = Setting(true)
        #expect(await change(refused, to: false, FakeAuthenticator(.refused(.notInteractive)), confirmation: Confirmation(true))
            == .turnedOffWithoutAuthentication)
        #expect(!refused.isOn)

        let without = Setting(true)
        let confirmation = Confirmation(true)
        #expect(await change(without, to: false, nil, confirmation: confirmation) == .turnedOffWithoutAuthentication)
        #expect(!without.isOn)
        #expect(confirmation.asked == 1)
        #expect(QuitAuthenticationChange.turnOffWithoutAuthenticationQuestion
            == "Authentication isn't available on this Mac; turn off “Ask for authentication before quitting apps” anyway?")
    }

    @Test func turningOnAsksNothing() async {
        let setting = Setting(false)
        let authenticator = FakeAuthenticator(.refused(.failed))
        let confirmation = Confirmation(false)

        #expect(await change(setting, to: true, authenticator, confirmation: confirmation) == .turnedOn)
        #expect(setting.isOn)
        #expect(authenticator.reasons.isEmpty)
        #expect(confirmation.asked == 0)
    }

    @Test func alreadyAsAskedChangesNothing() async {
        let off = Setting(false)
        let authenticator = FakeAuthenticator(.authenticated)
        #expect(await change(off, to: false, authenticator) == .unchanged)
        let on = Setting(true)
        #expect(await change(on, to: true, authenticator) == .unchanged)
        #expect(authenticator.reasons.isEmpty)
        #expect(off.applied.isEmpty && on.applied.isEmpty)
    }

    /// One prompt at a time, shared with quitting: turning it off while Close All's prompt shows
    /// is dropped, and the setting stays on.
    @Test func turningOffWhileAQuitPromptShowsIsDropped() async {
        let setting = Setting(true)
        let authenticator = FakeAuthenticator(.authenticated)
        authenticator.holds = true
        let gate = QuitAuthentication(isRequired: { setting.isOn }, authenticator: authenticator)

        let quitting = Task { await gate.authenticate() }
        while !gate.isAuthenticating { await Task.yield() }
        #expect(await gate.change(to: false, confirmWithoutAuthentication: { true }, apply: setting.apply) == .dropped)
        #expect(setting.isOn)
        authenticator.release()
        #expect(await quitting.value == .authenticated)
        #expect(authenticator.reasons == [QuitAuthentication.reason])
    }

    // MARK: - Refused links: one alert per window

    /// `shouldAlert`, outside `#expect` (which can't mutate).
    private static func alerts(_ notice: inout LinkRefusalNotice, at now: Date) -> Bool {
        notice.shouldAlert(at: now)
    }

    @Test func refusedLinksInOneWindowGetOneAlert() {
        var notice = LinkRefusalNotice()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LinkRefusalNotice.window == 5)

        var alerts = 0
        for offset in [0.0, 1, 2] {
            let now = start.addingTimeInterval(offset)
            if notice.shouldAlert(at: now) {
                alerts += 1
                // The alert is answered right away.
                notice.alertDismissed(at: now)
            }
        }
        #expect(alerts == 1)
        // The swallowed refusals don't extend the window: 5 seconds after the alert, a new one.
        #expect(!Self.alerts(&notice, at: start.addingTimeInterval(4.9)))
        #expect(Self.alerts(&notice, at: start.addingTimeInterval(5)))
    }

    @Test func noSecondAlertWhileOneShowsAndTheWindowRestartsWhenItsDismissed() {
        var notice = LinkRefusalNotice()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(Self.alerts(&notice, at: start))
        #expect(notice.isShowing)
        // Left open past the window: still one alert.
        #expect(!Self.alerts(&notice, at: start.addingTimeInterval(30)))
        notice.alertDismissed(at: start.addingTimeInterval(40))
        #expect(!notice.isShowing)
        #expect(!Self.alerts(&notice, at: start.addingTimeInterval(44)))
        #expect(Self.alerts(&notice, at: start.addingTimeInterval(45)))
    }

    @Test func aClockGoingBackwardsEndsTheWindow() {
        var notice = LinkRefusalNotice()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Self.alerts(&notice, at: start))
        notice.alertDismissed(at: start)
        #expect(Self.alerts(&notice, at: start.addingTimeInterval(-60)))
    }

    // MARK: - Diagnostics and older versions

    @Test(arguments: [true, false])
    func theDiagnosticsReportSaysWhetherItsOn(isOn: Bool) {
        let info = DiagnosticsInfo(
            app: .init(version: "0.17.0", build: "1700", path: "/Applications/Cybokron Dock Groups.app"),
            system: .init(macOSVersion: "Version 15.1 (Build 24B83)", hardwareModel: "Mac15,6", architecture: "arm64"),
            isAccessibilityTrusted: true,
            isStatusItemShown: true,
            preferences: PopupPreferences(asksForAuthenticationBeforeQuitting: isOn),
            updates: .init(lastCheckDate: nil, lastResult: "Never checked"),
            groups: [],
            recentErrors: []
        )
        let text = DiagnosticsReport.text(for: info, homeDirectory: "/Users/jane")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.filter { $0.hasPrefix("Ask before quitting apps:") } == ["Ask before quitting apps: \(isOn ? "on" : "off")"])
        // In the Settings section.
        let settings = lines.firstIndex(of: "== Settings ==")
        let updates = lines.firstIndex(of: "== Updates ==")
        let line = lines.firstIndex { $0.hasPrefix("Ask before quitting apps:") }
        #expect(settings != nil && updates != nil && line != nil)
        if let settings, let updates, let line {
            #expect(settings < line && line < updates)
        }
    }

    private static func version(_ text: String) -> SemanticVersion {
        SemanticVersion(text)!
    }

    @Test func goingBackToAVersionWithoutItWarnsWhileItsOn() {
        let on = PopupPreferences(asksForAuthenticationBeforeQuitting: true)
        #expect(ReleaseHistory.firstQuitAuthenticationVersion == Self.version("0.17.0"))

        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.16.1"), over: Self.version("0.17.0"), preferences: on) == [
            "Version 0.16.1 doesn't know “Ask for authentication before quitting apps”: it quits apps without asking, and the setting is lost once it saves your settings.",
        ])
        // Without a running version (development), as the other warnings.
        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.16.1"), over: nil, preferences: on).count == 1)
    }

    @Test func noWarningWhileItsOffOrTheVersionKnowsIt() {
        let on = PopupPreferences(asksForAuthenticationBeforeQuitting: true)
        let off = PopupPreferences()
        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.16.1"), over: Self.version("0.17.0"), preferences: off).isEmpty)
        // A version that has it, going back or not.
        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.17.0"), over: Self.version("0.17.1"), preferences: on).isEmpty)
        // Going up from an older version, or the same version again.
        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.17.0"), over: Self.version("0.16.1"), preferences: on).isEmpty)
        #expect(DowngradeProtection.quitAuthenticationWarning(installing: Self.version("0.16.1"), over: Self.version("0.16.1"), preferences: on).isEmpty)
    }
}
