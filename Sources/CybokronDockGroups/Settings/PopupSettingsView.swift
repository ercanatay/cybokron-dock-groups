import DockGroupsCore
import SwiftUI

/// App-wide popup settings: look of the panel, the layout defaults groups can override, and what
/// opening a running app does.
struct PopupSettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: binding(\.theme)) {
                    ForEach(PanelTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Toggle("Frosted glass background", isOn: binding(\.usesFrostedGlass))
            } header: {
                Text("Popup Appearance")
            } footer: {
                Text("The theme applies to the popup only; this window follows your macOS appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Picker("Columns", selection: binding(\.columns)) {
                        Text("Auto").tag(PopupColumns.auto)
                        ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                            Text("\(count)").tag(PopupColumns.fixed(count))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Columns")
                    Text("Auto keeps the standard popup width; a number makes the popup only as wide as the group needs.")
                }
                LabeledContent {
                    Picker("Maximum rows", selection: binding(\.maxRows)) {
                        ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Maximum rows")
                    Text("Limits the popup's height; larger groups scroll.")
                }
                Toggle("Show app names", isOn: binding(\.showsTitles))
                LabeledContent {
                    Picker("Position", selection: binding(\.anchor)) {
                        ForEach(PopupAnchor.allCases, id: \.self) { anchor in
                            Text(anchor.title).tag(anchor)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Position")
                    Text("Above the clicked icon opens a popup over its group's Dock icon, or under the menu bar icon when chosen from its menu. Popups opened with a shortcut, a link or Siri stay centered over the Dock.")
                }
            } header: {
                Text("Popup Layout")
            } footer: {
                Text("These are the defaults for every group. Each group can override them under Manage Groups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.usesFreeLayout)) {
                    Text("Free layout")
                    Text("Apps stay in the cell you drag them to, and the others don't move; dropping an app on another swaps the two.")
                }
            } header: {
                Text("Arranging Apps")
            } footer: {
                Text("Off, a group's apps fill the popup in order and make room when you move one. A→Z in the popup sorts a group by name either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.restoresWindowsOfRunningApps)) {
                    Text("Restore windows when reopening an app that is running")
                    Text("Clicking a running app brings back its hidden and minimized windows, as clicking it in the Dock does. Off, the app only comes to the front.")
                }
                if preferences.preferences.restoresWindowsOfRunningApps {
                    WindowRestoreAccessStatus()
                }
            } header: {
                Text("Running Apps")
            }

            Section {
                Toggle(isOn: binding(\.showsStandaloneDockMenus)) {
                    Text("Menu on group Dock icons")
                    Text("Right-click a standalone group's Dock icon for its apps, Open All, Hide All and Close All, once the icon was clicked. Its app then shows as running in the Dock and in ⌘-Tab.")
                }
            } header: {
                Text("Standalone Dock Icons")
            }

            if let problem = preferences.saveProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// Whether minimized windows can be restored: that needs Accessibility access. Access is granted in
/// System Settings, which doesn't tell the app, so `AccessibilityTrustMonitor` reads it again while
/// this shows (every second until granted, and whenever the app becomes active again).
private struct WindowRestoreAccessStatus: View {
    @ObservedObject private var access = AccessibilityTrustMonitor.shared

    var body: some View {
        Group {
            if access.isTrusted {
                Label("Accessibility access granted: minimized windows come back too", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                LabeledContent {
                    Button("Open Privacy & Security…", action: AccessibilityAccess.openSettings)
                } label: {
                    Label("Restoring minimized windows requires Accessibility access", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Allow \(AppInfo.name) under Privacy & Security → Accessibility. Until then, hidden apps still come back, and apps are asked to reopen as from the Dock. Standalone group icons need the access for their own apps.")
                    Text(AccessibilityAccess.staleEntryHint)
                }
            }
        }
        .onAppear { access.beginObserving() }
        .onDisappear { access.endObserving() }
    }
}
