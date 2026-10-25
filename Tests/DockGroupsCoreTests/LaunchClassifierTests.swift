import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: how a launch counts")
struct LaunchClassifierTests {
    private static let session = Date(timeIntervalSince1970: 1_800_000_000)

    private func kind(loginItem: Bool = false, session: Date? = session, after seconds: TimeInterval, request: Bool = false) -> LaunchKind {
        LaunchClassifier.kind(
            launchedAsLoginItem: loginItem,
            consoleSessionStart: session,
            launchedAt: Self.session.addingTimeInterval(seconds),
            hadRequest: request
        )
    }

    @Test func aLaunchSoonAfterLoggingInIsTheLogin() {
        #expect(kind(after: 12) == .login(session: Self.session))
        #expect(kind(after: LaunchClassifier.loginWindow) == .login(session: Self.session))
        // A clock a little behind the login record still counts.
        #expect(kind(after: -30) == .login(session: Self.session))
    }

    @Test func laterLaunchesAreNormalUnlessMacOSOpenedTheLoginItem() {
        #expect(kind(after: LaunchClassifier.loginWindow + 1) == .normal)
        #expect(kind(after: 3 * 3600) == .normal)
        #expect(kind(after: -120) == .normal)
        // macOS opened it as a login item, late after a slow login: still the login, of that session.
        #expect(kind(loginItem: true, after: 3 * 3600) == .login(session: Self.session))
    }

    @Test func aLaunchWithALinkOrARequestIsQuiet() {
        #expect(kind(after: 12, request: true) == .quiet)
        #expect(kind(loginItem: true, after: 12, request: true) == .quiet)
        #expect(kind(after: 3 * 3600, request: true) == .quiet)
    }

    @Test func withoutTheLoginRecordOnlyTheLoginItemFlagTells() {
        let launched = Self.session.addingTimeInterval(40)
        #expect(kind(session: nil, after: 40) == .normal)
        #expect(kind(loginItem: true, session: nil, after: 40) == .login(session: launched))
        #expect(kind(loginItem: true, session: nil, after: 40, request: true) == .quiet)
    }
}
