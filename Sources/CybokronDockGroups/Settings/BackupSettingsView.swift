import DockGroupsCore
import SwiftUI

/// Backup: export the groups and settings to a file, and restore them from one. Diagnostics: a
/// report to attach to a support request.
struct BackupSettingsView: View {
    @ObservedObject var backup: SettingsBackupController
    @ObservedObject var diagnostics: DiagnosticsController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(L10n.Settings.Backup.exportButton) { backup.exportSettings() }
                        .disabled(backup.isBusy)
                } label: {
                    Text(L10n.Settings.Backup.export)
                    Text(L10n.Settings.Backup.exportDetail)
                }
                LabeledContent {
                    Button(L10n.Settings.Backup.importButton) { backup.importSettings() }
                        .disabled(backup.isBusy)
                } label: {
                    Text(L10n.Settings.Backup.importLabel)
                    Text(L10n.Settings.Backup.importDetail)
                }
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text(L10n.Settings.backupTab)
            } footer: {
                Text(L10n.Settings.Backup.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(diagnostics.feedback == .copied ? L10n.Common.copied : L10n.Common.copy) { diagnostics.copyToClipboard() }
                            .disabled(diagnostics.isBusy)
                        Button(L10n.Settings.Diagnostics.saveToFile) { diagnostics.saveToFile() }
                            .disabled(diagnostics.isBusy)
                    }
                } label: {
                    Text(L10n.Settings.Diagnostics.export)
                    Text(L10n.Settings.Diagnostics.exportDetail)
                }
                if let feedback = diagnosticsFeedback {
                    Label(feedback.text, systemImage: feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isFailure ? .orange : .green)
                }
            } header: {
                Text(L10n.Settings.Diagnostics.header)
            } footer: {
                Text(L10n.Settings.Diagnostics.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String? {
        switch backup.status {
        case .exported(let fileName):
            return L10n.Settings.Backup.exported(fileName)
        case .imported(let groupCount, let appCount):
            return L10n.Settings.Backup.restored(groups: L10n.Common.groupCount(groupCount), apps: L10n.Common.appCount(appCount))
        case .merged(let addedGroupCount, let skippedGroupCount):
            let added = L10n.Common.groupCount(addedGroupCount)
            return skippedGroupCount > 0
                ? L10n.Settings.Backup.merged(groups: added, alreadyHere: skippedGroupCount)
                : L10n.Settings.Backup.merged(groups: added)
        case nil:
            return nil
        }
    }

    private var diagnosticsFeedback: (text: String, isFailure: Bool)? {
        switch diagnostics.feedback {
        case .copied:
            return (L10n.Settings.Diagnostics.copiedToClipboard, false)
        case .saved(let fileName):
            return (L10n.Settings.Diagnostics.saved(fileName), false)
        case .failed(let message):
            return (L10n.Settings.Diagnostics.saveFailed(message), true)
        case nil:
            return nil
        }
    }
}
