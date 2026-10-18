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
                Toggle(L10n.Settings.MostUsed.show, isOn: binding(\.showsMostUsed))
                LabeledContent {
                    Picker(L10n.Settings.MostUsed.appsShown, selection: binding(\.mostUsedLimit)) {
                        ForEach(MostUsedRanking.allowedLimits, id: \.self) { limit in
                            Text(verbatim: "\(limit)").tag(limit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(L10n.Settings.MostUsed.appsShown)
                    Text(L10n.Settings.MostUsed.appsShownDetail)
                }
                .disabled(!settings.showsMostUsed)
                LabeledContent {
                    Picker(L10n.Settings.MostUsed.sessionLength, selection: binding(\.mostUsedSessionSeconds)) {
                        ForEach(PopupPreferences.allowedMostUsedSessionSeconds, id: \.self) { seconds in
                            Text(Self.title(forSessionSeconds: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(L10n.Settings.MostUsed.openedTogether)
                    Text(L10n.Settings.MostUsed.openedTogetherDetail)
                }
            } header: {
                Text(MostUsedGroup.name)
            } footer: {
                Text(L10n.Settings.MostUsed.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L10n.Settings.MostUsed.recorded) {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button(L10n.Settings.MostUsed.clearHistoryEllipsis) { confirmsClearing = true }
                        .disabled(usage.stats.isEmpty)
                } label: {
                    Text(L10n.Settings.MostUsed.history)
                    Text(L10n.Settings.MostUsed.historyDetail)
                }
            } header: {
                Text(L10n.Settings.MostUsed.usageHistoryHeader)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .confirmationDialog(L10n.Settings.MostUsed.clearConfirmTitle, isPresented: $confirmsClearing) {
            Button(L10n.Settings.MostUsed.clearHistory, role: .destructive) { usage.clearHistory() }
        } message: {
            Text(L10n.Settings.MostUsed.clearConfirmMessage)
        }
    }

    private var summary: String {
        let stats = usage.stats
        guard !stats.isEmpty else { return L10n.Settings.MostUsed.noLaunches }
        return L10n.Settings.MostUsed.summary(
            launches: L10n.Settings.MostUsed.launchCount(stats.totalLaunchCount),
            apps: L10n.Common.appCount(stats.apps.count)
        )
    }

    /// "15 minutes", "1 hour", in the user's language.
    static func title(forSessionSeconds seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
