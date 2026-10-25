import Carbon.HIToolbox
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group shortcuts: the store")
@MainActor
struct GroupShortcutStoreTests {
    private static let controlOption: KeyModifiers = [.control, .option]

    private func store(_ groups: [DockGroup] = []) -> (GroupStore, MemoryGroupPersistence) {
        let persistence = MemoryGroupPersistence()
        try? persistence.saveGroups(groups)
        return (GroupStore(persistence: persistence, saveDelay: .zero), persistence)
    }

    @Test func givesAGroupItsShortcutAndSavesOnce() {
        let (store, persistence) = store()
        let coding = store.addGroup(named: "Coding")
        let saves = persistence.saveCount
        let shortcut = makeShortcut(kVK_ANSI_C, Self.controlOption, .startOrFinish)

        #expect(store.setShortcut(shortcut, forGroup: coding.id) == .assigned)
        #expect(store.group(withID: coding.id)?.shortcut == shortcut)
        #expect(persistence.saveCount == saves + 1)

        #expect(store.setShortcut(shortcut, forGroup: coding.id) == .unchanged)
        #expect(persistence.saveCount == saves + 1, "nothing saved for the same shortcut")

        #expect(store.setShortcut(nil, forGroup: coding.id) == .assigned)
        #expect(store.group(withID: coding.id)?.shortcut == nil)
        #expect(store.setShortcut(nil, forGroup: coding.id) == .unchanged)
        #expect(store.setShortcut(shortcut, forGroup: UUID()) == .unknownGroup)
    }

    @Test func refusesKeysAnotherGroupHas() {
        let (store, _) = store()
        let design = store.addGroup(named: "Design")
        let coding = store.addGroup(named: "Coding")
        let keys = makeShortcut(kVK_ANSI_D, Self.controlOption)
        store.setShortcut(keys, forGroup: design.id)

        #expect(store.setShortcut(makeShortcut(kVK_ANSI_D, Self.controlOption, .openAll), forGroup: coding.id) == .refused(.takenByGroup(design.id)))
        #expect(store.group(withID: coding.id)?.shortcut == nil)
        // Only the exact keys: with ⇧ they're other keys.
        #expect(store.setShortcut(makeShortcut(kVK_ANSI_D, Self.controlOption.union(.shift)), forGroup: coding.id) == .assigned)
        // A group keeps its own keys and may change what they do.
        #expect(store.setShortcut(makeShortcut(kVK_ANSI_D, Self.controlOption, .startOrFinish), forGroup: design.id) == .assigned)
        #expect(store.group(withID: design.id)?.shortcut?.action == .startOrFinish)
    }

    @Test func editsCantTakeAnotherGroupsKeys() {
        let (store, _) = store()
        let design = store.addGroup(named: "Design")
        let coding = store.addGroup(named: "Coding")
        store.setShortcut(makeShortcut(kVK_ANSI_D, Self.controlOption), forGroup: design.id)
        store.setShortcut(makeShortcut(kVK_ANSI_C, Self.controlOption), forGroup: coding.id)

        store.updateGroup(coding.id) { group in
            group.name = "Coding 2"
            group.shortcut = makeShortcut(kVK_ANSI_D, Self.controlOption)
        }

        let edited = store.group(withID: coding.id)
        #expect(edited?.name == "Coding 2", "the rest of the edit is taken")
        #expect(edited?.shortcut == makeShortcut(kVK_ANSI_C, Self.controlOption), "the shortcut stays as it was")

        store.updateGroup(coding.id) { $0.shortcut = makeShortcut(kVK_ANSI_K, Self.controlOption, .openAll) }
        #expect(store.group(withID: coding.id)?.shortcut == makeShortcut(kVK_ANSI_K, Self.controlOption, .openAll))
    }

    /// A groups file with two groups on the same keys (crafted, or edited by hand) loads as it is:
    /// the planner turns the later one off; the store doesn't rewrite the file.
    @Test func sharedKeysInAGroupsFileAreLoadedAsTheyAre() {
        let keys = makeShortcut(kVK_ANSI_X, Self.controlOption)
        let first = DockGroup.numbered(1, shortcut: keys)
        let second = DockGroup.numbered(2, shortcut: keys)
        let (store, persistence) = store([first, second])

        #expect(store.groups == [first, second])
        #expect(persistence.saveCount == 1, "only the test's own save")
        let plan = GroupShortcutPlanner.plan(groups: store.groups, numbers: .off, system: [])
        #expect(plan.statuses[second.id] == .off(.takenByGroup(first.id)))
        // Editing the later group's action keeps its (shared) keys.
        store.updateGroup(second.id) { $0.shortcut?.action = .openAll }
        #expect(store.group(withID: second.id)?.shortcut?.action == .openAll)
    }

    @Test func restoringABackupKeepsOnlyTheFirstOfSharedKeys() throws {
        let keys = makeShortcut(kVK_ANSI_X, Self.controlOption)
        let (store, _) = store()
        let first = DockGroup.numbered(1, shortcut: keys)
        let second = DockGroup.numbered(2, shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption, .openAll))
        let third = DockGroup.numbered(3, shortcut: makeShortcut(kVK_ANSI_Y, Self.controlOption))

        try store.replaceGroups(with: [first, second, third])

        #expect(store.groups.map(\.shortcut) == [keys, nil, third.shortcut])
    }

    @Test func mergedGroupsComeInWithoutKeysACurrentGroupHas() throws {
        let keys = makeShortcut(kVK_ANSI_X, Self.controlOption)
        let current = DockGroup.numbered(1, shortcut: keys)
        let (store, _) = store([current])
        let incoming = DockGroup(name: "From a backup", shortcut: makeShortcut(kVK_ANSI_X, Self.controlOption, .startOrFinish))
        let other = DockGroup(name: "Another", shortcut: makeShortcut(kVK_ANSI_Y, Self.controlOption))

        let result = try store.mergeGroups([incoming, other])

        #expect(store.group(withID: current.id)?.shortcut == keys)
        #expect(store.group(withID: incoming.id)?.shortcut == nil)
        #expect(store.group(withID: other.id)?.shortcut == other.shortcut)
        #expect(result.addedGroups.map(\.id) == [incoming.id, other.id])
        #expect(result.addedGroups.map(\.shortcut) == [nil, other.shortcut], "the result is what was added")
    }
}

@Suite("Group shortcuts: standalone groups' configurations")
struct GroupShortcutAgentTests {
    private static let group = DockGroup(name: "Work", apps: [AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")], isStandalone: true)

    @Test func agentsDontGetTheShortcut() throws {
        var withShortcut = Self.group
        withShortcut.shortcut = makeShortcut(kVK_ANSI_W, [.control, .option], .startOrFinish)

        let configuration = AgentConfiguration(group: withShortcut, preferences: PopupPreferences())

        #expect(configuration.group.shortcut == nil)
        #expect(configuration.group.apps == Self.group.apps)
    }

    @Test func givingAGroupAShortcutDoesntRebuildItsAgent() throws {
        let base = AgentConfiguration(group: Self.group, preferences: PopupPreferences())
        for shortcut in [makeShortcut(kVK_ANSI_W, [.control, .option]), makeShortcut(kVK_F13, [.control, .command], .openAll)] {
            var group = Self.group
            group.shortcut = shortcut
            let other = AgentConfiguration(group: group, preferences: PopupPreferences())
            #expect(other == base)
            #expect(try other.encoded() == base.encoded())
            let desired = DesiredAgent(configuration: other, folderName: "work.app", sourceDigest: "d")
            let installed = InstalledAgent(bundleURL: URL(fileURLWithPath: "/tmp/Agents/work.app"), bundleIdentifier: desired.bundleIdentifier, configuration: base, sourceDigest: "d")
            #expect(AgentPlanner.plan(desired: [desired], installed: [installed], runningBundleIdentifiers: []).isEmpty)
        }
    }
}

@Suite("Group shortcuts: Start and Finish from a key press")
@MainActor
struct ShortcutTriggerTests {
    private static let design = DockGroup.of("Design", ["com.figma.Desktop"])
    private static let coding = DockGroup.of("Coding", ["com.apple.dt.Xcode"], switching: GroupSwitching(onStart: .quitPreviousGroup))

    /// Design is current, Figma runs; Coding quits the previous group's apps when it starts.
    private func rig(answer: TransitionConfirmation.Answer, coding: DockGroup? = nil) async throws -> SwitchingRig {
        let rig = SwitchingRig(groups: [Self.design, coding ?? Self.coding], answer: answer)
        rig.apps.run("com.figma.Desktop", name: "Figma")
        _ = try await rig.switcher.start(Self.design.id, trigger: .userAction)
        rig.clock.advance(10)
        return rig
    }

    @Test func aKeyPressMayQuitButAsksFirst() {
        #expect(TransitionTrigger.shortcut.mayQuit)
        #expect(TransitionTrigger.shortcut.asksBeforeQuitting)
        #expect(TransitionTrigger.allCases.filter(\.asksBeforeQuitting) == [.link, .intent, .shortcut])
        #expect(TransitionTrigger.allCases.filter { !$0.mayQuit } == [.focus, .automation])
    }

    @Test func quittingAsksWithTheAppsAlert() async throws {
        let rig = try await rig(answer: .quit)

        let report = try await rig.switcher.start(Self.coding.id, trigger: .shortcut)

        #expect(report.wasAsked && report.outcome == .done)
        let question = try #require(rig.transitionPrompt.asked.first)
        #expect(question.requester == .keyboardShortcut)
        #expect(question.message == """
            “Coding” is set to quit the apps of “Design” it doesn't use: Figma.

            A keyboard shortcut asked for this.

            Apps can still ask to save changes.
            """)
        #expect(rig.log.events(withPrefix: "quit:") == ["com.figma.desktop"])
        #expect(rig.session.startTrigger == .shortcut)
    }

    @Test func hideInsteadHidesAndCancelDoesNothing() async throws {
        let hiding = try await rig(answer: .hideInstead)
        let hidden = try await hiding.switcher.start(Self.coding.id, trigger: .shortcut)
        #expect(hidden.outcome == .done)
        #expect(hiding.log.events(withPrefix: "quit:").isEmpty)
        #expect(hiding.log.events(withPrefix: "hide:") == ["com.figma.desktop"])

        let cancelling = try await rig(answer: .cancel)
        let cancelled = try await cancelling.switcher.start(Self.coding.id, trigger: .shortcut)
        #expect(cancelled.outcome == .declined)
        #expect(cancelling.log.events(withPrefix: "quit:").isEmpty && cancelling.log.events(withPrefix: "hide:").isEmpty)
        #expect(cancelling.session.current == Self.design.id)
    }

    @Test func hidingSettingsDontAsk() async throws {
        let hidingCoding = DockGroup.of("Coding", ["com.apple.dt.Xcode"])
        let rig = try await rig(answer: .cancel, coding: hidingCoding)

        let report = try await rig.switcher.start(hidingCoding.id, trigger: .shortcut)

        #expect(!report.wasAsked && report.outcome == .done)
        #expect(rig.transitionPrompt.asked.isEmpty)
        #expect(rig.log.events(withPrefix: "hide:") == ["com.figma.desktop"])
    }

    @Test func linksKeepTheirLine() {
        let link = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: nil), appNames: ["Xcode"])
        #expect(link.requester == .link)
        #expect(link.message.contains("A link opened by another app, a script or a web page asked for this."))
        let key = TransitionConfirmation(kind: .finish(group: "Coding", nextGroup: nil), appNames: ["Xcode"], requester: .keyboardShortcut)
        #expect(key.message.contains("A keyboard shortcut asked for this."))
        #expect(!key.message.contains("A link"))
        #expect(key.intentDialog == link.intentDialog, "Siri's question doesn't say where it came from")
    }

    @Test func theStartShortcutStartsAndFinishesTheCurrentGroup() {
        let session = ContextSession()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let coding = UUID()
        let design = UUID()

        #expect(ShortcutTransition.forGroup(coding, in: session, at: start) == .start)
        session.didStart(design, at: start, by: .shortcut)
        #expect(ShortcutTransition.forGroup(coding, in: session, at: start) == .start, "another group is current")
        session.didStart(coding, at: start, by: .shortcut)
        #expect(ShortcutTransition.forGroup(coding, in: session, at: start.addingTimeInterval(1)) == .nothing, "a double press")
        #expect(ShortcutTransition.forGroup(coding, in: session, at: start.addingTimeInterval(3)) == .finish)
        // Current because Finish went back to it: it wasn't just started.
        session.didStart(design, at: start.addingTimeInterval(10), by: .userAction)
        session.didFinish(design, showing: coding)
        #expect(ShortcutTransition.forGroup(coding, in: session, at: start.addingTimeInterval(10)) == .finish)
    }
}
