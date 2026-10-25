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
                    readNetworkName: triggers.currentWiFiNetworkName
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
        case .screensSleep: return 4
        case .condition: return 5
        case .unsupported: return 6
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

/// One trigger: its switch, its rule, its last run (or why it can't run), Edit… and Remove.
struct TriggerRow: View {
    let trigger: GroupTrigger
    @ObservedObject var triggers: TriggerController
    let store: TriggerStore
    let onEdit: (() -> Void)?

    private typealias Texts = L10n.Triggers.GroupWindow

    var body: some View {
        let summary = TriggerController.summary(of: trigger)
        let status = triggers.statusLine(of: trigger)
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
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(trigger.isRunnable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityLabel("\(summary). \(status)")
    }

    static func symbol(for event: TriggerEvent) -> String {
        switch event {
        case .schedule: return "clock"
        case .login: return "person.crop.circle"
        case .appOpens: return "power"
        case .screensWake: return "sun.max"
        case .screensSleep: return "moon"
        case .condition(.display, _), .condition(.displays, _): return "display"
        case .condition(.wifi, _): return "wifi"
        case .condition(.ethernet, _): return "cable.connector"
        case .condition(.vpn, _): return "lock.shield"
        case .unsupported: return "questionmark.circle"
        }
    }
}
