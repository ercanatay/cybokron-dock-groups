import AppKit
import DockGroupsCore
import SwiftUI

/// The group window's Triggers section (triggers spec §3.1): the group's triggers — each with its
/// switch, its rule and what happened last — Add Trigger…, Edit… and Remove. It says that triggers
/// run while the app is open and never quit apps, whether they're paused, and when Open at Login is
/// off. A trigger this version can't edit (a VPN one, or one a newer version made) can still be
/// turned off and removed; a Wi-Fi one says when it waits for Location access.
struct GroupTriggersSection: View {
    @ObservedObject var triggers: TriggerController
    @ObservedObject var store: TriggerStore
    @ObservedObject var loginItem: LoginItem
    let group: DockGroup
    /// Settings → Triggers (Open at Login).
    let showTriggerSettings: () -> Void

    @State private var editing: TriggerEditing?

    private typealias Texts = L10n.Triggers.GroupWindow

    private var groupTriggers: [GroupTrigger] {
        store.triggers(ofGroup: group.id).sorted(by: Self.listOrder)
    }

    private var limitMessage: String? {
        if store.triggers.count >= GroupTrigger.maximumCount { return TriggerAddResult.limitReached.message }
        if store.triggers(ofGroup: group.id).count >= GroupTrigger.maximumPerGroup { return TriggerAddResult.groupLimitReached.message }
        return nil
    }

    var body: some View {
        Section {
            let list = groupTriggers
            if list.isEmpty {
                Text(Texts.empty)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { trigger in
                TriggerRow(trigger: trigger, triggers: triggers, store: store, onEdit: { editing = TriggerEditing(existing: trigger) })
            }
            if list.contains(where: { if case .applicationPresence = $0.event { return true }; return false }) {
                Toggle(Texts.identifiedAppsOnly, isOn: Binding(get: { triggers.monitorIdentifiedAppsOnlyForSession }, set: { triggers.setMonitorIdentifiedAppsOnlyForSession($0) }))
                Text(Texts.identifiedAppsWarning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.Triggers.Identity.sectionNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(Texts.add) { editing = TriggerEditing(existing: nil) }
                    .disabled(limitMessage != nil)
                    .help(limitMessage ?? "")
                Spacer()
            }
            // On one row: a modifier on the section would go to each of its rows.
            .sheet(item: $editing) { request in
                TriggerEditorSheet(
                    group: group,
                    existing: request.existing,
                    store: store,
                    loginItem: loginItem,
                    locationAccess: triggers.locationAccess,
                    readDisplays: triggers.connectedDisplays,
                    readNetworkName: triggers.currentWiFiNetworkName,
                    approveApplication: { await triggers.approveApplication(ofTrigger: $0, confirmAdHoc: $1) }
                ) { editing = nil }
            }
            if triggers.isPaused, !list.isEmpty {
                Label(triggers.pauseDescription ?? Texts.paused, systemImage: "pause.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !loginItem.isOn, !list.isEmpty {
                HStack {
                    Text(Texts.loginItemOff)
                        .foregroundStyle(.secondary)
                    Button(Texts.turnOn, action: showTriggerSettings)
                        .buttonStyle(.link)
                }
            }
        } header: {
            Text(Texts.section)
        } footer: {
            Text(Texts.footer(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// By event kind (times first, then login, opening, screens, displays, networks), times by the
    /// hour; otherwise as they were added.
    private static func listOrder(_ lhs: GroupTrigger, _ rhs: GroupTrigger) -> Bool {
        let left = (rank(of: lhs.event), minute(of: lhs.event))
        let right = (rank(of: rhs.event), minute(of: rhs.event))
        return left < right
    }

    private static func rank(of event: TriggerEvent) -> Int {
        switch event {
        case .schedule: return 0
        case .login: return 1
        case .appOpens: return 2
        case .screensWake: return 3
        case .screensSleep, .screenLocks, .screenUnlocks: return 4
        case .condition: return 5
        case .unsupported: return 6
        case .applicationPresence: return 6
        }
    }

    private static func minute(of event: TriggerEvent) -> Int {
        if case .schedule(let schedule) = event { return schedule.minuteOfDay }
        return 0
    }
}

/// The editor to show: for a new trigger, or one being changed.
struct TriggerEditing: Identifiable {
    let existing: GroupTrigger?
    let id = UUID()
}

/// One trigger: its switch, its rule, its last run (or why it can't run), an application trigger's
/// approval, Edit… and Remove.
struct TriggerRow: View {
    let trigger: GroupTrigger
    @ObservedObject var triggers: TriggerController
    let store: TriggerStore
    let onEdit: (() -> Void)?

    private typealias Texts = L10n.Triggers.GroupWindow

    var body: some View {
        let summary = TriggerController.summary(of: trigger)
        let status = triggers.statusLine(of: trigger)
        let identity = triggers.identityBadge(of: trigger)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: Binding(
                get: { trigger.isEnabled && trigger.isRunnable },
                set: { store.setEnabled($0, forTrigger: trigger.id) }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!trigger.isRunnable)
            .help(Texts.toggleHelp)
            Image(systemName: Self.symbol(for: trigger.event))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(TriggerIdentityLabel.signatureHelp(of: trigger) ?? "")
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(trigger.isRunnable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                delayLabel
                if let identity {
                    TriggerIdentityLabel(state: identity, signature: trigger.approvedApplicationSignature)
                }
            }
            Spacer(minLength: 8)
            if let onEdit {
                let editable = TriggerDraft(editing: trigger, calendar: .autoupdatingCurrent) != nil
                Button(Texts.edit, action: onEdit)
                    .disabled(!editable)
                    .help(editable ? "" : Texts.cantEdit)
            }
            Button(role: .destructive) {
                store.delete(trigger.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Texts.remove)
            .accessibilityLabel(Texts.remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(identity.map { "\(summary). \(L10n.Triggers.Identity.badge($0)). \(status)" } ?? "\(summary). \(status)")
    }

    /// The delay a trigger waits before its action ("After 30 s"); while it waits, the time left,
    /// counting down, with an hourglass. Nothing for a trigger without a delay.
    @ViewBuilder
    private var delayLabel: some View {
        if let due = triggers.delayedUntil[trigger.id] {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(TriggerDescriptions.delay(Self.secondsLeft(until: due, now: context.date)), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        } else if trigger.delaySeconds > 0, trigger.hasValidDelay {
            Label(TriggerDescriptions.delay(trigger.delaySeconds), systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Whole seconds left until `due`, rounded up; 0 once it's due.
    static func secondsLeft(until due: Date, now: Date) -> Int {
        max(0, Int(due.timeIntervalSince(now).rounded(.up)))
    }

    static func symbol(for event: TriggerEvent) -> String {
        switch event {
        case .schedule: return "clock"
        case .login: return "person.crop.circle"
        case .appOpens: return "power"
        case .screensWake: return "sun.max"
        case .screensSleep: return "moon"
        case .screenLocks: return "lock"
        case .screenUnlocks: return "lock.open"
        case .condition(.display, _), .condition(.displays, _): return "display"
        case .condition(.wifi, _): return "wifi"
        case .condition(.ethernet, _): return "cable.connector"
        case .condition(.vpn, _): return "lock.shield"
        case .unsupported: return "questionmark.circle"
        case .applicationPresence: return "app"
        }
    }
}

/// An application trigger's approval under its status line: Unverified, Needs re-approval, Invalid
/// or Verification unavailable (none for an authorized one whose code is confirmed), with what it
/// means (and, where it must be approved again, how) as its tooltip. Information only: an app is approved in the trigger's editor, so it offers no button.
struct TriggerIdentityLabel: View {
    let state: TriggerApplicationIdentityState
    /// How the approved code was signed (an authorized trigger only), told in the tooltip.
    var signature: TriggerApplicationSignature?

    private typealias Texts = L10n.Triggers.Identity

    var body: some View {
        Label(Texts.badge(state), systemImage: Self.symbol(for: state))
            .font(.caption)
            .foregroundStyle(state.blocksEveryAction ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(Self.help(for: state, signature: signature))
    }

    /// What `state` means; for one waiting for approval or unreadable, also how to approve it
    /// again (an authorized trigger whose code can't be confirmed has nothing to approve).
    static func help(for state: TriggerApplicationIdentityState, signature: TriggerApplicationSignature? = nil) -> String {
        switch state {
        case .needsReapproval, .invalid: return "\(Texts.detail(state)) \(Texts.howToReapprove)"
        case .unverified: return Texts.detail(state)
        case .verificationUnavailable:
            // The approved signature, an ad-hoc one called weaker (the editor's wording).
            return [Texts.detail(state), Texts.Approve.signature(signature)].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// The tooltip of an authorized rule's summary: how its approved code was signed (an ad-hoc
    /// signature called weaker); `nil` for a rule that isn't authorized.
    static func signatureHelp(of trigger: GroupTrigger) -> String? {
        Texts.Approve.signature(trigger.approvedApplicationSignature)
    }

    static func symbol(for state: TriggerApplicationIdentityState) -> String {
        switch state {
        case .unverified: return "shield"
        case .needsReapproval: return "arrow.clockwise.circle"
        case .invalid: return "exclamationmark.triangle"
        case .verificationUnavailable: return "shield.slash"
        }
    }
}
