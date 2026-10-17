import DockGroupsCore
import SwiftUI

/// The Most Used list: whether the menu bar shows it, how long it is, what counts as apps opened
/// together, and clearing the history.
struct MostUsedSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageStore

    @State private var confirmsClearing = false

    private var settings: PopupPreferences { preferences.preferences }

    var body: some View {
        Form {
            Section {
                Toggle("Show Most Used in the menu bar", isOn: binding(\.showsMostUsed))
                LabeledContent {
                    Picker("Apps shown", selection: binding(\.mostUsedLimit)) {
                        ForEach(MostUsedRanking.allowedLimits, id: \.self) { limit in
                            Text("\(limit)").tag(limit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Apps shown")
                    Text("The most opened apps, in the menu and in the Most Used popup.")
                }
                .disabled(!settings.showsMostUsed)
                LabeledContent {
                    Picker("Session length", selection: binding(\.mostUsedSessionSeconds)) {
                        ForEach(PopupPreferences.allowedMostUsedSessionSeconds, id: \.self) { seconds in
                            Text(Self.title(forSessionSeconds: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Opened together within")
                    Text("Apps opened within this time of each other count as used together, which moves them up a little.")
                }
            } header: {
                Text("Most Used")
            } footer: {
                Text("Apps are ranked by how often you open them, from the Dock, Finder, Spotlight or a group. Launches are counted even while the list is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Recorded") {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Clear History…") { confirmsClearing = true }
                        .disabled(usage.stats.isEmpty)
                } label: {
                    Text("History")
                    Text("Stored on this Mac only, in usage-stats.json and usage-cooccurrence.json in Application Support.")
                }
            } header: {
                Text("Usage History")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear the usage history?", isPresented: $confirmsClearing) {
            Button("Clear History", role: .destructive) { usage.clearHistory() }
        } message: {
            Text("The Most Used list starts over. Your groups and apps aren't affected.")
        }
    }

    private var summary: String {
        let stats = usage.stats
        guard !stats.isEmpty else { return "No launches yet" }
        let launches = stats.totalLaunchCount
        let apps = stats.apps.count
        return "\(launches) \(launches == 1 ? "launch" : "launches") of \(apps) \(apps == 1 ? "app" : "apps")"
    }

    static func title(forSessionSeconds seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
