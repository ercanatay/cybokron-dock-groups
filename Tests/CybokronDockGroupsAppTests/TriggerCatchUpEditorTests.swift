import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// "Run what was missed" in the app: the editor shows Run It After the Mac Wakes for application
/// triggers only, and a trigger's status line keeps the trace of a catch-up.
@MainActor
struct TriggerCatchUpEditorTests {
    @Test func theRowShowsOnlyForApplicationTriggers() {
        var draft = TriggerDraft(calendar: .autoupdatingCurrent)
        for when in TriggerDraft.When.offered {
            draft.setWhen(when)
            if case .application = when {
                #expect(TriggerEditorSheet.showsAfterWake(draft))
            } else {
                #expect(!TriggerEditorSheet.showsAfterWake(draft))
            }
        }
        #expect(!L10n.Triggers.Editor.afterWake.isEmpty)
        #expect(!L10n.Triggers.Editor.afterWakeNote.isEmpty)
    }

    @Test func theStatusLineShowsTheCatchUpTraceAndAnOrdinaryRunDoesNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-trigger-catchup-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: dir.appendingPathComponent("groups.json")), saveDelay: .zero)
        let group = groups.addGroup(named: "Fixture")
        let store = TriggerStore(persistence: JSONFileTriggerPersistence(fileURL: dir.appendingPathComponent("triggers.json")), saveDelay: .zero)
        // The status line words whatever the saved entry says; triggers on the screens waking
        // keep the test free of the machine's running apps and their approval checks.
        let caughtUp = GroupTrigger(groupID: group.id, event: .screensWake, action: .openAll, runMode: .notice)
        let ordinary = GroupTrigger(groupID: group.id, event: .screensWake, action: .openAll, runMode: .notice)
        _ = store.add(caughtUp)
        _ = store.add(ordinary)
        let ranAt = Date()
        let saved = TriggerState(entries: [
            caughtUp.id: .init(lastRunAt: ranAt, lastOutcome: .ran(.openAll), lastOutcomeAt: ranAt, isCatchUp: true),
            ordinary.id: .init(lastRunAt: ranAt, lastOutcome: .ran(.openAll), lastOutcomeAt: ranAt),
        ])
        let statePersistence = JSONFileTriggerStatePersistence(fileURL: dir.appendingPathComponent("state.json"))
        try statePersistence.saveState(saved)
        let state = TriggerStateStore(persistence: statePersistence, saveDelay: .zero)
        let controller = TriggerController(groups: groups, store: store, stateStore: state, loginItem: LoginItem(), locationAccess: LocationAccess())
        #expect(controller.state.entry(for: caughtUp.id).isCatchUp)
        // Compared with the core's words (whatever the test machine's language).
        func expected(_ entry: TriggerState.Entry) -> String {
            TriggerDescriptions.lastRun(entry, groupName: "Fixture", now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        }
        let traced = controller.statusLine(of: caughtUp)
        let plain = controller.statusLine(of: ordinary)
        #expect(traced == expected(saved.entry(for: caughtUp.id)))
        #expect(plain == expected(saved.entry(for: ordinary.id)))
        #expect(traced != plain)
        var untraced = saved.entry(for: caughtUp.id)
        untraced.isCatchUp = false
        #expect(plain == expected(untraced))
        let moment = TriggerDescriptions.moment(ranAt, now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        #expect(traced.contains(Localization.format("core.trigger.lastRun.afterWake", "%@ (after the Mac woke)", moment)))
    }
}
