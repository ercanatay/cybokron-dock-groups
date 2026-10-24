import Foundation
import Testing
@testable import DockGroupsCore

/// What the popup, the menu bar menu and the group window offer for a group (PR 3's surfaces).
@Suite("Switching: Start and Finish buttons")
struct SwitchingOfferTests {
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private static func coding(_ switching: GroupSwitching = GroupSwitching()) -> DockGroup {
        .of("Coding", ["com.apple.dt.Xcode"], switching: switching)
    }

    @Test func theCurrentGroupOffersFinishAndTheOthersStart() {
        let coding = Self.coding()
        let groups = [Self.design, coding]

        let finish = SwitchingOffer.offer(for: coding, current: coding.id, previous: Self.design.id, in: groups)
        #expect(finish == SwitchingOffer(action: .finish, groupName: "Coding", otherGroupName: "Design", switching: GroupSwitching()))
        #expect(finish.title == "Finish")
        #expect(finish.systemImage == "stop.fill")
        #expect(finish.accessibilityLabel == "Finish Coding")
        #expect(finish.help == "Finish: hide this group's apps and show “Design” again.")

        let start = SwitchingOffer.offer(for: Self.design, current: coding.id, previous: Self.design.id, in: groups)
        #expect(start == SwitchingOffer(action: .start, groupName: "Design", otherGroupName: "Coding", switching: GroupSwitching()))
        #expect(start.title == "Start")
        #expect(start.systemImage == "play.fill")
        #expect(start.accessibilityLabel == "Start Design")
        #expect(start.help == "Start: open this group's items and hide the apps of “Coding”.")

        // No current group: every group offers Start, putting nothing away.
        let alone = SwitchingOffer.offer(for: coding, current: nil, previous: nil, in: groups)
        #expect(alone.action == .start && alone.otherGroupName == nil)
        #expect(alone.help == "Start: open this group's items and make it the current group.")
        // A current group that was deleted meanwhile isn't named.
        #expect(SwitchingOffer.offer(for: coding, current: UUID(), previous: nil, in: groups).otherGroupName == nil)
    }

    @Test(arguments: [
        (GroupSwitching.OnStart.leaveOthers, "Start: open this group's items and leave the other apps as they are."),
        (.hidePreviousGroup, "Start: open this group's items and hide the apps of “Design”."),
        (.hideAllOtherApps, "Start: open this group's items and hide all other apps."),
        (.quitPreviousGroup, "Start: open this group's items and quit the apps of “Design” it doesn't use."),
    ])
    func startSaysWhatItDoesToTheOtherApps(_ onStart: GroupSwitching.OnStart, _ help: String) {
        let offer = SwitchingOffer.start(Self.coding(GroupSwitching(onStart: onStart)), current: Self.design)
        #expect(offer.help == help)
    }

    @Test func startingTheCurrentGroupAgainPutsNothingAway() {
        let coding = Self.coding(GroupSwitching(onStart: .quitPreviousGroup))
        let offer = SwitchingOffer.start(coding, current: coding)
        #expect(offer.otherGroupName == nil)
        #expect(offer.help == "Start: open this group's items and make it the current group.")
    }

    @Test(arguments: [
        (GroupSwitching.OnFinish.hideApps, true, "Finish: hide this group's apps and show “Design” again."),
        (.hideApps, false, "Finish: hide this group's apps."),
        (.quitApps, true, "Finish: quit this group's apps and show “Design” again."),
        (.quitApps, false, "Finish: quit this group's apps."),
        (.leaveApps, true, "Finish: leave this group's apps open and show “Design” again."),
        (.leaveApps, false, "Finish: leave this group's apps open; it's no longer the current group."),
    ])
    func finishSaysWhatItDoesAndWhatComesBack(_ onFinish: GroupSwitching.OnFinish, _ hasPrevious: Bool, _ help: String) {
        let offer = SwitchingOffer.finish(Self.coding(GroupSwitching(onFinish: onFinish)), previous: hasPrevious ? Self.design : nil)
        #expect(offer.help == help)
    }

    @Test func finishingWithoutShowingThePreviousGroupDoesntNameIt() {
        let coding = Self.coding(GroupSwitching(afterFinish: .nothing))
        let offer = SwitchingOffer.finish(coding, previous: Self.design)
        #expect(offer.otherGroupName == nil)
        #expect(offer.help == "Finish: hide this group's apps.")
        #expect(SwitchingOffer.finish(Self.coding(), previous: Self.coding()).otherGroupName == "Coding", "another group of the same name")
    }
}

@Suite("Switching: editing the protected apps")
struct ProtectedAppsEditingTests {
    private static func app(_ bundleIdentifier: String, _ name: String) -> GroupItem {
        GroupItem(bundleIdentifier: bundleIdentifier, name: name)
    }

    @Test func addingKeepsAppsOnlyEachOnceAndAtMostFifty() {
        var list = ProtectedApps([Self.app("com.apple.Music", "Music")])
        list = list.adding([
            Self.app("COM.APPLE.MUSIC", "Music again"),
            Self.app("com.apple.FaceTime", "FaceTime"),
            GroupItem(websiteURL: URL(string: "https://example.com")!),
        ])
        #expect(list.apps.map(\.name) == ["Music", "FaceTime"])
        #expect(!list.isFull)

        let many = (0..<60).map { Self.app("com.example.app\($0)", "App \($0)") }
        let full = list.adding(many)
        #expect(full.apps.count == ProtectedApps.maximumCount)
        #expect(full.isFull)
        #expect(full.apps.prefix(2).map(\.name) == ["Music", "FaceTime"], "the ones already there stay first")
        #expect(full.adding([Self.app("com.example.late", "Late")]) == full)
    }

    @Test func removingIgnoresCase() {
        let list = ProtectedApps([Self.app("com.apple.Music", "Music"), Self.app("com.apple.FaceTime", "FaceTime")])
        #expect(list.removing(identity: "COM.apple.music").apps.map(\.name) == ["FaceTime"])
        #expect(list.removing(identity: "com.example.other") == list)
    }

    @Test func runningAppsOfferedAreTheOnesNotProtectedYet() {
        let list = ProtectedApps([Self.app("com.apple.Music", "Music")])
        let running = [
            Self.app("com.apple.Safari", "Safari"),
            Self.app("com.apple.music", "Music"),
            Self.app("com.cybokron.dockgroups", "Cybokron Dock Groups"),
            Self.app("\(AgentIdentity.bundleIdentifierPrefix)\(UUID().uuidString)", "Coding"),
            Self.app("com.apple.finder", "Finder"),
            Self.app("com.apple.Safari", "Safari"),
            Self.app("com.apple.AppStore", "App Store"),
            GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Notes.txt"), kind: .file),
        ]
        // Finder can be protected from hiding; this app and its groups' apps always are.
        #expect(list.addable(from: running).map(\.name) == ["App Store", "Finder", "Safari"])
    }

    @Test @MainActor func closeAllSparesAnAppAsSoonAsSettingsProtectsIt() {
        let preferences = PreferencesStore(persistence: MemoryPreferencesPersistence(), saveDelay: .zero)
        let apps = FakeRunningApps()
        apps.run("com.apple.Music", name: "Music")
        apps.run("com.apple.dt.Xcode", name: "Xcode")
        // As the app wires it: the list is read from the preferences at every call.
        let terminator = GroupTerminator(applications: apps, ownProcessIdentifier: 1, listing: apps, protectedApps: { preferences.preferences.protectedApps })
        let group = DockGroup.of("Work", ["com.apple.Music", "com.apple.dt.Xcode"])

        preferences.update { $0.protectedApps = $0.protectedApps.adding([GroupItem(bundleIdentifier: "com.apple.Music", name: "Music")]) }
        let report = terminator.closeAll(group, mode: .graceful)

        #expect(report.kept.map(\.bundleIdentifier) == ["com.apple.Music"])
        #expect(report.quit.map(\.bundleIdentifier) == ["com.apple.dt.Xcode"])
        #expect(apps.log.events == ["quit:com.apple.dt.xcode"])
    }
}

@Suite("Switching: every link the app handles")
struct LinkCommandTests {
    private func link(_ string: String) -> LinkCommand? {
        URL(string: string).flatMap(LinkCommand.init(url:))
    }

    @Test func parsesTheURLCommandsAndTheSwitchingLinks() {
        #expect(link("cybokrondockgroups://launch/coding") == .command(.launchGroup("coding")))
        #expect(link("cybokrondockgroups://quit/coding?mode=force") == .command(.quitGroup("coding", .force)))
        #expect(link("cybokrondockgroups://settings") == .command(.openSettings))
        #expect(link("cybokrondockgroups://start/coding") == .switching(.start("coding")))
        #expect(link("cybokrondockgroups://switch/Deep%20Work") == .switching(.start("Deep Work")))
        #expect(link("cybokrondockgroups://finish/coding") == .switching(.finish("coding")))
    }

    @Test(arguments: ["cybokrondockgroups://start", "cybokrondockgroups://unknown/coding", "https://launch/coding", "cybokrondockgroups://"])
    func rejectsWhatNeitherParses(_ string: String) {
        #expect(link(string) == nil)
    }

    @Test func keysAreTheParsedCommands() {
        #expect(LinkCommand.command(.launchGroup("Deep Work")).throttleKey == URLCommand.launchGroup("Deep Work").throttleKey)
        #expect(LinkCommand.command(.showGroup("a")).groupActionKey == nil)
        #expect(LinkCommand.switching(.start("Deep Work")).throttleKey == SwitchingURLCommand.start("deep-work").throttleKey)
        #expect(LinkCommand.switching(.finish("a")).groupActionKey == URLCommand.groupAppsKey)
    }

    @Test func oneGateLimitsLaunchHideStartAndFinishTogether() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var gate = URLCommandGate()
        let links = try ["start/coding", "launch/design", "finish/coding", "open/coding", "start/coding"].map {
            try #require(link("cybokrondockgroups://\($0)"))
        }
        let decisions = links.enumerated().map { index, link in gate.accept(link, at: start.addingTimeInterval(Double(index))) }
        #expect(decisions == [.accepted, .groupActionLimited, .groupActionLimited, .accepted, .repeated])
    }
}

@Suite("Switching: Siri phrases and links in Settings")
struct SwitchingInvocationsTests {
    @Test func phrasesMatchTheAppShortcuts() {
        let phrases = GroupInvocations.switchingPhrases(groupName: "Work", appName: "Cybokron Dock Groups")
        #expect(phrases.map(\.title) == ["Start Group", "Finish Group"])
        #expect(phrases.map(\.text) == ["Start Work in Cybokron Dock Groups", "Finish Work in Cybokron Dock Groups"])
    }

    @Test func linksUseTheGroupsTokenAndParse() throws {
        let group = DockGroup(name: "Çalışma Alanı")
        let links = GroupInvocations.switchingLinks(for: group, in: [group])
        #expect(links.map(\.title) == ["Start", "Finish"])
        #expect(links.map(\.text) == ["cybokrondockgroups://start/calisma-alani", "cybokrondockgroups://finish/calisma-alani"])
        let commands = try links.map { try #require(URL(string: $0.text).flatMap(LinkCommand.init(url:))) }
        #expect(commands == [.switching(.start("calisma-alani")), .switching(.finish("calisma-alani"))])
        #expect(GroupLookup.group(matching: "calisma-alani", in: [group])?.id == group.id)

        // A name the slug doesn't find on its own is linked by identifier, as the other links are.
        let emoji = DockGroup(name: "🎮")
        #expect(GroupInvocations.switchingLinks(for: emoji, in: [emoji]).map(\.text) == ["cybokrondockgroups://start/\(emoji.id.uuidString)", "cybokrondockgroups://finish/\(emoji.id.uuidString)"])
    }
}

@Suite("Switching: the link's alert")
struct TransitionAlertTests {
    @Test func buttonsAreQuitHideInsteadAndCancelAndOnlyQuittingWaits() {
        let start = TransitionConfirmation(kind: .start(group: "Coding", previousGroup: "Design"), appNames: ["Figma"])
        #expect(start.alertButtons == [
            .init(title: "Quit and Switch", answer: .quit, isDelayed: true),
            .init(title: "Hide Instead", answer: .hideInstead, isDelayed: false),
            .init(title: "Cancel", answer: .cancel, isDelayed: false),
        ])
        let finish = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: nil), appNames: ["Xcode"])
        #expect(finish.alertButtons.map(\.title) == ["Quit Apps", "Hide Instead", "Cancel"])
    }

    @Test func answersFollowTheButtonsAndAnythingElseCancels() {
        let question = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: "Design"), appNames: ["Xcode"])
        #expect((0...2).map(question.answer(forButtonAt:)) == [.quit, .hideInstead, .cancel])
        #expect(question.answer(forButtonAt: 3) == .cancel)
        #expect(question.answer(forButtonAt: -1000) == .cancel)
    }
}

/// A link's cooldown starts again once its question is answered (`TransitionReport.wasAsked`).
@Suite("Switching: whether the user was asked")
@MainActor
struct TransitionAskedTests {
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private static let coding = DockGroup.of("Coding", ["com.apple.dt.Xcode"], switching: GroupSwitching(onStart: .quitPreviousGroup))

    /// Design is current, Figma runs; Coding quits the previous group's apps when it starts.
    private func rig(answer: TransitionConfirmation.Answer = .quit, coding: DockGroup? = nil) async throws -> SwitchingRig {
        let rig = SwitchingRig(groups: [Self.design, coding ?? Self.coding], answer: answer)
        rig.apps.run("com.figma.Desktop", name: "Figma")
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
        return rig
    }

    @Test(arguments: [TransitionConfirmation.Answer.quit, .hideInstead, .cancel])
    func aLinksQuestionCountsWhateverTheAnswer(_ answer: TransitionConfirmation.Answer) async throws {
        let rig = try await rig(answer: answer)
        let report = try await rig.switcher.start(Self.coding.id, trigger: .link)
        #expect(report.wasAsked)
        #expect(report.outcome == (answer == .cancel ? .declined : .done))
        #expect(rig.transitionPrompt.asked.count == 1)
    }

    @Test func withoutAQuestionNobodyWasAsked() async throws {
        let clicked = try await rig()
        #expect(try await !clicked.switcher.start(Self.coding.id, trigger: .userAction).wasAsked)

        // A link whose transition only hides doesn't ask.
        let hidingCoding = DockGroup.of("Coding", ["com.apple.dt.Xcode"])
        let hiding = try await rig(coding: hidingCoding)
        let report = try await hiding.switcher.start(hidingCoding.id, trigger: .link)
        #expect(!report.wasAsked && report.outcome == .done)
        #expect(hiding.transitionPrompt.asked.isEmpty)
    }

    @Test func siriAnsweringCounts() async throws {
        let rig = try await rig()
        var asked: [TransitionConfirmation] = []
        let report = try await rig.switcher.start(Self.coding.id, trigger: .intent) { asked.append($0) }
        #expect(report.wasAsked && asked.count == 1)
        #expect(rig.transitionPrompt.asked.isEmpty, "Siri asks, not the app's alert")
    }
}
