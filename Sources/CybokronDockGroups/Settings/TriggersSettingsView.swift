import AppKit
import DockGroupsCore
import SwiftUI

/// Settings → Triggers (triggers spec §3.3): Open at Login, whether triggers run or are paused
/// (with Pause and Resume), where Location access will show (only Wi-Fi triggers need it, and this
/// version has none), and every trigger by group — each with its switch, its rule and what happened
/// last, and the way to its group's settings. The footer says triggers run while the app is open,
/// and how a Shortcuts automation starts a group when it's quit.
struct TriggersSettingsView: View {
    @ObservedObject var triggers: TriggerController
    @ObservedObject var store: TriggerStore
    @ObservedObject var groups: GroupStore
    @ObservedObject var loginItem: LoginItem
    /// Opens the group window on a group's settings.
    let showGroupSettings: (DockGroup.ID) -> Void

    private typealias Texts = L10n.Triggers.Settings

    var body: some View {
        Form {
            loginSection
            statusSection
            locationSection
            listSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { loginItem.refresh() }
    }

    private var loginSection: some View {
        Section {
            Toggle(Texts.openAtLogin, isOn: Binding(get: { loginItem.status != .off }, set: { loginItem.set($0) }))
            Text(Texts.openAtLoginDetail(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loginItem.status == .needsApproval {
                HStack {
                    Label(Texts.needsApproval, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Texts.openLoginItems, action: loginItem.openSystemSettings)
                }
            }
            if let problem = loginItem.problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(Texts.status) {
                HStack {
                    Text(statusText)
                        .foregroundStyle(triggers.isPaused ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.trailing)
                    if triggers.isPaused {
                        Button(Texts.resume, action: triggers.resume)
                    } else {
                        Menu(Texts.pause) {
                            Button(L10n.Triggers.MenuBar.forOneHour) { triggers.pause(.oneHour) }
                            Button(L10n.Triggers.MenuBar.untilTomorrow) { triggers.pause(.untilTomorrow) }
                            Button(L10n.Triggers.MenuBar.untilResumed) { triggers.pause(.untilResumed) }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch triggers.pauseStatus {
        case nil: return Texts.running
        case .until(let time): return Texts.pausedUntil(time)
        case .untilResumed: return Texts.pausedIndefinitely
        case .budget: return TriggerBudget.pauseMessage
        }
    }

    private var locationSection: some View {
        Section {
            LabeledContent(Texts.location) {
                Text(Texts.locationNotUsed)
                    .foregroundStyle(.secondary)
            }
            Text(Texts.locationDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The groups that have triggers, active first, then archived ones.
    private var groupsWithTriggers: [DockGroup] {
        let ids = Set(store.triggers.map(\.groupID))
        return (groups.groups + groups.archivedGroups.map(\.group)).filter { ids.contains($0.id) }
    }

    private var listSection: some View {
        Section {
            if store.triggers.isEmpty {
                Text(Texts.listEmpty)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groupsWithTriggers) { group in
                HStack {
                    Text(verbatim: "\(group.emoji)  \(group.name)")
                        .font(.headline)
                    Spacer()
                    if groups.group(withID: group.id) != nil {
                        Button(Texts.showInGroupWindow) { showGroupSettings(group.id) }
                            .buttonStyle(.link)
                    }
                }
                ForEach(store.triggers(ofGroup: group.id)) { trigger in
                    TriggerRow(trigger: trigger, triggers: triggers, store: store, onEdit: nil)
                        .padding(.leading, 8)
                }
            }
        } header: {
            Text(Texts.listHeader)
        } footer: {
            Text(Texts.footer(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
