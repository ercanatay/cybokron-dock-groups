import Foundation
import Testing
@testable import DockGroupsCore

/// The application-presence authorization record: how it's saved and read back (strictly), how old,
/// imported and malformed records are treated, and how the evaluator and the coordinator gate on it.
@Suite("Application identity authorization")
@MainActor
struct ApplicationIdentityAuthorizationTests {
    private static let work = TriggerRig.work
    private static let design = TriggerRig.design
    private static let groupID = work.id
    private static let id = UUID(uuidString: "7A1660E0-0000-4000-8000-0000000000A1")!
    nonisolated private static let bundle = "com.example.App"
    nonisolated private static let hashHex = "0123456789abcdef0123456789abcdef01234567"

    private func appTrigger(_ action: TriggerAction = .showPopup, runMode: TriggerRunMode? = .immediately, identity: ApplicationIdentityAuthorization?, group: DockGroup? = nil) -> GroupTrigger {
        var trigger = GroupTrigger(groupID: (group ?? Self.work).id, event: .applicationPresence(bundleIdentifier: Self.bundle, edge: .starts), action: action, runMode: runMode)
        if let identity { trigger.applicationIdentity = identity }
        return trigger
    }

    private func roundTrip(_ trigger: GroupTrigger) throws -> GroupTrigger {
        try JSONDecoder().decode(GroupTrigger.self, from: JSONEncoder().encode(trigger))
    }

    /// A saved application rule (enabled) with `identity` as its record (`nil`: no record at all).
    private func decodeRule(identity: Any?, enabled: Bool = true, bundle: String = Self.bundle) throws -> GroupTrigger {
        var object: [String: Any] = [
            "id": Self.id.uuidString,
            "groupID": Self.groupID.uuidString,
            "enabled": enabled,
            "event": ["kind": "applicationPresence", "bundleIdentifier": bundle, "edge": "starts"],
            "action": "showPopup",
            "runMode": "immediately",
        ]
        if let identity { object["applicationIdentity"] = identity }
        return try JSONDecoder().decode(GroupTrigger.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func bindingObject(status: String = "authorized", identifier: String = Self.bundle, cdhash: Any = Self.hashHex, signature: Any = "developerID", authorizedAt: Any = 1_793_000_000) -> [String: Any] {
        ["status": status, "identifier": identifier, "cdhash": cdhash, "signature": signature, "authorizedAt": authorizedAt]
    }

    private func encodedJSON(_ trigger: GroupTrigger) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(trigger))
    }

    // MARK: - Saving and reading back

    @Test func everyStatusSurvivesARoundTrip() throws {
        let binding = ApplicationIdentityBinding.fixture(Self.bundle)
        let raw: JSONValue = .object(["status": .string("authorized"), "identifier": .string(Self.bundle), "cdhash": .string(""), "signature": .string("developerID"), "authorizedAt": .integer(1)])
        let cases: [(ApplicationIdentityAuthorization, ApplicationIdentityAuthorization.Status)] = [
            (.authorize(binding), .authorized),
            (.needsReapproval(binding), .needsReapproval),
            (.unverified, .unverified),
            (.invalid(raw), .invalid),
        ]
        for (identity, status) in cases {
            let original = appTrigger(identity: identity)
            let restored = try roundTrip(original)
            #expect(restored == original)
            #expect(restored.applicationIdentity == identity)
            #expect(restored.applicationIdentityStatus == status)
            // A saved record is the user's: an enabled rule stays enabled.
            #expect(restored.isEnabled)
        }
        let json = try encodedJSON(appTrigger(identity: .authorize(binding)))
        #expect(json["applicationIdentity"] == .object([
            "status": .string("authorized"),
            "identifier": .string(Self.bundle),
            "cdhash": .string(Self.hashHex),
            "signature": .string("developerID"),
            "authorizedAt": .integer(1_793_000_000),
        ]))
        #expect(try encodedJSON(appTrigger(identity: .unverified))["applicationIdentity"] == .object(["status": .string("unverified")]))
        // An unreadable record is written back exactly as it was read.
        #expect(try encodedJSON(appTrigger(identity: .invalid(raw)))["applicationIdentity"] == raw)
    }

    @Test func uppercaseHashIsReadAsTheSameHash() throws {
        let rule = try decodeRule(identity: bindingObject(cdhash: Self.hashHex.uppercased()))
        #expect(rule.applicationIdentityStatus == .authorized)
        #expect(rule.applicationIdentity?.binding?.codeHash.hex == Self.hashHex)
    }

    @Test func aRuleWithoutARecordIsUnverifiedAndComesInTurnedOff() throws {
        for identity in [nil, NSNull()] as [Any?] {
            let legacy = try decodeRule(identity: identity, enabled: true)
            #expect(legacy.applicationIdentityStatus == .unverified)
            #expect(legacy.applicationIdentity == .unverified)
            #expect(!legacy.isEnabled)
            #expect(!legacy.canRun)
            // Saved again, it carries its record and stays off.
            let saved = try encodedJSON(legacy)
            #expect(saved["applicationIdentity"] == .object(["status": .string("unverified")]))
            #expect(saved["enabled"] == .bool(false))
        }
    }

    @Test func aLegacyFileLoadsWithItsApplicationRulesTurnedOff() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dg-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "triggers.json")
        let login = GroupTrigger(groupID: Self.groupID, event: .login, action: .showPopup)
        let text = """
        {"formatVersion": 1, "triggers": [
          {"id": "\(Self.id.uuidString)", "groupID": "\(Self.groupID.uuidString)", "enabled": true,
           "event": {"kind": "applicationPresence", "bundleIdentifier": "\(Self.bundle)", "edge": "starts"},
           "action": "openAll", "runMode": "immediately"},
          {"id": "\(login.id.uuidString)", "groupID": "\(Self.groupID.uuidString)", "enabled": true,
           "event": {"kind": "login"}, "action": "showPopup", "runMode": "immediately"}
        ]}
        """
        try Data(text.utf8).write(to: url)
        let loaded = try JSONFileTriggerPersistence(fileURL: url).loadTriggers()
        #expect(loaded.count == 2)
        #expect(loaded[0].applicationIdentityStatus == .unverified)
        #expect(!loaded[0].isEnabled)
        // Other triggers are untouched and carry no record.
        #expect(loaded[1].isEnabled)
        #expect(loaded[1].applicationIdentity == nil)
        #expect(loaded[1].applicationIdentityStatus == nil)
    }

    @Test func malformedRecordsAreInvalidAndNeverRun() throws {
        let malformed: [Any] = [
            bindingObject(cdhash: ""),
            bindingObject(cdhash: String(Self.hashHex.dropLast())),
            bindingObject(cdhash: String(Self.hashHex.dropLast()) + "g"),
            bindingObject(cdhash: Self.hashHex + "00"),
            bindingObject(cdhash: 42),
            bindingObject(signature: "unsigned"),
            bindingObject(signature: ""),
            bindingObject(status: "trusted"),
            bindingObject(status: "invalid"),
            bindingObject(authorizedAt: "yesterday"),
            bindingObject(authorizedAt: 1.5),
            bindingObject(authorizedAt: 1e15),
            bindingObject(identifier: "com.example.Other"),
            bindingObject(identifier: "com.example.app"),
            bindingObject(identifier: "bad id"),
            bindingObject(status: "needsReapproval", cdhash: ""),
            bindingObject().merging(["path": "/Applications/Evil.app"]) { $1 },
            bindingObject().filter { $0.key != "authorizedAt" },
            ["status": "unverified", "cdhash": Self.hashHex],
            ["status": "unverified", "enabled": true],
            [:] as [String: Any],
            "authorized",
            true,
            [bindingObject()],
        ]
        for identity in malformed {
            let rule = try decodeRule(identity: identity, enabled: true)
            #expect(rule.applicationIdentityStatus == .invalid, "\(identity)")
            #expect(!rule.isRunnable)
            #expect(!rule.canRun)
            #expect(rule.problem != nil)
            // Kept as read.
            let saved = try encodedJSON(rule)
            let expected = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: identity, options: .fragmentsAllowed))
            #expect(saved["applicationIdentity"] == expected)
        }
    }

    @Test func waitingAndInvalidRulesCantRunButUnverifiedAndAuthorizedCan() {
        let binding = ApplicationIdentityBinding.fixture(Self.bundle)
        #expect(appTrigger(identity: .authorize(binding)).canRun)
        #expect(appTrigger(.start, identity: .unverified).canRun)
        #expect(!appTrigger(identity: .needsReapproval(binding)).canRun)
        #expect(!appTrigger(identity: .invalid(.string("x"))).canRun)
        // A record set for another identifier counts as invalid.
        #expect(!appTrigger(identity: .authorize(.fixture("com.example.Other"))).canRun)
        #expect(appTrigger(identity: .authorize(.fixture("com.example.Other"))).applicationIdentityStatus == .invalid)
    }

    @Test func changingTheApplicationDropsTheAuthorization() throws {
        var trigger = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        trigger.event = .applicationPresence(bundleIdentifier: "com.example.Other", edge: .starts)
        #expect(trigger.applicationIdentity == .unverified)
        // The same application with another edge keeps it.
        var edge = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        edge.event = .applicationPresence(bundleIdentifier: Self.bundle, edge: .ends)
        #expect(edge.applicationIdentityStatus == .authorized)
        // Another kind of event has no record at all.
        var login = appTrigger(identity: .authorize(.fixture(Self.bundle)))
        login.event = .login
        #expect(login.applicationIdentity == nil)
        #expect(try encodedJSON(login)["applicationIdentity"] == nil)
        // A new application rule starts unverified.
        #expect(appTrigger(identity: nil).applicationIdentity == .unverified)
    }

    @Test func transitionsNeverWidenTrust() throws {
        let binding = ApplicationIdentityBinding.fixture(Self.bundle)
        let newer = ApplicationIdentityBinding.fixture(Self.bundle, hash: try #require(ApplicationCodeHash(hex: String(repeating: "ab", count: 20))))
        let authorized = ApplicationIdentityAuthorization.authorize(binding)
        #expect(authorized.requiringReapproval() == .needsReapproval(binding))
        #expect(ApplicationIdentityAuthorization.unverified.requiringReapproval() == .unverified)
        #expect(ApplicationIdentityAuthorization.invalid(.null).requiringReapproval() == .invalid(.null))
        #expect(authorized.requiringReapproval().reapproved(with: newer) == .authorized(newer))
        #expect(authorized.requiringReapproval().reapproved(with: .fixture("com.example.Other")) == nil)
        #expect(ApplicationIdentityAuthorization.unverified.reapproved(with: newer) == nil)
        #expect(ApplicationIdentityAuthorization.invalid(.null).reapproved(with: newer) == nil)
        #expect(ApplicationIdentityBinding(identifier: "bad id", codeHash: binding.codeHash, signature: .apple, authorizedAt: Date()) == nil)
        #expect(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: binding.codeHash, signature: .apple, authorizedAt: Date(timeIntervalSince1970: 1e13)) == nil)
        // Whole seconds, so it reads back equal.
        let fractional = try #require(ApplicationIdentityBinding(identifier: Self.bundle, codeHash: binding.codeHash, signature: .adHoc, authorizedAt: Date(timeIntervalSince1970: 1_793_000_000.75)))
        #expect(fractional.authorizedAt == Date(timeIntervalSince1970: 1_793_000_000))
    }

    @Test func theProductionVerifierNeverConfirms() {
        let verifier = UnavailableApplicationIdentityVerifier()
        #expect(verifier.verdict(for: .fixture(Self.bundle)) == .unavailable)
        let authorized = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        #expect(ApplicationIdentityClearance.of(authorized, verifier: verifier) == .none)
        #expect(ApplicationIdentityClearance.of(appTrigger(identity: .unverified), verifier: verifier) == .showPopupOnly)
        #expect(ApplicationIdentityClearance.of(GroupTrigger.on(.login, group: Self.work), verifier: verifier) == .allActions)
    }

    @Test func clearanceFollowsTheStatusAndTheVerdict() {
        let binding = ApplicationIdentityBinding.fixture(Self.bundle)
        let verifier = FakeApplicationIdentityVerifier(.verified)
        let authorized = appTrigger(.openAll, identity: .authorize(binding))
        #expect(ApplicationIdentityClearance.of(authorized, verifier: verifier) == .allActions)
        #expect(verifier.askedAbout == [binding])
        verifier.verdict = .codeChanged
        #expect(ApplicationIdentityClearance.of(authorized, verifier: verifier) == .none)
        verifier.verdict = .unavailable
        #expect(ApplicationIdentityClearance.of(authorized, verifier: verifier) == .none)
        verifier.verdict = .verified
        #expect(ApplicationIdentityClearance.of(appTrigger(identity: .needsReapproval(binding)), verifier: verifier) == .none)
        #expect(ApplicationIdentityClearance.of(appTrigger(identity: .invalid(.null)), verifier: verifier) == .none)
        #expect(ApplicationIdentityClearance.of(appTrigger(identity: .authorize(.fixture("com.example.Other"))), verifier: verifier) == .none)
        #expect(ApplicationIdentityClearance.showPopupOnly.permits(.showPopup))
        for action in [TriggerAction.start, .openAll, .finish] {
            #expect(!ApplicationIdentityClearance.showPopupOnly.permits(action))
            #expect(!ApplicationIdentityClearance.none.permits(action))
            #expect(ApplicationIdentityClearance.allActions.permits(action))
        }
    }

    // MARK: - Evaluation

    private func evaluate(_ trigger: GroupTrigger) -> TriggerEvaluation {
        TriggerEvaluator.evaluate(.applicationEdge(triggerID: trigger.id, edge: .starts), rules: [trigger], state: TriggerState(), environment: TriggerEnvironment(), activeGroups: [Self.groupID], now: Date(timeIntervalSince1970: 1_800_000_000), calendar: Calendar(identifier: .gregorian))
    }

    @Test func unverifiedRulesRunOnlyShowThePopupAndRecordWhyTheRestIsSkipped() {
        let popup = appTrigger(.showPopup, identity: .unverified)
        #expect(evaluate(popup).firings.map(\.action) == [.showPopup])
        for action in [TriggerAction.start, .openAll, .finish] {
            let trigger = appTrigger(action, runMode: .notice, identity: .unverified)
            let evaluation = evaluate(trigger)
            #expect(evaluation.firings.isEmpty, "\(action)")
            #expect(evaluation.state.entry(for: trigger.id).lastOutcome == .skipped(.applicationNotVerified))
        }
    }

    @Test func waitingAndInvalidRulesProduceNothing() {
        for identity in [ApplicationIdentityAuthorization.needsReapproval(.fixture(Self.bundle)), .invalid(.null)] {
            let trigger = appTrigger(.showPopup, identity: identity)
            let evaluation = evaluate(trigger)
            #expect(evaluation.firings.isEmpty)
            #expect(evaluation.state.entry(for: trigger.id).lastOutcome == nil)
        }
        #expect(evaluate(appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))).firings.map(\.action) == [.openAll])
    }

    @Test func theSkipIsSavedAndDescribedWithExistingText() throws {
        var state = TriggerState()
        state.record(.skipped(.applicationNotVerified), for: Self.id, at: Date(timeIntervalSince1970: 1_800_000_000))
        let restored = try JSONDecoder().decode(TriggerState.self, from: JSONEncoder().encode(state))
        #expect(restored.entry(for: Self.id).lastOutcome == .skipped(.applicationNotVerified))
        let line = TriggerDescriptions.lastRun(restored.entry(for: Self.id), groupName: "Work", now: Date(timeIntervalSince1970: 1_800_000_000), calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
        #expect(line == "Can't run: fix or remove it.")
    }

    // MARK: - Coordinator

    @Test func unverifiedStartIsSkippedAndRecordedWhileUnverifiedPopupRuns() async {
        let start = appTrigger(.start, runMode: .notice, identity: .unverified)
        let rig = TriggerRig([start])
        rig.deliverApplicationEdge(of: start)
        await rig.settleDown()
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.outcome(start) == .skipped(.applicationNotVerified))

        let popup = appTrigger(.showPopup, identity: .unverified)
        let popupRig = TriggerRig([popup])
        popupRig.deliverApplicationEdge(of: popup)
        await popupRig.settleDown()
        #expect(popupRig.handler.calls == ["popup:Work"])
        // The verifier is never asked about unverified rules.
        #expect(rig.verifier.askedAbout.isEmpty)
        #expect(popupRig.verifier.askedAbout.isEmpty)
    }

    @Test func unverifiedOpenAllAndFinishAreSkipped() async {
        for action in [TriggerAction.openAll, .finish] {
            let trigger = appTrigger(action, runMode: .immediately, identity: .unverified)
            let rig = TriggerRig([trigger])
            rig.handler.current = Self.work.id
            rig.deliverApplicationEdge(of: trigger)
            await rig.settleDown()
            #expect(rig.handler.calls.isEmpty, "\(action)")
            #expect(rig.outcome(trigger) == .skipped(.applicationNotVerified))
        }
    }

    @Test func authorizedRuleRunsOnlyWhileTheVerifierConfirmsIt() async {
        let trigger = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await rig.settleDown()
        #expect(rig.handler.calls == ["openAll:Work"])

        for verdict in [ApplicationIdentityVerdict.unavailable, .codeChanged] {
            let rig = TriggerRig([trigger])
            rig.verifier.verdict = verdict
            // Not observed at all: nothing to track.
            #expect(!rig.coordinator.beginApplicationObservations(generation: 1))
            #expect(rig.coordinator.observeApplications(generation: 1, sequence: 1, counts: ["com.example.app": 0]) == .stopped)
            #expect(rig.coordinator.observeApplications(generation: 1, sequence: 2, counts: ["com.example.app": 1]) == .stopped)
            await rig.settleDown()
            #expect(rig.handler.calls.isEmpty, "\(verdict)")
            #expect(rig.outcome(trigger) == nil)
        }
    }

    @Test func withTheProductionVerifierAuthorizedRulesDoNothing() async {
        let trigger = appTrigger(.showPopup, identity: .authorize(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        rig.coordinator.applicationIdentityVerifier = UnavailableApplicationIdentityVerifier()
        #expect(!rig.coordinator.beginApplicationObservations(generation: 1))
        rig.coordinator.observeApplications(generation: 1, sequence: 1, counts: ["com.example.app": 0])
        rig.coordinator.observeApplications(generation: 1, sequence: 2, counts: ["com.example.app": 1])
        await rig.settleDown()
        #expect(rig.handler.calls.isEmpty)
    }

    @Test func verdictLostWhileSettlingDropsTheFiring() async {
        let trigger = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        rig.deliverApplicationEdge(of: trigger)
        await settle { rig.sleeper.sleepingCount > 0 }
        rig.verifier.verdict = .unavailable
        rig.sleeper.wakeAll()
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.coordinator.waitingFirings.isEmpty)
    }

    @Test func codeChangeDuringANoticeDismissesItAndRunsNothing() async {
        let trigger = appTrigger(.start, runMode: .notice, identity: .authorize(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        rig.deliverApplicationEdge(of: trigger)
        await rig.settleDown()
        #expect(rig.presenter.isShowing)
        rig.verifier.verdict = .codeChanged
        rig.coordinator.applicationIdentityVerdictsChanged()
        await settle { rig.coordinator.isIdle }
        #expect(rig.presenter.dismissCount == 1)
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.anotherTrigger))
    }

    @Test func codeChangeDuringANoticeWithoutAPushStillRunsNothing() async {
        // The carry-out checks after the notice ask the verifier again.
        let trigger = appTrigger(.start, runMode: .notice, identity: .authorize(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        rig.presenter.holds = true
        rig.deliverApplicationEdge(of: trigger)
        await rig.settleDown()
        #expect(rig.presenter.isShowing)
        rig.verifier.verdict = .codeChanged
        rig.presenter.release(.run)
        await settle { rig.coordinator.isIdle }
        #expect(rig.handler.calls.isEmpty)
        #expect(rig.outcome(trigger) == .skipped(.anotherTrigger))
    }

    @Test func savedReapprovalOrInvalidRecordCancelsPendingWork() async {
        let binding = ApplicationIdentityBinding.fixture(Self.bundle)
        for identity in [ApplicationIdentityAuthorization.needsReapproval(binding), .invalid(.string("x"))] {
            // Awaiting a notice.
            let trigger = appTrigger(.start, runMode: .notice, identity: .authorize(binding))
            let rig = TriggerRig([trigger])
            rig.presenter.holds = true
            rig.deliverApplicationEdge(of: trigger)
            await rig.settleDown()
            #expect(rig.presenter.isShowing)
            let previous = rig.rules
            rig.rules[0].applicationIdentity = identity
            rig.coordinator.rulesChanged(previous: previous)
            await settle { rig.coordinator.isIdle }
            #expect(rig.presenter.dismissCount >= 1)
            #expect(rig.handler.calls.isEmpty)
            // Still settling, and the store's notification hasn't come.
            let popup = appTrigger(.showPopup, identity: .authorize(binding))
            let settling = TriggerRig([popup])
            settling.deliverApplicationEdge(of: popup)
            await settle { settling.sleeper.sleepingCount > 0 }
            settling.rules[0].applicationIdentity = identity
            settling.sleeper.wakeAll()
            await settle { settling.coordinator.isIdle }
            #expect(settling.handler.calls.isEmpty)
            // And it isn't observed any more.
            #expect(!settling.coordinator.beginApplicationObservations(generation: settling.presenceGeneration + 1))
        }
    }

    @Test func waitingAndInvalidRulesAreNotObserved() async {
        let trigger = appTrigger(.showPopup, identity: .needsReapproval(.fixture(Self.bundle)))
        let rig = TriggerRig([trigger])
        #expect(!rig.coordinator.beginApplicationObservations(generation: 1))
        let invalid = appTrigger(.showPopup, identity: .invalid(.null))
        let invalidRig = TriggerRig([invalid])
        #expect(!invalidRig.coordinator.beginApplicationObservations(generation: 1))
    }

    // MARK: - Editing

    @Test func newApplicationTriggersAreUnverifiedAndTurnedOff() throws {
        var draft = TriggerDraft(calendar: Calendar(identifier: .gregorian))
        draft.setWhen(.application(.starts))
        let selected = draft.selectApplication(AppReference(bundleIdentifier: Self.bundle, name: "App"))
        #expect(selected)
        let created = draft.trigger(groupID: Self.groupID)
        #expect(created.applicationIdentity == .unverified)
        #expect(!created.isEnabled)
        // A schedule trigger is still on by default.
        #expect(TriggerDraft(calendar: Calendar(identifier: .gregorian)).trigger(groupID: Self.groupID).isEnabled)
    }

    @Test func editingKeepsTheAuthorizationOnlyForTheSameApplication() throws {
        var existing = appTrigger(.openAll, runMode: .notice, identity: .authorize(.fixture(Self.bundle)))
        existing.isEnabled = true
        var draft = try #require(TriggerDraft(editing: existing, calendar: Calendar(identifier: .gregorian)))
        draft.setAction(.start)
        let edited = draft.trigger(groupID: Self.groupID, replacing: existing)
        #expect(edited.applicationIdentity == existing.applicationIdentity)
        #expect(edited.isEnabled)
        let selectedOther = draft.selectApplication(AppReference(bundleIdentifier: "com.example.Other", name: "Other"))
        #expect(selectedOther)
        let other = draft.trigger(groupID: Self.groupID, replacing: existing)
        #expect(other.applicationIdentity == .unverified)
        #expect(!other.isEnabled)
    }

    // MARK: - Backups

    private func backup(_ triggers: [GroupTrigger]) -> SettingsBackup {
        SettingsBackup(appVersion: "0.11.1", exportedAt: Date(timeIntervalSince1970: 1_793_400_000), groups: [Self.work, Self.design], triggers: triggers, preferences: PopupPreferences())
    }

    @Test func backupsCarryNoCodeHashAndImportsNeverAuthorize() throws {
        let authorized = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        let waiting = appTrigger(.openAll, identity: .needsReapproval(.fixture(Self.bundle)), group: Self.design)
        let data = try backup([authorized, waiting]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(Self.hashHex))
        #expect(!text.contains("developerID"))
        #expect(!text.contains("authorizedAt"))
        let restored = try SettingsBackup.decode(from: data)
        #expect(restored.triggers.count == 2)
        for trigger in restored.triggers {
            #expect(trigger.applicationIdentity == .unverified)
            #expect(!trigger.isEnabled)
        }
    }

    @Test func aCraftedBackupsAuthorizationAndSwitchAreIgnored() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: backup([]).encoded()) as? [String: Any])
        let rule: [String: Any] = [
            "id": UUID().uuidString, "groupID": Self.groupID.uuidString, "enabled": true,
            "event": ["kind": "applicationPresence", "bundleIdentifier": Self.bundle, "edge": "starts"],
            "action": "openAll", "runMode": "immediately",
            "applicationIdentity": bindingObject(),
        ]
        object["triggers"] = [rule, rule.merging(["id": UUID().uuidString, "applicationIdentity": ["status": "unverified"]]) { $1 }]
        let imported = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: object))
        #expect(imported.triggers.count == 2)
        for trigger in imported.triggers {
            #expect(trigger.applicationIdentity == .unverified)
            #expect(!trigger.isEnabled)
            #expect(!trigger.canRun)
        }
    }

    @Test func restoringAndMergingDropTheAuthorizationToo() {
        // Restore and merge turn the backup's triggers off through `turnedOff`.
        let authorized = appTrigger(.openAll, identity: .authorize(.fixture(Self.bundle)))
        #expect(authorized.turnedOff.applicationIdentity == .unverified)
        #expect(!authorized.turnedOff.isEnabled)
        let login = GroupTrigger.on(.login, group: Self.work)
        #expect(login.turnedOff.applicationIdentity == nil)
    }
}
