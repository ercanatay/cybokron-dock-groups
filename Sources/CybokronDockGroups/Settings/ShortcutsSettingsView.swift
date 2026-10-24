import AppKit
import DockGroupsCore
import SwiftUI

/// Global keyboard shortcuts — the number shortcuts, and a read-only list of the groups' own
/// shortcuts, which are set in each group's settings — plus where else groups can be controlled
/// from: what to ask Siri for a group, the Shortcuts app and the URL scheme's links, each phrase and
/// link with a Copy button. The App Intents themselves are defined in `DockGroupsShortcuts`; this
/// only spells them out.
struct ShortcutsSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var store: GroupStore
    @ObservedObject var shortcuts: GlobalShortcutMonitor
    /// Opens the group window on a group's settings, where its shortcut is changed.
    let showGroupSettings: (DockGroup.ID) -> Void

    /// The group whose phrases and links are shown; the first group when unset or deleted.
    @State private var invocationGroupID: DockGroup.ID?
    /// The phrase or link copied last, which its button confirms for a moment.
    @State private var copiedText: String?

    private var settings: PopupPreferences { preferences.preferences }

    private var invocationGroup: DockGroup? {
        invocationGroupID.flatMap(store.group(withID:)) ?? store.groups.first
    }

    var body: some View {
        Form {
            keyboardSection
            if settings.shortcutsEnabled {
                assignedGroupsSection
            }
            groupShortcutsSection
            siriSection
            linksSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            shortcuts.refreshTrust()
            shortcuts.refreshSystemShortcuts()
        }
    }

    // MARK: - Sections

    private var keyboardSection: some View {
        Section {
            Toggle(L10n.Settings.Shortcuts.enable, isOn: binding(\.shortcutsEnabled))
            LabeledContent {
                Picker(L10n.Settings.Shortcuts.modifierKeys, selection: binding(\.shortcutModifiers)) {
                    ForEach(ShortcutModifiers.allCases, id: \.self) { modifiers in
                        Text(verbatim: "\(modifiers.symbols) 1…9").tag(modifiers)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text(L10n.Settings.Shortcuts.shortcutKeys)
                Text(L10n.Settings.Shortcuts.shortcutKeysDetail)
            }
            .disabled(!settings.shortcutsEnabled)
            if settings.shortcutsEnabled {
                shortcutStatus
            }
        } header: {
            Text(L10n.Settings.Shortcuts.keyboardHeader)
        }
    }

    /// Registered as hot keys, the shortcuts work everywhere without Accessibility access. Only
    /// when they couldn't be, and are watched for instead, does the access matter: then it says so.
    @ViewBuilder
    private var shortcutStatus: some View {
        switch shortcuts.mode {
        case .off:
            // Until the monitor has caught up with the toggle.
            EmptyView()
        case .hotKeys:
            worksEverywhereLabel
        case .eventMonitors:
            if shortcuts.isAccessibilityTrusted {
                LabeledContent {
                    EmptyView()
                } label: {
                    worksEverywhereLabel
                    Text(L10n.Settings.Shortcuts.hotKeyUnavailable)
                }
            } else {
                LabeledContent {
                    Button(L10n.Common.openPrivacySettings, action: shortcuts.openAccessibilitySettings)
                } label: {
                    Label(L10n.Settings.Shortcuts.needsAccess, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.Settings.Shortcuts.hotKeyUnavailable)
                    Text(L10n.Settings.Shortcuts.accessDetail(AppInfo.name))
                    Text(AccessibilityAccess.staleEntryHint)
                }
            }
        }
    }

    private var worksEverywhereLabel: some View {
        Label(L10n.Settings.Shortcuts.worksEverywhere, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }

    private var assignedGroupsSection: some View {
        Section {
            if store.groups.isEmpty {
                Text(L10n.Settings.Shortcuts.noGroups)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.groups.prefix(GroupShortcuts.digits.upperBound).enumerated()), id: \.element.id) { index, group in
                    LabeledContent {
                        Text(GroupShortcuts.title(digit: index + 1, modifiers: settings.shortcutModifiers))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(group.emoji)  \(group.name)")
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text(L10n.Settings.Shortcuts.assignedHeader)
        } footer: {
            Text(verbatim: [
                store.groups.count > GroupShortcuts.digits.upperBound
                    ? L10n.Settings.Shortcuts.assignedFooterLimit
                    : L10n.Settings.Shortcuts.assignedFooter,
                L10n.Settings.Shortcuts.Groups.renumber,
            ].joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The groups' own shortcuts, read-only: each with its keys, what it does and whether it
    /// works, and Change… to its group's settings (spec §3.2).
    private var groupShortcutsSection: some View {
        let assigned = store.groups.filter { $0.shortcut != nil }
        return Section {
            if assigned.isEmpty {
                Text(L10n.Settings.Shortcuts.Groups.none)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assigned) { group in
                    groupShortcutRow(group)
                }
            }
        } header: {
            Text(L10n.Settings.Shortcuts.Groups.header)
        } footer: {
            Text(L10n.Settings.Shortcuts.Groups.footer(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupShortcutRow(_ group: DockGroup) -> some View {
        if let shortcut = group.shortcut {
            let title = KeyNames.title(for: shortcut.keys)
            let status = shortcuts.groupStatuses[group.id] ?? .paused
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: status.isOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isOn ? Color.green : Color.orange)
                        .help(statusMessage(status, title: title))
                        .accessibilityLabel(statusMessage(status, title: title))
                    Button(L10n.Settings.Shortcuts.Groups.change) { showGroupSettings(group.id) }
                        .help(L10n.Settings.Shortcuts.Groups.changeHelp(group.name))
                }
            } label: {
                Text(verbatim: "\(group.emoji)  \(group.name)")
                    .lineLimit(1)
                Text(shortcut.action.title)
            }
        }
    }

    private func statusMessage(_ status: GroupShortcutStatus, title: String) -> String {
        var owner: String?
        if case .off(.takenByGroup(let id)) = status {
            owner = store.group(withID: id)?.name
        }
        return status.message(keyTitle: title, otherGroupName: owner)
    }

    private var siriSection: some View {
        Section {
            if let group = invocationGroup {
                Picker(L10n.Settings.Shortcuts.group, selection: invocationGroupBinding(selected: group.id)) {
                    ForEach(store.groups) { group in
                        Text(verbatim: "\(group.emoji)  \(group.name)").tag(group.id)
                    }
                }
                ForEach(
                    GroupInvocations.siriPhrases(groupName: group.name, appName: AppInfo.name)
                        + GroupInvocations.switchingPhrases(groupName: group.name, appName: AppInfo.name)
                ) { phrase in
                    copyRow(phrase, text: Text(L10n.Settings.Shortcuts.quotedPhrase(phrase.text)))
                }
            } else {
                Text(L10n.Settings.Shortcuts.siriNoGroups)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Button(L10n.Settings.Shortcuts.openShortcuts, action: openShortcutsApp)
            } label: {
                Text(L10n.Settings.Shortcuts.shortcutsApp)
                Text(L10n.Settings.Shortcuts.shortcutsAppDetail)
                Text(L10n.Switching.Shortcuts.shortcutsAppDetail)
            }
        } header: {
            Text(L10n.Settings.Shortcuts.siriHeader)
        } footer: {
            Text(L10n.Settings.Shortcuts.siriFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linksSection: some View {
        Section {
            if let group = invocationGroup {
                ForEach(GroupInvocations.links(for: group, in: store.groups) + GroupInvocations.switchingLinks(for: group, in: store.groups)) { link in
                    copyRow(link, text: Text(link.text).font(.system(.body, design: .monospaced)))
                }
            } else {
                Text(L10n.Settings.Shortcuts.linksNoGroups)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Common.links)
        } footer: {
            Text(markdown: "\(L10n.Settings.Shortcuts.linksFooter) \(L10n.Switching.Shortcuts.linksFooter)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A phrase or link with its action underneath and a Copy button.
    private func copyRow(_ invocation: GroupInvocation, text: Text) -> some View {
        LabeledContent {
            Button(copiedText == invocation.text ? L10n.Common.copied : L10n.Common.copy) { copy(invocation.text) }
                .help(L10n.Settings.Shortcuts.copyHelp(invocation.text))
        } label: {
            text
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(invocation.text)
            Text(invocation.title)
        }
    }

    private func invocationGroupBinding(selected id: DockGroup.ID) -> Binding<DockGroup.ID> {
        Binding(
            get: { id },
            set: { invocationGroupID = $0 }
        )
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedText == text {
                copiedText = nil
            }
        }
    }

    private func openShortcutsApp() {
        guard let url = URL(string: "shortcuts://") else { return }
        NSWorkspace.shared.open(url)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
