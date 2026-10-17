import DockGroupsCore
import SwiftUI

/// App-wide popup settings: look of the panel, and the layout defaults groups can override.
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
                    Text("Popups opened from the menu bar are centered over the Dock.")
                }
            } header: {
                Text("Popup Layout")
            } footer: {
                Text("These are the defaults for every group. Each group can override them under Manage Groups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
