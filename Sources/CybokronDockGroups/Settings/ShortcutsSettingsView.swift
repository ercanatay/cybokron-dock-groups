import AppKit
import DockGroupsCore
import SwiftUI

/// Global keyboard shortcuts, plus where else groups can be controlled from: what to ask Siri for
/// a group, the Shortcuts app and the URL scheme's links, each phrase and link with a Copy button.
/// The App Intents themselves are defined in `DockGroupsShortcuts`; this only spells them out.
struct ShortcutsSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var store: GroupStore
    @ObservedObject var shortcuts: GlobalShortcutMonitor

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
            siriSection
            linksSection
        }
        .formStyle(.grouped)
        // With every group's phrases and links this tab is the tallest; the form scrolls instead
        // of growing past the screen.
        .frame(width: 480, height: 640)
        .onAppear { shortcuts.refreshTrust() }
    }

    // MARK: - Sections

    private var keyboardSection: some View {
        Section {
            Toggle("Open group popups with keyboard shortcuts", isOn: binding(\.shortcutsEnabled))
            LabeledContent {
                Picker("Modifier keys", selection: binding(\.shortcutModifiers)) {
                    ForEach(ShortcutModifiers.allCases, id: \.self) { modifiers in
                        Text("\(modifiers.symbols) 1…9").tag(modifiers)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("Shortcut keys")
                Text("Hold these keys and press 1 for the first group, 2 for the second, and so on. Press it again to close the popup.")
            }
            .disabled(!settings.shortcutsEnabled)
            if settings.shortcutsEnabled {
                accessibilityStatus
            }
        } header: {
            Text("Keyboard Shortcuts")
        }
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        if shortcuts.isAccessibilityTrusted {
            Label("Works in every app", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            LabeledContent {
                Button("Open Privacy & Security…", action: shortcuts.openAccessibilitySettings)
            } label: {
                Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("To notice the shortcuts while you work in other apps, allow \(AppInfo.name) under Privacy & Security → Accessibility. Until then they work only while its popup or a window of it is active.")
                Text(AccessibilityAccess.staleEntryHint)
            }
        }
    }

    private var assignedGroupsSection: some View {
        Section {
            if store.groups.isEmpty {
                Text("No groups yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.groups.prefix(GroupShortcuts.digits.upperBound).enumerated()), id: \.element.id) { index, group in
                    LabeledContent {
                        Text(GroupShortcuts.title(digit: index + 1, modifiers: settings.shortcutModifiers))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("\(group.emoji)  \(group.name)")
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Assigned Groups")
        } footer: {
            Text(store.groups.count > GroupShortcuts.digits.upperBound
                ? "Only the first nine groups have shortcuts. Drag groups in Manage Groups to change the order."
                : "Shortcuts follow the order of the groups in Manage Groups.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var siriSection: some View {
        Section {
            if let group = invocationGroup {
                Picker("Group", selection: invocationGroupBinding(selected: group.id)) {
                    ForEach(store.groups) { group in
                        Text("\(group.emoji)  \(group.name)").tag(group.id)
                    }
                }
                ForEach(GroupInvocations.siriPhrases(groupName: group.name, appName: AppInfo.name)) { phrase in
                    copyRow(phrase, text: Text("“\(phrase.text)”"))
                }
            } else {
                Text("Add a group to see what to ask Siri for it.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Button("Open Shortcuts", action: openShortcutsApp)
            } label: {
                Text("Shortcuts app")
                Text("Launch Group, Quit Group and Show Group are actions there and in Spotlight: add them to your own shortcuts, with your own trigger.")
            }
        } header: {
            Text("Siri and Shortcuts")
        } footer: {
            Text("Ask Siri with these words, by voice or by typing. They use the group's current name; shortcuts you build keep working after a rename.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linksSection: some View {
        Section {
            if let group = invocationGroup {
                ForEach(GroupInvocations.links(for: group, in: store.groups)) { link in
                    copyRow(link, text: Text(link.text).font(.system(.body, design: .monospaced)))
                }
            } else {
                Text("Add a group to see its links.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Links")
        } footer: {
            Text("Open a link from a script or another app, e.g. with `open` in Terminal. A group is named by its name (case, accents and punctuation don't matter) or, when the name is ambiguous, its ID. Add ?mode=force to a quit link to force quit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A phrase or link with its action underneath and a Copy button.
    private func copyRow(_ invocation: GroupInvocation, text: Text) -> some View {
        LabeledContent {
            Button(copiedText == invocation.text ? "Copied" : "Copy") { copy(invocation.text) }
                .help("Copy “\(invocation.text)” to the clipboard.")
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
