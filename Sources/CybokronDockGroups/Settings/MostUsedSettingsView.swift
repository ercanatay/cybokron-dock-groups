import DockGroupsCore
import SwiftUI

/// The Most Used list: whether the menu bar shows it, how long it is, what counts as apps opened
/// together, Local Suggestions made from it, and clearing the history.
struct MostUsedSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageStore
    let suggestions: SuggestionCenter

    @State private var confirmsClearing = false
    @State private var explainsSuggestions = false
    @State private var confirmsReset = false

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

            suggestionsSection

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
            Text(settings.showsSuggestions ? L10n.Suggestions.Settings.clearMessage : L10n.Settings.MostUsed.clearConfirmMessage)
        }
        // Shown once, before Suggestions are first turned on: nothing turns on without it.
        .alert(L10n.Suggestions.Settings.explainTitle, isPresented: $explainsSuggestions) {
            Button(L10n.Suggestions.Settings.explainButton) { suggestions.setEnabled(true) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Suggestions.Settings.explainMessage(AppInfo.name))
        }
        .confirmationDialog(L10n.Suggestions.Settings.resetConfirmTitle, isPresented: $confirmsReset) {
            Button(L10n.Suggestions.Settings.resetConfirmButton, role: .destructive) { suggestions.resetDismissed() }
        } message: {
            Text(L10n.Suggestions.Settings.resetConfirmMessage)
        }
    }

    private typealias SuggestionTexts = L10n.Suggestions.Settings

    /// Settings → Most Used → Suggestions (local-suggestions.md §2.4): the switch — off while Most
    /// Used is, with the reason — its status, Reset Dismissed Suggestions… and where it's stored.
    private var suggestionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(SuggestionTexts.toggle, isOn: Binding(get: { settings.showsSuggestions }, set: { setSuggestions($0) }))
                    .disabled(!settings.showsMostUsed)
                Text(settings.showsMostUsed ? SuggestionTexts.detail : SuggestionTexts.needsMostUsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent(SuggestionTexts.status) {
                Text(Self.statusText(suggestions.status()))
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Button(SuggestionTexts.reset) { confirmsReset = true }
                    .disabled(usage.suggestionState.dismissed.isEmpty)
            } label: {
                Text(SuggestionTexts.dismissed)
                Text(SuggestionTexts.dismissedCount(usage.suggestionState.dismissed.count))
            }
        } header: {
            Text(SuggestionTexts.header)
        } footer: {
            Text(SuggestionTexts.storage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setSuggestions(_ isOn: Bool) {
        if isOn, suggestions.needsExplanation {
            explainsSuggestions = true
        } else {
            suggestions.setEnabled(isOn)
        }
    }

    static func statusText(_ status: SuggestionStatus) -> String {
        switch status {
        case .off: SuggestionTexts.statusOff
        case .needsMostUsed: SuggestionTexts.statusNeedsMostUsed
        case .watching(let days, let required): SuggestionTexts.watching(days, of: required)
        case .none: SuggestionTexts.statusNone
        case .available(let count): SuggestionTexts.count(count)
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
