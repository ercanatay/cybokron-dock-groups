import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group lookup")
struct GroupLookupTests {
    @Test(arguments: [
        ("Work", "work"),
        ("  Deep   Work  ", "deep-work"),
        ("Çalışma Alanı", "calisma-alani"),
        ("İŞ ÜÇ", "is-uc"),
        ("Dev & Ops!", "dev-ops"),
        ("Café 2", "cafe-2"),
        ("Straße", "strasse"),
        ("🎮 Games", "games"),
        ("🎮", ""),
    ])
    func slugsAreLowercaseASCIIWithHyphens(name: String, slug: String) {
        #expect(GroupLookup.slug(for: name) == slug)
    }

    @Test func findsGroupsBySlugIdentifierOrExactEmojiName() {
        let work = DockGroup(name: "Work")
        let deep = DockGroup(name: "Çalışma Alanı")
        let games = DockGroup(name: "🎮")
        let groups = [work, deep, games]

        #expect(GroupLookup.group(matching: "work", in: groups)?.id == work.id)
        #expect(GroupLookup.group(matching: "WORK", in: groups)?.id == work.id)
        #expect(GroupLookup.group(matching: "calisma-alani", in: groups)?.id == deep.id)
        #expect(GroupLookup.group(matching: "Çalışma alanı", in: groups)?.id == deep.id)
        #expect(GroupLookup.group(matching: deep.id.uuidString, in: groups)?.id == deep.id)
        #expect(GroupLookup.group(matching: deep.id.uuidString.lowercased(), in: groups)?.id == deep.id)
        #expect(GroupLookup.group(matching: "🎮", in: groups)?.id == games.id)
        #expect(GroupLookup.group(matching: "play", in: groups) == nil)
        #expect(GroupLookup.group(matching: "  ", in: groups) == nil)
    }

    @Test func firstGroupWinsWhenSlugsCollide() {
        let first = DockGroup(name: "Dev Ops")
        let second = DockGroup(name: "dev-ops")
        #expect(GroupLookup.group(matching: "dev-ops", in: [first, second])?.id == first.id)
    }

    @Test func searchIgnoresCaseAccentsAndPunctuation() {
        let work = DockGroup(name: "Work")
        let deep = DockGroup(name: "Deep Work")
        let cafe = DockGroup(name: "Café")
        let groups = [work, deep, cafe]

        #expect(GroupLookup.search("work", in: groups).map(\.id) == [work.id, deep.id])
        #expect(GroupLookup.search("cafe", in: groups).map(\.id) == [cafe.id])
        #expect(GroupLookup.search("deep-work", in: groups).map(\.id) == [deep.id])
        #expect(GroupLookup.search("", in: groups).count == 3)
        #expect(GroupLookup.search("music", in: groups).isEmpty)
    }
}

@Suite("URL commands")
struct URLCommandTests {
    private func command(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init(url:))
    }

    @Test func parsesGroupCommands() {
        #expect(command("cybokrondockgroups://open/work") == .showGroup("work"))
        #expect(command("cybokrondockgroups://show/Deep%20Work") == .showGroup("Deep Work"))
        #expect(command("CybokronDockGroups://OPEN/Work/") == .showGroup("Work"))
        #expect(command("cybokrondockgroups:open/work") == .showGroup("work"))
        #expect(command("cybokrondockgroups://open/Dev%2FOps") == .showGroup("Dev/Ops"))
        #expect(command("cybokrondockgroups://open/%C3%87al%C4%B1%C5%9Fma") == .showGroup("Çalışma"))
        #expect(command("cybokrondockgroups://launch/work") == .launchGroup("work"))
        #expect(command("cybokrondockgroups://quit/work") == .quitGroup("work", .graceful))
        #expect(command("cybokrondockgroups://quit/work?mode=force") == .quitGroup("work", .force))
        #expect(command("cybokrondockgroups://shortcut/3") == .showShortcut(3))
    }

    @Test func groupIdentifierInAURLFindsTheGroup() throws {
        let work = DockGroup(name: "Work")
        let play = DockGroup(name: "Play")
        let parsed = try #require(command("cybokrondockgroups://open/\(play.id.uuidString)"))
        guard case .showGroup(let token) = parsed else {
            Issue.record("Expected showGroup, got \(parsed)")
            return
        }
        #expect(GroupLookup.group(matching: token, in: [work, play])?.id == play.id)
        #expect(command("cybokrondockgroups://launch/\(work.id.uuidString.lowercased())") == .launchGroup(work.id.uuidString.lowercased()))
    }

    @Test func parsesAppCommands() {
        #expect(command("cybokrondockgroups://close") == .closePopup)
        #expect(command("cybokrondockgroups://settings") == .openSettings)
        #expect(command("cybokrondockgroups://groups") == .manageGroups)
    }

    @Test(arguments: [
        "https://open/work",
        "dockgroups://showPanel",
        "cybokrondockgroups://",
        "cybokrondockgroups://open",
        "cybokrondockgroups://open/",
        "cybokrondockgroups://launch",
        "cybokrondockgroups://shortcut/0",
        "cybokrondockgroups://shortcut/10",
        "cybokrondockgroups://shortcut/two",
        "cybokrondockgroups://close/work",
        "cybokrondockgroups://delete/work",
    ])
    func rejectsOtherSchemesAndMalformedCommands(url: String) {
        #expect(command(url) == nil)
    }

    @Test func spellingsOfTheSameGroupShareACooldownKey() {
        #expect(URLCommand.showGroup("Work").throttleKey == URLCommand.showGroup("work").throttleKey)
        #expect(URLCommand.showGroup("Deep Work").throttleKey == URLCommand.showGroup("deep-work").throttleKey)
        #expect(URLCommand.showGroup("work").throttleKey != URLCommand.launchGroup("work").throttleKey)
        #expect(URLCommand.quitGroup("work", .graceful).throttleKey != URLCommand.quitGroup("work", .force).throttleKey)
    }
}

@Suite("Command cooldown")
struct CommandThrottleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Feeds `requests` (key, seconds after `start`) to `throttle` and returns which were accepted.
    private func accepted(_ requests: [(String, TimeInterval)], by throttle: CommandThrottle = CommandThrottle()) -> [Bool] {
        var throttle = throttle
        return requests.map { key, offset in throttle.accept(key, at: start.addingTimeInterval(offset)) }
    }

    @Test func swallowsRepeatsWithinFiveSeconds() {
        #expect(CommandThrottle().interval == 5)
        let results = accepted([("show/work", 0), ("show/work", 0.2), ("show/work", 4.9), ("show/work", 5)])
        #expect(results == [true, false, false, true])
    }

    @Test func swallowedRepeatsDoNotExtendTheCooldown() {
        let results = accepted([("show/work", 0), ("show/work", 3), ("show/work", 5.5)], by: CommandThrottle(interval: 5))
        #expect(results == [true, false, true])
    }

    @Test func differentRequestsHaveTheirOwnCooldown() {
        let results = accepted([("show/work", 0), ("show/play", 1), ("close", 1), ("show/play", 2)])
        #expect(results == [true, true, true, false])
    }

    @Test func clockGoingBackwardsEndsTheCooldown() {
        #expect(accepted([("show/work", 0), ("show/work", -60)]) == [true, true])
    }
}

@Suite("Report summaries")
struct ReportSummaryTests {
    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")

    @Test func launchSummaries() {
        #expect(LaunchReport(groupName: "Work", entries: []).summary == "“Work” has no apps yet.")
        #expect(LaunchReport(groupName: "Work", entries: [
            .init(app: Self.safari, outcome: .launched), .init(app: Self.mail, outcome: .activated),
        ]).summary == "Opened all 2 apps in “Work”.")
        #expect(LaunchReport(groupName: "Work", entries: [
            .init(app: Self.safari, outcome: .launched), .init(app: Self.mail, outcome: .notFound),
        ]).summary == "Opened 1 of 2 apps in “Work”. Couldn't open Mail.")
        #expect(LaunchReport(groupName: "Work", entries: [
            .init(app: Self.mail, outcome: .failed(reason: "Damaged")),
        ]).summary == "Couldn't open the apps in “Work”: Mail.")
    }

    @Test func quitSummaries() {
        #expect(QuitReport(groupName: "Work", mode: .graceful, quit: [], refused: []).summary
            == "None of the apps in “Work” are running.")
        #expect(QuitReport(groupName: "Work", mode: .graceful, quit: [Self.safari, Self.mail], refused: []).summary
            == "Asked 2 apps in “Work” to quit.")
        #expect(QuitReport(groupName: "Work", mode: .force, quit: [Self.safari], refused: [Self.mail]).summary
            == "Force quit 1 app in “Work”. Couldn't quit Mail.")
    }
}
