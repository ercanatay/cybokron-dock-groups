import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: the editor's display triggers")
struct TriggerDisplayDraftTests {
    private static let group = DockGroup.of("Work", ["com.apple.mail"])
    private static let calendar = TriggerTime.calendar(locale: "en_GB")
    private static let monitor = DisplayIdentity.monitor("VX2776-4K-mhd")
    private static let ultraFine = DisplayIdentity.monitor("LG UltraFine", vendor: 7789, model: 23_305, serial: 4_242)

    @Test func everyChangeMakesItsConditionAndEdge() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setChange(.displayConnects)
        #expect(draft.kind == nil)
        #expect(draft.change == .displayConnects)
        #expect(draft.event == .condition(.display(.anyExternal), edge: .starts))
        #expect(draft.isValid)
        draft.display = .display(Self.monitor)
        draft.setChange(.displayDisconnects)
        #expect(draft.event == .condition(.display(.display(Self.monitor)), edge: .ends))
        draft.useDisplays([.builtIn, Self.monitor])
        draft.setChange(.displaysConnected)
        #expect(draft.event == .condition(.displays(DisplayArrangement(displays: [.builtIn, Self.monitor])), edge: .starts))
        draft.setChange(.displaysDisconnected)
        #expect(draft.event == .condition(.displays(DisplayArrangement(displays: [.builtIn, Self.monitor])), edge: .ends))
        // Back to a moment: the time as it was.
        draft.setKind(.time)
        #expect(draft.event == .schedule(TriggerSchedule(hour: 9, minute: 0, weekdays: TriggerTime.weekdays)))
        #expect(draft.change == nil)
    }

    @Test func theWhenPopUpOffersMomentsThenChanges() {
        let offered = TriggerDraft.When.offered
        #expect(Array(offered.prefix(5)) == TriggerDraft.Kind.allCases.map(TriggerDraft.When.moment))
        for change in [TriggerDraft.Change.displayConnects, .displayDisconnects, .displaysConnected, .displaysDisconnected] {
            #expect(offered.contains(.change(change)))
        }
        #expect(Set(offered).count == offered.count)
    }

    @Test func changesAllowEveryAction() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setChange(.displayDisconnects)
        #expect(draft.allowedActions == TriggerAction.allCases)
        draft.setAction(.finish)
        #expect(draft.action == .finish)
        draft.setAction(.showPopup)
        #expect(draft.runMode == .immediately)
    }

    @Test func theseDisplaysNeedOneToEightDisplays() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setChange(.displaysConnected)
        #expect(draft.displays.isEmpty)
        #expect(!draft.isValid)
        let many = (1...10).map { DisplayIdentity.monitor("Monitor \($0)", serial: UInt32(100 + $0)) }
        draft.useDisplays(many)
        #expect(draft.displays.count == DisplayArrangement.maximumCount)
        #expect(draft.isValid)
        draft.useDisplays([.builtIn])
        #expect(draft.isValid, "the built-in display alone is a set too (the lid open, nothing else)")
    }

    @Test func aChosenDisplayCantBeTheBuiltInOne() {
        var draft = TriggerDraft(calendar: Self.calendar)
        draft.setChange(.displayConnects)
        draft.display = .display(.builtIn)
        #expect(!draft.isValid)
        draft.display = .display(Self.monitor)
        #expect(draft.isValid)
    }

    @Test func finishWhenItEndsIsOnlyForAStartOnAChangesStart() {
        var draft = TriggerDraft(calendar: Self.calendar)
        #expect(!draft.canFinishWhenEventEnds, "a time has no end")
        draft.setChange(.displayConnects)
        #expect(draft.canFinishWhenEventEnds)
        draft.finishesWhenEventEnds = true
        #expect(draft.trigger(groupID: Self.group.id).finishesWhenEventEnds)
        // Another action, or the end of the condition: the option goes.
        draft.setAction(.openAll)
        #expect(!draft.canFinishWhenEventEnds)
        #expect(!draft.finishesWhenEventEnds)
        draft.setAction(.start)
        draft.finishesWhenEventEnds = true
        draft.setChange(.displayDisconnects)
        #expect(!draft.finishesWhenEventEnds)
        // Set where it doesn't apply, it isn't saved.
        draft.finishesWhenEventEnds = true
        #expect(!draft.trigger(groupID: Self.group.id).finishesWhenEventEnds)
    }

    @Test func editingADisplayTriggerKeepsItsDisplayAndOption() throws {
        let existing = GroupTrigger.on(
            .condition(.display(.display(Self.ultraFine)), edge: .starts),
            group: Self.group,
            runMode: .notice,
            finishesWhenEventEnds: true
        )
        let draft = try #require(TriggerDraft(editing: existing, calendar: Self.calendar))
        #expect(draft.change == .displayConnects)
        #expect(draft.display == .display(Self.ultraFine))
        #expect(draft.finishesWhenEventEnds)
        #expect(draft.trigger(groupID: Self.group.id, replacing: existing) == existing)

        let arrangement = GroupTrigger.on(
            .condition(.displays(DisplayArrangement(displays: [.builtIn, Self.monitor, Self.monitor])), edge: .ends),
            group: Self.group,
            action: .finish,
            runMode: .askFirst
        )
        let other = try #require(TriggerDraft(editing: arrangement, calendar: Self.calendar))
        #expect(other.change == .displaysDisconnected)
        #expect(other.displays == [.builtIn, Self.monitor, Self.monitor])
        #expect(other.trigger(groupID: Self.group.id, replacing: arrangement) == arrangement)
    }

    // MARK: - The chooser

    @Test func theChooserListsExternalDisplaysOnceAndTheSavedOneWhenAway() {
        let twin = DisplayIdentity.monitor("VX2776-4K-mhd")
        let connected = [DisplayIdentity.builtIn, Self.monitor, twin]
        let options = DisplayChoices.options(connected: connected, saved: .anyExternal)
        #expect(options.map(\.match) == [.anyExternal, .display(Self.monitor)], "built-in left out, twins without serials are one choice")
        #expect(options.filter { !$0.isConnected }.isEmpty)

        let away = DisplayChoices.options(connected: connected, saved: .display(Self.ultraFine))
        #expect(away.map(\.match) == [.anyExternal, .display(Self.monitor), .display(Self.ultraFine)])
        #expect(away.last?.isConnected == false)

        let here = DisplayChoices.options(connected: connected + [Self.ultraFine], saved: .display(Self.ultraFine))
        #expect(here.count == 3)
        #expect(here.filter { !$0.isConnected }.isEmpty)
    }

    @Test func aRenamedDisplayIsStillChosen() {
        // Same serial, another name (a firmware update, another port): it's the same display.
        let renamed = DisplayIdentity.monitor("LG UltraFine Display", vendor: 7789, model: 23_305, serial: 4_242)
        let options = DisplayChoices.options(connected: [renamed], saved: .display(Self.ultraFine))
        #expect(options.map(\.match) == [.anyExternal, .display(renamed)])
        #expect(DisplayChoices.selection(for: .display(Self.ultraFine), in: options) == .display(renamed))
        #expect(DisplayChoices.selection(for: .anyExternal, in: options) == .anyExternal)
        let away = DisplayChoices.options(connected: [], saved: .display(Self.ultraFine))
        #expect(DisplayChoices.selection(for: .display(Self.ultraFine), in: away) == .display(Self.ultraFine))
    }

    @Test func theseDisplaysSayWhichAreConnected() {
        #expect(DisplayChoices.isConnected(Self.monitor, in: [.builtIn, DisplayIdentity.monitor("VX2776-4K-mhd")]))
        #expect(!DisplayChoices.isConnected(Self.ultraFine, in: [.builtIn, Self.monitor]))
        #expect(DisplayChoices.isConnected(.builtIn, in: [.builtIn]))
    }

    // MARK: - Sources

    @Test func theDisplaySourceRunsOnlyForADisplayTriggerThatCanRun() {
        let group = Self.group
        let active: Set<DockGroup.ID> = [group.id]
        let time = GroupTrigger.at(9, 0, group: group)
        var display = GroupTrigger.on(.condition(.display(.anyExternal), edge: .starts), group: group)
        #expect(TriggerSourceNeeds.of(rules: [time], activeGroups: active).isEmpty)
        #expect(TriggerSourceNeeds.of(rules: [time, display], activeGroups: active) == .displays)
        let arrangement = GroupTrigger.on(.condition(.displays(DisplayArrangement(displays: [.builtIn])), edge: .ends), group: group, action: .finish)
        #expect(TriggerSourceNeeds.of(rules: [arrangement], activeGroups: active) == .displays)
        // Off, of an archived group, or not runnable: no source.
        #expect(TriggerSourceNeeds.of(rules: [display], activeGroups: []).isEmpty)
        let builtIn = GroupTrigger.on(.condition(.display(.display(.builtIn)), edge: .starts), group: group)
        #expect(!builtIn.isRunnable)
        #expect(TriggerSourceNeeds.of(rules: [builtIn], activeGroups: active).isEmpty)
        display.isEnabled = false
        #expect(TriggerSourceNeeds.of(rules: [display], activeGroups: active).isEmpty)
    }
}
