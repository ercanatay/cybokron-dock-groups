import DockGroupsCore
import SwiftUI

/// App-wide popup settings: look of the panel, the layout defaults groups can override, and what
/// opening a running app does.
struct PopupSettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.Settings.Popup.theme, selection: binding(\.theme)) {
                    ForEach(PanelTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Toggle(L10n.Settings.Popup.frostedGlass, isOn: binding(\.usesFrostedGlass))
            } header: {
                Text(L10n.Settings.Popup.appearanceHeader)
            } footer: {
                Text(L10n.Settings.Popup.appearanceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Picker(L10n.Settings.Popup.columns, selection: binding(\.columns)) {
                        Text(L10n.Common.auto).tag(PopupColumns.auto)
                        ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                            Text(verbatim: "\(count)").tag(PopupColumns.fixed(count))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(L10n.Settings.Popup.columns)
                    Text(L10n.Settings.Popup.columnsDetail)
                }
                LabeledContent {
                    Picker(L10n.Settings.Popup.maximumRows, selection: binding(\.maxRows)) {
                        ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                            Text(verbatim: "\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(L10n.Settings.Popup.maximumRows)
                    Text(L10n.Settings.Popup.maximumRowsDetail)
                }
                Toggle(L10n.Settings.Popup.showAppNames, isOn: binding(\.showsTitles))
                LabeledContent {
                    Picker(L10n.Settings.Popup.position, selection: binding(\.anchor)) {
                        ForEach(PopupAnchor.allCases, id: \.self) { anchor in
                            Text(anchor.title).tag(anchor)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(L10n.Settings.Popup.position)
                    Text(L10n.Settings.Popup.positionDetail)
                }
            } header: {
                Text(L10n.Settings.Popup.layoutHeader)
            } footer: {
                Text(L10n.Settings.Popup.layoutFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.usesFreeLayout)) {
                    Text(L10n.Settings.Popup.freeLayout)
                    Text(L10n.Settings.Popup.freeLayoutDetail)
                }
            } header: {
                Text(L10n.Settings.Popup.arrangingHeader)
            } footer: {
                Text(L10n.Settings.Popup.arrangingFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.restoresWindowsOfRunningApps)) {
                    Text(L10n.Settings.Popup.restoreWindows)
                    Text(L10n.Settings.Popup.restoreWindowsDetail)
                }
                if preferences.preferences.restoresWindowsOfRunningApps {
                    WindowRestoreAccessStatus()
                }
            } header: {
                Text(L10n.Settings.Popup.runningAppsHeader)
            }

            Section {
                Toggle(isOn: binding(\.showsStandaloneDockMenus)) {
                    Text(L10n.Settings.Popup.dockMenus)
                    Text(L10n.Settings.Popup.dockMenusDetail)
                }
            } header: {
                Text(L10n.Settings.Popup.standaloneIconsHeader)
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
                Label(L10n.Settings.Popup.accessGranted, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                LabeledContent {
                    Button(L10n.Common.openPrivacySettings, action: AccessibilityAccess.openSettings)
                } label: {
                    Label(L10n.Settings.Popup.accessRequired, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.Settings.Popup.accessDetail(AppInfo.name))
                    Text(AccessibilityAccess.staleEntryHint)
                }
            }
        }
        .onAppear { access.beginObserving() }
        .onDisappear { access.endObserving() }
    }
}
