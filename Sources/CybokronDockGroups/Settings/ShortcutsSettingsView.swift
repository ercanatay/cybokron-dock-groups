import DockGroupsCore
import SwiftUI

/// Global keyboard shortcuts, plus where else groups can be controlled from: Siri, the Shortcuts
/// app and the URL scheme.
struct ShortcutsSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var store: GroupStore
    @ObservedObject var shortcuts: GlobalShortcutMonitor

    private var settings: PopupPreferences { preferences.preferences }

    var body: some View {
        Form {
            keyboardSection
            if settings.shortcutsEnabled {
                assignedGroupsSection
            }
            siriSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
        // Examples with the first group, so they work as written.
        let exampleName = store.groups.first?.name ?? "Work"
        let exampleSlug = store.groups.first.map { GroupLookup.slug(for: $0.name) }.flatMap { $0.isEmpty ? nil : $0 } ?? "work"
        return Section {
            LabeledContent("Siri") {
                Text("“Launch \(exampleName) in \(AppInfo.name)”")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Shortcuts app") {
                Text("Launch Group · Quit Group · Show Group")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("URL") {
                Text("\(URLCommand.scheme)://open/\(exampleSlug)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Siri, Shortcuts and Links")
        } footer: {
            Text("The actions also appear in Spotlight and the Shortcuts app, where you can give them your own trigger. Links take open, launch or quit with a group's name or ID, for example from a script.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
